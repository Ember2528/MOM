-- Canonical declarative meaning shared by semantic planning and both lowerers.
-- This module has no catalog or runtime dependencies: record facts are resolved
-- only by the selected backend after the common plan has been placed.
local M = {}
local authored = require('scripts.mom.compiler.authored_contract')
local keyed = require('scripts.mom.compiler.keyed_targets')
local tables = require('scripts.mom.common.tables')
local tuple = require('scripts.mom.compiler.tuple_contract')
local selectors = require('scripts.mom.contracts.ref_selector')
local predicates = require('scripts.mom.contracts.predicate')
local model_path = require('scripts.mom.contracts.model_path')
local allTypes, writableTypes = {}, {}
for _, name in ipairs(require('scripts.mom.contracts.ref_type').names()) do allTypes[name:lower()] = name end
for name, spec in pairs(require('scripts.mom.contracts.content_types')) do
  if spec.fields.model then writableTypes[name] = true end
end

function M.verb(action)
  if not tables.isObject(action) then return nil, 'expected action object' end
  local found
  for _, key in ipairs(authored.verbKeys) do
    if action[key] ~= nil then
      if found then return nil, 'multiple verb keys found: ' .. found .. ' and ' .. key end
      found = key
    end
  end
  if not found then return nil, 'no verb key found (expected one of: ' .. table.concat(authored.verbKeys, ', ') .. ')' end
  return found
end

local function types(value)
  if type(value) == 'string' then value = {value} end
  if not tables.isArray(value) or #value == 0 then return nil end
  local out = {}
  for _, name in ipairs(value) do
    local normalized = type(name) == 'string' and allTypes[name:lower()]
    if not normalized then return nil end
    out[normalized] = true
  end
  return out
end
M.types = types
local function writable(value)
  if value == nil then return false end
  for name in pairs(value) do if not writableTypes[name] then return false end end
  return true
end
function M.intersectTypes(left, right)
  if left == nil then return right end
  if right == nil then return left end
  local out = {}
  for name in pairs(left) do if right[name] then out[name] = true end end
  return out
end
local intersect = M.intersectTypes
local function empty(value)
  return value == nil or (tables.isArray(value) and next(value) == nil)
end

-- Pure equivalence of the unrestricted spellings in the ordinary cell grammar.
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
      if key ~= 'recordId' and key ~= 'type' and key ~= 'mwscript' then return nil, 'reference query' end
      values[key] = value
    end
  end
  if next(values) == nil then return nil end
  return selectors.normalize(values, path)
end

local function modelTarget(value)
  if type(value) == 'string' then
    if not value:lower():match('%.nif$') then return nil end
    return model_path.normalize(value)
  end
  if type(value) ~= 'table' or value.choose == nil then return nil end
  local target, outcome = require('scripts.mom.contracts.replacement_choice').constant(value, 'replacement')
  if outcome ~= 'target' or not target or target.targetKind ~= 'model_path' then return nil end
  return target.targetValue
end

function M.uniformModel(action, path)
  if type(action) == 'table' and action.transferContents ~= nil and type(action.transferContents) ~= 'boolean' then return nil end
  if type(action) ~= 'table' or action.disableOriginal ~= true or not empty(action.actions)
      or (action.chance ~= nil and action.chance ~= 1)
      or (action.previsit ~= nil and action.previsit ~= false) or action.conflict ~= nil then return nil end
  local excluded, exclusionError = exclusionSet(action.filters, path and (path .. '.filters') or 'filters')
  if excluded == nil then return nil, exclusionError end
  local select = action.select or {}
  if not tables.isObject(select) or not unrestrictedCell(select.cell) then return nil end
  local outerQuery, queryError = pureQuery(select, 'select')
  if queryError then return nil end
  local outer = select.type ~= nil and types(select.type) or nil
  if select.type ~= nil and not outer then return nil end
  if not tables.isArray(action.attach) or #action.attach == 0 then return nil end
  local rows = {}
  for index, row in ipairs(action.attach) do
    if not tables.isArray(row) or #row < 3 or not unrestrictedCell(row[1]) then return nil end
    local argEnd = tuple.attachArgumentEnd(row)
    if argEnd > 4 then return nil end -- Supplied rotation changes the effect, even when zero.
    if argEnd == 4 then
      if not tables.isArray(row[4]) or #row[4] ~= 3 then return nil end
      for i = 1, 3 do if row[4][i] ~= 0 then return nil end end
    end
    local rowExcluded = {}
    for id in pairs(excluded) do rowExcluded[id] = true end
    for pi = argEnd + 1, #row do
      local predicate = predicates.compileTuple(row[pi], 'attach[' .. index .. '][' .. pi .. ']')
      if not predicates.isRecordIdExclude(predicate) then return nil end
      for id in pairs(predicate.excludedIds or {}) do rowExcluded[id] = true end
    end
    local model = modelTarget(row[3])
    if not model then return nil end
    local own, source, rowQuery = nil, row[2], nil
    if type(source) == 'table' then
      rowQuery, queryError = pureQuery(source, 'attach[' .. index .. '].source')
      if queryError or not rowQuery then return nil end
      own = source.type ~= nil and types(source.type) or nil
      if source.type ~= nil and not own then return nil end
      local ids = rowQuery.recordId
      if ids == nil or #ids ~= 1 or rowQuery.matches ~= nil then return nil end
      source = ids[1]
    end
    local parsed = keyed.parseSelectorKey(source)
    if not parsed or parsed.sourcePosition ~= nil then return nil end
    local domain = intersect(outer, own)
    if not writable(domain) then return nil end
    local query = selectors.intersect(outerQuery, rowQuery)
    rows[index] = {source = parsed, types = domain, model = model,
      query = query, excluded = rowExcluded,
      noop = rowExcluded[parsed.sourceValue] == true and parsed.sourceKeyKind == 'record_id'
        or parsed.sourceKeyKind == 'model_path' and parsed.sourceValue == model}
  end
  return {rows = rows}
end

return M
