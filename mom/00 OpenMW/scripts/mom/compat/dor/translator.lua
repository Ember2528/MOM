local M = {}
M.id = 'dor'
M.abiVersion = 1
M.behaviorVersion = 0
M.configDirs = {
  'MWSE/mods/_OR_',
}
local spec_key = require('scripts.mom.compiler.spec_key')
local source_ir = require('scripts.mom.compiler.source_ir')
local function basename(path)
  local normalized = tostring(path or ''):gsub('\\', '/')
  return normalized:match('([^/]+)$') or normalized
end
local function stem(path)
  return (basename(path):gsub('%.lua$', ''))
end
local function normalizePath(path)
  return tostring(path or ''):gsub('\\', '/')
end
local hashString = require('scripts.mom.common.strings').hashString
local function sanitizeId(value)
  local lowered = tostring(value or ''):lower()
  lowered = lowered:gsub('^_or_', '')
  lowered = lowered:gsub('[^%w]+', '_')
  lowered = lowered:gsub('_+', '_')
  lowered = lowered:gsub('^_', ''):gsub('_$', '')
  if lowered == '' then
    return 'unnamed'
  end
  return lowered
end
local function compatError(kind, message)
  return {
    kind = kind,
    message = message,
  }
end
local function parseIndexedSuffix(key, prefix)
  local suffix = tostring(key or ''):match('^' .. prefix .. '(%d+)$')
  return suffix and tonumber(suffix) or nil
end
local function sortedIndexedKeys(values, prefix)
  local out = {}
  for key in pairs(values or {}) do
    local index = parseIndexedSuffix(key, prefix)
    if index ~= nil then
      out[#out + 1] = {
        key = key,
        index = index,
      }
    end
  end
  table.sort(out, function(left, right)
    if left.index ~= right.index then
      return left.index < right.index
    end
    return left.key < right.key
  end)
  return out
end
local function hasAnyIndexedKey(values, prefix)
  for key in pairs(values or {}) do
    if parseIndexedSuffix(key, prefix) ~= nil then
      return true
    end
  end
  return false
