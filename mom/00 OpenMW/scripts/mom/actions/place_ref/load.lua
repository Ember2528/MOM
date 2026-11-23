-- Action-owned compile-time LOAD promotion, interference footprint, and
-- definition lowering for place_ref (`attach`).
--
-- Untyped or mixed-domain uniform model replacements split cleanly across
-- disjoint record-type domains:
--   LOAD:   all 12 LOAD-writable model types in contracts/content_types.lua
--   GLOBAL: complementary runtime-only types (Container, Creature)
local M = {}

local content_types = require('scripts.mom.contracts.content_types')
local schema = require('scripts.mom.compiler.content.schema')
local keyed = require('scripts.mom.compiler.keyed_targets')
local model_path = require('scripts.mom.contracts.model_path')
local predicates = require('scripts.mom.contracts.predicate')
local ref_type = require('scripts.mom.contracts.ref_type')
local replacement_choice = require('scripts.mom.contracts.replacement_choice')
local selectors = require('scripts.mom.contracts.ref_selector')
local tables = require('scripts.mom.common.tables')
local tuple = require('scripts.mom.compiler.tuple_contract')

local ALL_TYPES = {}
for _, name in ipairs(ref_type.names()) do ALL_TYPES[name:lower()] = name end

local LOAD_MODEL_TYPES = {}
for name, spec in pairs(content_types) do
  if spec.fields and spec.fields.model then LOAD_MODEL_TYPES[name] = true end
end

local GLOBAL_RUNTIME_TYPES = {
  Container = true,
  Creature = true,
}

local MODEL_FIELDS = {
  attach = true, select = true, disableOriginal = true, id = true,
  filters = true, chance = true, previsit = true, onMissingTarget = true,
  key = true, transferContents = true,
}

M.LOAD_MODEL_TYPES = LOAD_MODEL_TYPES
M.GLOBAL_RUNTIME_TYPES = GLOBAL_RUNTIME_TYPES

local function parseTypes(value)
  if type(value) == 'string' then value = {value} end
  if not tables.isArray(value) or #value == 0 then return nil end
  local out = {}
  for _, name in ipairs(value) do
    local normalized = type(name) == 'string' and ALL_TYPES[name:lower()]
    if not normalized then return nil end
    out[normalized] = true
  end
  return out
end

local function intersectTypes(left, right)
  if left == nil then return right end
  if right == nil then return left end
  local out = {}
  for name in pairs(left) do
    if right[name] then out[name] = true end
  end
  return out
end

local function copySet(set)
  local out = {}
  for key, value in pairs(set) do out[key] = value end
  return out
end

local function splitTypeDomain(domain)
  if domain == nil then
    return copySet(LOAD_MODEL_TYPES), copySet(GLOBAL_RUNTIME_TYPES)
  end
  local loadSet, globalSet = {}, {}
  for name in pairs(domain) do
    if LOAD_MODEL_TYPES[name] then
      loadSet[name] = true
    else
      globalSet[name] = true
    end
  end
  return loadSet, globalSet
end

local function isEmpty(value)
  return value == nil or (tables.isArray(value) and next(value) == nil)
end

local function unrestrictedCell(cell)
  if cell == nil or cell == '*' then return true end
  if not tables.isObject(cell) then return false end
  for key in pairs(cell) do if key ~= 'match' then return false end end
  if cell.match == nil or cell.match == '*' then return true end
  if tables.isArray(cell.match) then
    for _, value in ipairs(cell.match) do if value == '*' then return true end end
  end
  return false
end

local function exclusionSet(raw, path)
  local compiled, err = tuple.compileFilters(raw, path)
  if err then return nil, err end
  local out = {}
  for _, value in ipairs(compiled or {}) do
    if not predicates.isRecordIdExclude(value) then return nil end
    for id in pairs(value.excludedIds or {}) do out[id] = true end
  end
  return out
end

local function pureQuery(raw, path)
  if raw == nil or next(raw) == nil then return nil end
  local values = {}
  for key, value in pairs(raw) do
    if key ~= 'cell' then
      if key ~= 'recordId' and key ~= 'type' and key ~= 'mwscript' then
        return nil, 'reference query'
      end
      values[key] = value
    end
  end
  if next(values) == nil then return nil end
  return selectors.normalize(values, path)
