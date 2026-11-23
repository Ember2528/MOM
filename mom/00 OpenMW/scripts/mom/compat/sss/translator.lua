local M = {}
M.id = 'sss'
M.abiVersion = 1
-- Existing supported sources keep their lowering and saved extension version.
M.behaviorVersion = 0
M.configDirs = {
  'scripts/staticSwitcher/data',
}
local model_path_contract = require('scripts.mom.contracts.model_path')
local source_ir = require('scripts.mom.compiler.source_ir')
local isArray = require('scripts.mom.common.tables').isArray
local finiteInteger = require('scripts.mom.common.numbers').isInteger
local clone = require('scripts.mom.contracts.plain_data').cloneValidated
local normalizeMeshPath = model_path_contract.normalize
local function normalizePath(path)
  return tostring(path or ''):gsub('\\', '/')
end
local function basename(path)
  local normalized = normalizePath(path)
  local last = normalized:match('([^/]+)$') or normalized
  return (last:gsub('%.ya?ml$', ''))
end
local function isSssConfig(sourceConfig)
  if type(sourceConfig) ~= 'table' then return false end
  if sourceConfig.variants ~= nil or sourceConfig.actions ~= nil then return false end
  -- Claim malformed static candidates too, so invalid scopes cannot be
  -- declined and accidentally reinterpreted as another format.
  return sourceConfig.replace_meshes ~= nil
end
function M.claims(source)
  return isSssConfig(source and source.config or nil)
end
local function nonEmptyString(value)
  return type(value) == 'string' and value:find('%S') ~= nil
end
local function arrayLength(values, path)
  if type(values) ~= 'table' then return nil, path .. ': expected array' end
  if not isArray(values) then return nil, path .. ': expected dense array' end
  return #values, nil
end
local function copyStringArray(values, path)
  if values == nil then return {}, nil end
  local count, err = arrayLength(values, path)
  if count == nil then return nil, err end
  local out = {}
  for i = 1, count do
    if not nonEmptyString(values[i]) then
      return nil, string.format('%s[%d]: expected non-empty string', path, i)
    end
    out[i] = values[i]
  end
  return out, nil
end
local function copyExteriorCells(values, path)
  if values == nil then return {}, nil end
  local count, err = arrayLength(values, path .. '.exterior_cells')
  if count == nil then return nil, err end
  local out = {}
  for i = 1, count do
    local cell = values[i]
    local cellPath = string.format('%s.exterior_cells[%d]', path, i)
    if type(cell) ~= 'table' then
      return nil, cellPath .. ': expected object with integer x and y'
    end
    for key in pairs(cell) do
      if key ~= 'x' and key ~= 'y' then
        return nil, cellPath .. '.' .. tostring(key) .. ': is not allowed'
      end
    end
    if not finiteInteger(cell.x) or not finiteInteger(cell.y) then
      return nil, cellPath .. ': expected finite integer x and y'
    end
    out[i] = {cell.x, cell.y}
  end
  return out, nil
end
local STATIC_FIELDS = {
  log_name = true, priority = true, once = true, instances = true,
  replace_names = true, replace_regions = true, exterior_cells = true,
  replace_meshes = true, ignore_records = true,
}
local function validateFields(raw, path)
  for key in pairs(raw) do
    if not STATIC_FIELDS[key] then
      return nil, path .. '.' .. tostring(key) .. ': unsupported SSS static field'
    end
  end
  if raw.instances ~= nil then
    return nil, path .. '.instances: static and instance pipelines cannot be combined'
  end
  if raw.once ~= nil then
    return nil, path .. '.once: once is not applicable to SSS static modules'
  end
  if raw.priority ~= nil and raw.priority ~= 'standard' then
    return nil, path .. '.priority: only standard priority is supported; SSS tier/chain order is not MOM conflict priority'
  end
  if raw.log_name ~= nil and type(raw.log_name) ~= 'string' then
    return nil, path .. '.log_name: expected string'
  end
  return true, nil
