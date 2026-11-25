-- Shared VFR module-header validation and content-gate helpers.
local M = {}

local tables = require('scripts.mom.common.tables')
local isArray = tables.isArray
local isInteger = require('scripts.mom.common.numbers').isInteger

local INT32_MIN = -2147483648
local INT32_MAX = 2147483647

function M.id(value)
  return type(value) == 'string' and value:match('%S') and value:lower() or nil
end

function M.integer(value, low, high)
  return isInteger(value) and value >= low and value <= high
end

function M.int32(value)
  return M.integer(value, INT32_MIN, INT32_MAX)
end

function M.fields(value, allowed)
  return type(value) == 'table' and tables.validateAllowedKeys(value, allowed) == nil
end

function M.contentNames(value)
  if value == nil then return nil end
  if type(value) == 'string' then value = {value} end
  if not isArray(value) then return nil, 'invalid content conditions' end
  local out = {}
  for _, name in ipairs(value) do
    local normalized = M.id(name)
    if not normalized then return nil, 'invalid content conditions' end
    out[#out + 1] = normalized
  end
  return out
end

function M.mergeContentNames(first, second)
  if first == nil and second == nil then return nil end
  local out, seen = {}, {}
  local function append(list)
    if type(list) ~= 'table' then return end
    for i = 1, #list do
      local name = list[i]
      if not seen[name] then
        seen[name] = true
        out[#out + 1] = name
      end
    end
  end
  append(first)
  append(second)
  return #out > 0 and out or nil
end

function M.validateModuleHeader(raw)
  if raw.name ~= nil and type(raw.name) ~= 'string' then
    return nil, 'name: expected string'
  end
  if raw.enabled ~= nil and type(raw.enabled) ~= 'boolean' then
    return nil, 'enabled: expected boolean'
  end
  if raw.priority ~= nil and not M.int32(raw.priority) then
    return nil, 'priority: expected 32-bit integer'
  end
  local required, reqErr = M.contentNames(raw.require_content)
  if reqErr then return nil, 'require_content: ' .. reqErr end
  local excluded, excErr = M.contentNames(raw.exclude_content)
  if excErr then return nil, 'exclude_content: ' .. excErr end
  return {
    enabled = raw.enabled ~= false,
    priority = raw.priority,
    requires = required,
    requiresNot = excluded,
  }
end

return M