end

local function modelTarget(value)
  if type(value) == 'string' then
    if not value:lower():match('%.nif$') then return nil end
    return model_path.normalize(value), false
  end
  if type(value) ~= 'table' or value.choose == nil then return nil end
  local target, outcome = replacement_choice.constant(value, 'replacement')
  if outcome ~= 'target' or not target or target.targetKind ~= 'model_path' then
    return nil
  end
  return target.targetValue, true
end

local function parseSourceRef(value)
  if type(value) == 'table' then
    local ids = value.recordId
    if type(ids) == 'table' and tables.isArray(ids) and #ids == 1 then ids = ids[1] end
    local parsed = keyed.parseSelectorKey(ids)
    return parsed, value.type ~= nil and parseTypes(value.type) or nil
  end
  return keyed.parseSelectorKey(value), nil
end

-- Analyzes whether an authored attach action is eligible for LOAD promotion
-- or disjoint LOAD/GLOBAL domain splitting.
function M.analyzeLoad(node, opts)
  opts = opts or {}
  local spec = type(node) == 'table' and node.spec or nil
  if type(spec) ~= 'table' or spec.attach == nil then return nil end
  if opts.guarded or opts.isChild or node.guardOwner ~= nil then return nil end
  if opts.conflict ~= nil or node.conflict ~= nil or spec.conflict ~= nil then return nil end
  if opts.hasChildren or #(node.children or {}) > 0 or not isEmpty(spec.actions) then return nil end
  if spec.transferContents ~= nil and type(spec.transferContents) ~= 'boolean' then return nil end
  if spec.disableOriginal ~= true
      or (spec.chance ~= nil and spec.chance ~= 1)
      or (spec.previsit ~= nil and spec.previsit ~= false) then
    return nil
  end
  local path = opts.path or tostring(node.diagnosticId or 'attach')
  local excluded, exclusionError = exclusionSet(spec.filters, path .. '.filters')
  if excluded == nil then return nil, exclusionError end
  local selectSpec = spec.select or {}
  if not tables.isObject(selectSpec) or not unrestrictedCell(selectSpec.cell) then return nil end
  local outerQuery, queryError = pureQuery(selectSpec, 'select')
  if queryError then return nil end
  local outer = selectSpec.type ~= nil and parseTypes(selectSpec.type) or nil
  if selectSpec.type ~= nil and not outer then return nil end
  if not tables.isArray(spec.attach) or #spec.attach == 0 then return nil end

  local rows = {}
  local anyLoad, anyGlobal, hasChoice = false, false, false
  for index, row in ipairs(spec.attach) do
    if not tables.isArray(row) or #row < 3 or not unrestrictedCell(row[1]) then return nil end
    local argEnd = tuple.attachArgumentEnd(row)
    if argEnd > 4 then return nil end -- Supplied rotation changes runtime effect.
    if argEnd == 4 then
      if not tables.isArray(row[4]) or #row[4] ~= 3 then return nil end
      for i = 1, 3 do if row[4][i] ~= 0 then return nil end end
    end
    local rowExcluded = copySet(excluded)
    for pi = argEnd + 1, #row do
      local predicate = predicates.compileTuple(row[pi], 'attach[' .. index .. '][' .. pi .. ']')
      if not predicates.isRecordIdExclude(predicate) then return nil end
      for id in pairs(predicate.excludedIds or {}) do rowExcluded[id] = true end
    end
    local model, rowIsChoice = modelTarget(row[3])
    if not model then return nil end
    hasChoice = hasChoice or rowIsChoice
    local own, source, rowQuery = nil, row[2], nil
    if type(source) == 'table' then
      rowQuery, queryError = pureQuery(source, 'attach[' .. index .. '].source')
      if queryError or not rowQuery then return nil end
      own = source.type ~= nil and parseTypes(source.type) or nil
      if source.type ~= nil and not own then return nil end
      local ids = rowQuery.recordId
      if ids == nil or #ids ~= 1 or rowQuery.matches ~= nil then return nil end
      source = ids[1]
    end
    local parsed = keyed.parseSelectorKey(source)
    if not parsed or parsed.sourcePosition ~= nil then return nil end
    local domain = intersectTypes(outer, own)
    if domain ~= nil and next(domain) == nil then return nil end
    local loadSet, globalSet = splitTypeDomain(domain)
    if next(loadSet) ~= nil then anyLoad = true end
    if next(globalSet) ~= nil then anyGlobal = true end
    local query = selectors.intersect(outerQuery, rowQuery)
    rows[index] = {
      source = parsed,
      types = loadSet,
      globalTypes = globalSet,
      allTypes = domain,
      model = model,
      query = query,
      excluded = rowExcluded,
      noop = (rowExcluded[parsed.sourceValue] == true and parsed.sourceKeyKind == 'record_id')
        or (parsed.sourceKeyKind == 'model_path' and parsed.sourceValue == model),
    }
  end

  if not anyLoad then return nil end
  local mode = anyGlobal and 'split' or 'promotable'
  return {
    mode = mode,
    rows = rows,
    choice = hasChoice,
  }
