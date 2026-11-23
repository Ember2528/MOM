-- Shared numeric/scalar matching dispatch used by time, weather, and quest_stage guards.
-- Supports operators: eq, any, not, range, min, max.
local M = {}
local isArray = require('scripts.mom.common.tables').isArray

local function anyMatch(value, allowed)
  for i = 1, #allowed do
    if value == tonumber(allowed[i]) then return true end
  end
  return false
end

local function matchesRange(value, rangeSpec, fieldName, wrapRange)
  assert(type(rangeSpec) == 'table', fieldName .. '.range must be an object')
  local fromValue = assert(tonumber(rangeSpec.from), fieldName .. '.range requires from')
  local toValue = assert(tonumber(rangeSpec.to), fieldName .. '.range requires to')
  local inclusive = rangeSpec.inclusive ~= false
  if value == nil then return false end
  if fromValue <= toValue or not wrapRange then
    if inclusive then
      return value >= fromValue and value <= toValue
    end
    return value >= fromValue and value < toValue
  end
  -- Wrap-around range (e.g. hour 22..6 meaning evening-to-morning)
  if inclusive then
    return value >= fromValue or value <= toValue
  end
  return value >= fromValue or value < toValue
end

--- Match a numeric value against a scalar spec.
--- @param value number|nil The value to match.
--- @param spec table|nil The spec (e.g. {eq=5}, {any={1,2}}, {range={from=1,to=5}}).
--- @param fieldName string Label for error messages.
--- @param opts table|nil Options: wrapRange (boolean) enables wrap-around range matching.
--- @return boolean
function M.matchesScalar(value, spec, fieldName, opts)
  if spec == nil then return true end
  assert(type(spec) == 'table', fieldName .. ' must be an object')
  if spec.eq ~= nil then
    return value == tonumber(spec.eq)
  end
  if spec.any ~= nil then
    assert(type(spec.any) == 'table', fieldName .. '.any must be an array')
    return anyMatch(value, spec.any)
  end
  if spec["not"] ~= nil then
    assert(type(spec["not"]) == 'table', fieldName .. '.not must be an array')
    return not anyMatch(value, spec["not"])
  end
  if spec.range ~= nil then
    return matchesRange(value, spec.range, fieldName, opts and opts.wrapRange)
  end
  if spec.min ~= nil then
    return value ~= nil and value >= tonumber(spec.min)
  end
  if spec.max ~= nil then
    return value ~= nil and value <= tonumber(spec.max)
  end
  error(fieldName .. ' requires one of eq, any, not, range, min, or max')
end

local function parseInteger(value, path)
  local num = tonumber(value)
  if num == nil or num ~= math.floor(num) then
    return nil, path .. ': expected integer'
  end
  return num, nil
end

local function parseRangeMode(value, path)
  if value == nil or value == 'inclusive' then return true, nil end
  if value == 'exclusive' then return false, nil end
  return nil, path .. ': expected inclusive or exclusive'
end

--- Lower a compact tuple into a scalar spec.
--- Tuple layout: [guardType, field?, op, value|[values], to?, rangeMode?].
--- Range modes are 'inclusive' (default) and 'exclusive'.
--- @param tuple table The compact tuple.
--- @param path string Error path prefix.
--- @param opIndex number Index of the operator in the tuple (e.g. 3 for [type, field, op, ...]).
--- @return table|nil spec  The normalized scalar spec (e.g. {eq=5}).
--- @return string|nil err  Error message if parsing failed.
function M.lowerScalarTuple(tuple, path, opIndex)
  local op = tuple[opIndex]
  if type(op) ~= 'string' or op == '' then
    return nil, path .. '[' .. tostring(opIndex) .. ']: expected operator string'
  end
  local argIndex = opIndex + 1
  if op == 'eq' or op == 'min' or op == 'max' then
    local value, err = parseInteger(tuple[argIndex], path .. '[' .. tostring(argIndex) .. ']')
    if not value then return nil, err end
    if tuple[argIndex + 1] ~= nil then
      return nil, path .. ': ' .. tostring(op) .. ' tuple is too long'
    end
    return { [op] = value }, nil
  end
  if op == 'any' or op == 'not' then
    if not isArray(tuple[argIndex]) then
      return nil, path .. '[' .. tostring(argIndex) .. ']: expected numeric array'
    end
    local values = {}
    for i, rawValue in ipairs(tuple[argIndex]) do
      local parsed, err = parseInteger(rawValue, path .. '[' .. tostring(argIndex) .. '][' .. tostring(i) .. ']')
      if not parsed then return nil, err end
      values[#values + 1] = parsed
    end
    if #values == 0 then
      return nil, path .. '[' .. tostring(argIndex) .. ']: expected at least one number'
    end
    if tuple[argIndex + 1] ~= nil then
      return nil, path .. ': ' .. tostring(op) .. ' tuple is too long'
    end
    return { [op] = values }, nil
  end
  if op == 'range' then
    local fromValue, fromErr = parseInteger(tuple[argIndex], path .. '[' .. tostring(argIndex) .. ']')
    if not fromValue then return nil, fromErr end
    local toIndex = argIndex + 1
    local toValue, toErr = parseInteger(tuple[toIndex], path .. '[' .. tostring(toIndex) .. ']')
    if not toValue then return nil, toErr end
    local modeIndex = toIndex + 1
    local inclusive, modeErr = parseRangeMode(tuple[modeIndex], path .. '[' .. tostring(modeIndex) .. ']')
    if inclusive == nil then return nil, modeErr end
    if tuple[modeIndex + 1] ~= nil then
      return nil, path .. ': range tuple is too long'
    end
    return {
      range = {
        from = fromValue,
        to = toValue,
        inclusive = inclusive,
      },
    }, nil
  end
  return nil, path .. '[' .. tostring(opIndex) .. ']: unsupported operator ' .. tostring(op)
end

M.parseInteger = parseInteger
M.parseRangeMode = parseRangeMode

return M