end
local function meshEntries(meshMap, path)
  if type(meshMap) ~= 'table' then
    return nil, path .. '.replace_meshes: expected non-empty mesh map'
  end
  local sources = {}
  for source, target in pairs(meshMap) do
    if not nonEmptyString(source) or not nonEmptyString(target) then
      return nil, path .. '.replace_meshes: expected non-empty source and replacement mesh strings'
    end
    sources[#sources + 1] = source
  end
  if #sources == 0 then return nil, path .. '.replace_meshes: expected non-empty mesh map' end
  table.sort(sources)
  local entries, bySource = {}, {}
  for i = 1, #sources do
    local source = normalizeMeshPath(sources[i])
    local target = normalizeMeshPath(meshMap[sources[i]])
    if not source or not target then
      return nil, path .. '.replace_meshes: invalid mesh path'
    end
    local previous = bySource[source]
    if previous ~= nil and previous ~= target then
      return nil, path .. '.replace_meshes: conflicting replacements for normalized source ' .. source
    end
    if previous == nil then
      bySource[source] = target
      entries[#entries + 1] = {source, target}
    end
  end
  return entries, nil
end
local function nameAndGridCell(names, coords)
  local cell = {}
  if #names > 0 then
    cell.match = {}
    for i = 1, #names do cell.match[i] = '*' .. names[i] .. '*' end
  end
  if #coords > 0 then cell.coords = clone(coords) end
  return next(cell) and cell or '*'
end
local function scopeBranches(names, coords, regions)
  local nameGrid = nameAndGridCell(names, coords)
  if #regions == 0 then
    -- Preserve the old supported no-region source action exactly.
    return {{cell = nameGrid, previsit = #coords > 0}}
  end
  local branches = {}
  if #coords > 0 then
    -- Coordinate cells retain legacy previsit even inside a region branch.
    branches[#branches + 1] = {
      name = 'region_grids',
      cell = {coords = clone(coords), region = clone(regions)}, previsit = true,
    }
    branches[#branches + 1] = {
      name = 'region_other',
      cell = {region = clone(regions), exclude = {coords = clone(coords)}},
    }
  else
    branches[#branches + 1] = {name = 'regions', cell = {region = clone(regions)}}
  end
  if #names > 0 or #coords > 0 then
    nameGrid.exclude = {region = clone(regions)}
    branches[#branches + 1] = {
      name = 'names_grids_other', cell = nameGrid, previsit = #coords > 0,
    }
  end
  return branches
end
local function buildIgnoreFilter(ids)
  if #ids == 0 then return nil end
  local tuple = {'exclude'}
  for i = 1, #ids do tuple[#tuple + 1] = ids[i] end
  return tuple
end
local function buildAttachTuples(entries, cellSpec)
  local tuples = {}
  for i = 1, #entries do
    tuples[i] = {clone(cellSpec), entries[i][1], entries[i][2]}
  end
  return tuples
end
local function compatError(message)
  return {kind = 'invalid-sss-config', message = message}
end
function M.translateSource(source)
  local path = source and source.path or nil
  local raw = source and source.config or nil
  if not isSssConfig(raw) then return nil, false end
  local errorPath = tostring(path or 'SSS source')
  local valid, err = validateFields(raw, errorPath)
  if not valid then return nil, true, compatError(err) end
  local names
  names, err = copyStringArray(raw.replace_names, errorPath .. '.replace_names')
  if not names then return nil, true, compatError(err) end
  local coords
  coords, err = copyExteriorCells(raw.exterior_cells, errorPath)
  if not coords then return nil, true, compatError(err) end
  local regions
  regions, err = copyStringArray(raw.replace_regions, errorPath .. '.replace_regions')
  if not regions then return nil, true, compatError(err) end
  local ignored
  ignored, err = copyStringArray(raw.ignore_records, errorPath .. '.ignore_records')
  if not ignored then return nil, true, compatError(err) end
  local entries
  entries, err = meshEntries(raw.replace_meshes, errorPath)
  if not entries then return nil, true, compatError(err) end
  local branches = scopeBranches(names, coords, regions)
  local actions = {}
  for i = 1, #branches do
    local branch = branches[i]
    local diagnosticId = normalizePath(path) .. '#compat:sss:sss:replace_meshes'
    local sourcePath = {'replace_meshes'}
    if branch.name ~= nil then
      diagnosticId = diagnosticId .. ':' .. branch.name
      sourcePath[2] = branch.name
    end
    local ignoreFilter = buildIgnoreFilter(ignored)
    actions[i] = source_ir.sourceActionOwned({
      attach = buildAttachTuples(entries, branch.cell),
      disableOriginal = true,
      filters = ignoreFilter and {ignoreFilter} or nil,
      previsit = branch.previsit == true or nil,
    }, {
      source = {
        adapterId = M.id, file = normalizePath(path),
        variant = 'sss:' .. basename(path), path = sourcePath,
      },
      diagnosticId = diagnosticId, family = 'place_ref',
      allowEmptyCellSelection = branch.name ~= nil and true or nil,
    })
  end
  return actions, true
end

return M