end
local function cellPatternList(raw, path)
  if raw == nil then return nil, nil end
  if type(raw) ~= 'table' then
    return nil, string.format('%s: expected array of cell descriptors', tostring(path))
  end
  local out = {}
  for i = 1, #raw do
    local entry = raw[i]
    local cell_name = nil
    if type(entry) == 'string' then
      cell_name = entry
    elseif type(entry) == 'table' then
      cell_name = entry.cellName
    end
    if type(cell_name) ~= 'string' or cell_name == '' then
      return nil, string.format('%s[%d]: expected cellName string', tostring(path), i)
    end
    out[#out + 1] = '*' .. tostring(cell_name) .. '*'
  end
  return #out > 0 and out or nil, nil
end
local function translateCellSpec(candidate, path)
  local include, include_err = cellPatternList(candidate.specificCell, path .. '.specificCell')
  if include_err then return nil, include_err end
  local exclude, exclude_err = cellPatternList(candidate.excludedCell, path .. '.excludedCell')
  if exclude_err then return nil, exclude_err end
  if not include and not exclude then
    return nil, nil
  end
  local cell = {}
  if include then
    cell.match = include
  end
  if exclude then
    cell.exclude = {
      match = exclude,
    }
  end
  return cell, nil
end
local function familyKeyFor(old_object)
  return tostring(old_object or ''):lower()
end
local function familyStableId(old_object)
  return string.format('%s_%s', sanitizeId(old_object), hashString(familyKeyFor(old_object)))
end
local function managedConflictGroupId(module_id)
  return string.format('dor:%s:candidates', tostring(module_id))
end
local function managedCandidatePriority(position)
  return 1 - tonumber(position or 1)
end
local function buildCandidate(old_object, raw_candidate, object_key, candidate_key, path, source_order)
  if type(raw_candidate) ~= 'table' then
    return nil, string.format('%s: expected object', tostring(path))
  end
  local new_object = raw_candidate.newObject
  if type(new_object) ~= 'string' or new_object == '' then
    return nil, string.format('%s.newObject: expected non-empty string', tostring(path))
  end
  local chance = raw_candidate.replaceChance
  if chance == nil then
    chance = 1
  end
  if type(chance) ~= 'number' or chance < 0 or chance > 1 then
    return nil, string.format('%s.replaceChance: expected number in [0, 1]', tostring(path))
  end
  local cell, cell_err = translateCellSpec(raw_candidate, path)
  if cell_err then
    return nil, cell_err
  end
  return {
    id = sanitizeId(candidate_key),
    chance = chance,
    select = cell and { cell = cell } or nil,
    hasSpecificCell = raw_candidate.specificCell ~= nil,
    hasExcludedCell = raw_candidate.excludedCell ~= nil,
    sourceOrder = tonumber(source_order) or 0,
    identityHint = tostring(object_key) .. '/' .. tostring(candidate_key),
    sourcePath = {tostring(object_key), 'newObjects', tostring(candidate_key)},
    oldObject = old_object,
    newObject = new_object,
  }, nil
end
local function compareCandidates(left, right)
  if left.hasSpecificCell ~= right.hasSpecificCell then
    return left.hasSpecificCell == true
  end
  if left.hasExcludedCell ~= right.hasExcludedCell then
    return left.hasExcludedCell == true
  end
  if left.chance ~= right.chance then
    return left.chance > right.chance
  end
  if left.sourceOrder ~= right.sourceOrder then
    return left.sourceOrder < right.sourceOrder
  end
  return tostring(left.id) < tostring(right.id)
end
local function parseObjectEntry(raw_object, path)
  if type(raw_object) ~= 'table' then
    return nil, string.format('%s: expected object', tostring(path))
  end
  local old_object = raw_object.oldObject
  if type(old_object) ~= 'string' or old_object == '' then
    return nil, string.format('%s.oldObject: expected non-empty string', tostring(path))
  end
  if type(raw_object.newObjects) ~= 'table' or not hasAnyIndexedKey(raw_object.newObjects, 'newObject') then
    return nil, string.format('%s.newObjects: expected at least one newObjectN entry', tostring(path))
  end
  return {
    oldObject = old_object,
    indexedCandidates = sortedIndexedKeys(raw_object.newObjects, 'newObject'),
  }, nil
end
local function newFamily(old_object)
  return {
    oldObject = old_object,
    candidates = {},
  }
end
local function appendObjectCandidates(family, raw_object, object_key, path)
  local parsed, parsed_err = parseObjectEntry(raw_object, path)
  if not parsed then
    return nil, parsed_err
  end
  local base_order = #family.candidates
  for i = 1, #parsed.indexedCandidates do
    local entry = parsed.indexedCandidates[i]
    local candidate, candidate_err = buildCandidate(
      parsed.oldObject,
      raw_object.newObjects[entry.key],
      object_key,
      entry.key,
      string.format('%s.newObjects.%s', tostring(path), tostring(entry.key)),
      base_order + i
    )
    if not candidate then
      return nil, candidate_err
    end
    family.candidates[#family.candidates + 1] = candidate
  end
  return family, nil
end
local function canUseSimpleGrouping(family)
  if #family.candidates ~= 1 then
    return false
  end
  local candidate = family.candidates[1]
  return candidate.select == nil and candidate.chance == 1
end
local function managedFamilySignature(position, candidate)
  return spec_key.fromSpec({
    position = tonumber(position or 1),
    chance = candidate and candidate.chance or 1,
    select = candidate and candidate.select or nil,
    oldObject = candidate and candidate.oldObject or nil,
    newObject = candidate and candidate.newObject or nil,
  })
end
function M.matchesPath(path)
  local normalized = normalizePath(path):lower()
  local base = basename(normalized)
  return normalized:match('^mwse/mods/_or_/') ~= nil
    and normalized:sub(-4) == '.lua'
    and base:match('^_or_') ~= nil
end
function M.load(path)
  local dor_loader = require('scripts.mom.compat.dor.loader')
  local parsed, err = dor_loader.load(path)
  if not parsed then
    return nil, compatError('dor-load-failed', tostring(err))
  end
  if type(parsed) ~= 'table' then
    return nil, compatError('invalid-dor-config', 'top-level DOR module must return a table')
  end
  return parsed
end

local function parseFamilies(path, raw)
  if type(raw) ~= 'table' then
    return nil, nil, 'top-level DOR module must return a table'
  end
  if not hasAnyIndexedKey(raw, 'objectToReplace') then
    return nil, nil, 'expected at least one objectToReplaceN entry'
  end
  local module_id = sanitizeId(stem(path))
  local indexed_objects = sortedIndexedKeys(raw, 'objectToReplace')
  local families = {}
  local families_by_key = {}
  for i = 1, #indexed_objects do
    local entry = indexed_objects[i]
    local object_path = string.format('%s.%s', tostring(path), tostring(entry.key))
    local parsed, parsed_err = parseObjectEntry(raw[entry.key], object_path)
    if not parsed then
      return nil, nil, tostring(parsed_err)
    end
    local family_key = familyKeyFor(parsed.oldObject)
    local family = families_by_key[family_key]
    if not family then
      family = newFamily(parsed.oldObject)
      families_by_key[family_key] = family
      families[#families + 1] = family
    end
    local _, action_err = appendObjectCandidates(family, raw[entry.key], entry.key, object_path)
    if action_err then
      return nil, nil, tostring(action_err)
    end
  end
  table.sort(families, function(left, right)
    local left_id = familyStableId(left.oldObject)
    local right_id = familyStableId(right.oldObject)
    return left_id < right_id
  end)
  for i = 1, #families do table.sort(families[i].candidates, compareCandidates) end
  return module_id, families, nil
end

local function sourceNode(path, module_id, family, candidate, position)
  local managed = not canUseSimpleGrouping(family)
  local conflict = nil
  if managed then
    conflict = {
      group = managedConflictGroupId(module_id),
      mode = 'durable-exclusive',
      groupBy = 'record_id',
      familySignatures = {
        [familyKeyFor(family.oldObject)] = managedFamilySignature(position, candidate),
      },
    }
  end
  return source_ir.sourceActionOwned({
    attach = {{
      candidate.select and candidate.select.cell or '*',
      candidate.oldObject,
      candidate.newObject,
    }},
    disableOriginal = true,
    chance = candidate.chance,
  }, {
    source = {
      adapterId = M.id,
      file = normalizePath(path),
      variant = 'dor:' .. tostring(module_id),
      path = candidate.sourcePath,
    },
    diagnosticId = normalizePath(path) .. '#compat:dor:dor:' .. tostring(candidate.identityHint),
    family = 'place_ref',
    priority = managed and managedCandidatePriority(position) or nil,
    conflict = conflict,
  })
end

local function buildSourceActions(path, module_id, families)
  local actions = {}
  for i = 1, #families do
    local family = families[i]
    for position = 1, #family.candidates do
      actions[#actions + 1] = sourceNode(
        path,
        module_id,
        family,
        family.candidates[position],
        position
      )
    end
  end
  return actions
end

function M.translateSource(source)
  local path = source and source.path or nil
  if not M.matchesPath(path) then return nil, false end
  local module_id, families, err = parseFamilies(path, source and source.config or nil)
  if not module_id then return nil, true, compatError('invalid-dor-config', err) end
  return buildSourceActions(path, module_id, families), true
end

return M
