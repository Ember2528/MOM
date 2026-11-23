-- Foreign list syntax ends here. Ordinary leveled actions enter the same
-- compiler, target policies and content planner as native declarations.
local M = {}
local source_ir = require('scripts.mom.compiler.source_ir')
local tables = require('scripts.mom.common.tables')
local array = tables.isArray
local isInteger = require('scripts.mom.common.numbers').isInteger

local function id(value)
  return type(value) == 'string' and value:match('%S') and value:lower() or nil
end
local function integer(value, low, high)
  return isInteger(value) and value >= low and value <= high
end
local function fields(value, allowed)
  return type(value) == 'table' and tables.validateAllowedKeys(value, allowed) == nil
end
local function contentNames(value)
  if value == nil then return nil end
  if type(value) == 'string' then value = {value} end
  if not array(value) then return nil, 'invalid content conditions' end
  local out = {}
  for _, name in ipairs(value) do
    name = id(name)
    if not name then return nil, 'invalid content conditions' end
    out[#out + 1] = name
  end
  return out
end
local MODULE_FIELDS = {name = true, enabled = true, priority = true,
  require_content = true, exclude_content = true, injections = true}
local RULE_FIELDS = {list = true, add = true}
local ENTRY_FIELDS = {id = true, level = true}

function M.validate(raw, path)
  path = tostring(path or 'VFR leveled creatures')
  if not fields(raw, MODULE_FIELDS) or not array(raw.injections)
      or (raw.enabled ~= nil and type(raw.enabled) ~= 'boolean')
      or (raw.priority ~= nil and not integer(raw.priority, -2147483648, 2147483647)) then
    return nil, path .. ': invalid module fields, priority, enabled, or injections array'
  end
  local _, requiredError = contentNames(raw.require_content)
  local _, excludedError = contentNames(raw.exclude_content)
  if requiredError or excludedError then return nil, path .. ': invalid content conditions' end
  return true
end

local function validRule(rule)
  if not fields(rule, RULE_FIELDS) or not id(rule.list)
      or not array(rule.add) or #rule.add == 0 then return false end
  for _, entry in ipairs(rule.add) do
    if not fields(entry, ENTRY_FIELDS) or not id(entry.id)
        or not integer(entry.level, 0, 65535) then return false end
  end
  return true
end

function M.translate(raw, path)
  path = tostring(path or 'VFR leveled creatures'):gsub('\\', '/')
  local valid, err = M.validate(raw, path)
  if not valid then return {}, nil, {err .. '; skipped'} end
  if raw.enabled == false then return {} end
  local required = contentNames(raw.require_content)
  local excluded = contentNames(raw.exclude_content)
  local actions, diagnostics = {}, {}
  for index, rule in ipairs(raw.injections) do
    local location = path .. '#' .. index
    if not validRule(rule) then
      diagnostics[#diagnostics + 1] = location .. ': invalid injection; entire rule skipped'
    else
      local entries = {}
      for _, entry in ipairs(rule.add) do entries[#entries + 1] = {id = id(entry.id), level = entry.level} end
      actions[#actions + 1] = source_ir.sourceActionOwned({
        admission = {requires = required, requiresNot = excluded},
        onMissingTarget = 'skip',
        leveled = {type = 'CreatureLevelledList', id = id(rule.list),
          operations = {{op = 'merge_by_id', entries = entries}}},
      }, {
        family = 'leveled_content', diagnosticId = location,
        source = {adapterId = 'vfr', file = path, variant = 'vfr:leveled_creatures',
          path = {'injections', index}}, priority = 0,
        compositionOrder = {1, raw.priority or 0, path:lower(), index},
      })
    end
  end
  return actions, nil, diagnostics
end

return M