end

-- Declares pre-edit record/model reads when this action runs in GLOBAL.
function M.readFootprint(node)
  local spec = type(node) == 'table' and node.spec or nil
  if type(spec) ~= 'table' or spec.attach == nil then
    return {reads = {}, choice = false}
  end
  local reads, choice = {}, false
  local outer = spec.select and spec.select.type ~= nil and parseTypes(spec.select.type) or nil
  for _, row in ipairs(type(spec.attach) == 'table' and spec.attach or {}) do
    if type(row) == 'table' and #row >= 3 then
      local parsed, ownTypes = parseSourceRef(row[2])
      if parsed then
        reads[#reads + 1] = {
          source = parsed,
          types = intersectTypes(outer, ownTypes),
        }
      end
      if type(row[3]) == 'table' and row[3].choose ~= nil then choice = true end
    end
  end
  return {reads = reads, choice = choice}
end

-- Lowers the LOAD half of a promoted or split uniform-model attach action.
function M.compileLoad(node, loadCtx)
  local spec = node.spec
  local source = loadCtx.source
  if type(spec) ~= 'table' or type(spec.attach) ~= 'table'
      or node.guardOwner ~= nil or node.conflict ~= nil or #(node.children or {}) > 0 then
    return nil, source .. ': invalid selected model-definition action'
  end
  local ok, err = schema.object(spec, MODEL_FIELDS, source)
  if not ok then return nil, err end
  if spec.id ~= nil and type(spec.id) ~= 'string' then
    return nil, source .. '.id: expected string'
  end
  local descriptor, descriptorError = M.analyzeLoad(node, {path = source})
  if not descriptor then
    return nil, descriptorError or (source .. ': invalid uniform model definition')
  end
  local isSplit = descriptor.mode == 'split' or loadCtx.decision == 'split'
  local nodes, seen = {}, {}
  for index, row in ipairs(descriptor.rows) do
    if next(row.types) ~= nil then
      local path = source .. '.attach[' .. tostring(index) .. ']'
      local targets, targetError = loadCtx.lookup(row.source, row.types, {
        allowEmpty = isSplit,
      })
      if not targets then return nil, path .. ': ' .. tostring(targetError) end
      for _, target in ipairs(targets) do
        local script
        if row.query and row.query.mwscript and schema.types[target.type].fields.mwscript then
          script, err = schema.lookup(target.record, 'mwscript')
          if err then return nil, path .. ': cannot read MWScript: ' .. err end
        end
        if not row.excluded[target.id] and (row.query == nil
            or selectors.matchesRecord(row.query, target.id, target.type, script)) then
          local key = target.type .. '\0' .. target.id
          if seen[key] then
            return nil, path .. ': model rows overlap source record ' .. target.id
          end
          seen[key] = true
          nodes[#nodes + 1] = {
            kind = 'record',
            source = path,
            priority = node.priority,
            order = loadCtx.nextOrder(),
            compositionOrder = node.compositionOrder,
            payload = {type = target.type, id = target.id, patch = {model = row.model}},
          }
        end
      end
    end
  end
  return nodes
end

return M
