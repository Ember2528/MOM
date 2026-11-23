-- Deliberate subset of existing LOAD draft fields. A namespace alone never
-- grants a new record domain or arbitrary fields to authored configuration.
local M = {}
local model_path = require('scripts.mom.contracts.model_path')
M.types = require('scripts.mom.contracts.content_types')
M.payloadFields = {
  record = {type = true, id = true, patch = true, create = true, template = true},
  leveled = {type = true, id = true, patch = true, operations = true},
}
M.finite = require('scripts.mom.common.numbers').isFinite
function M.integer(value, low, high)
  return M.finite(value) and value % 1 == 0 and value >= low and value <= high
end
function M.id(value, allowEmpty)
  if type(value) ~= 'string' or (not allowEmpty and not value:find('%S')) then return nil end
  if value:find('[%z\1-\31]') then return nil end
  return value:lower()
end
function M.array(value)
  if type(value) ~= 'table' or getmetatable(value) ~= nil then return false end
  local count = 0
  for key in pairs(value) do
    if not M.integer(key, 1, #value) then return false end
    count = count + 1
  end
  return count == #value
end
function M.object(value, allowed, path)
  if type(value) ~= 'table' or getmetatable(value) ~= nil then return nil, path .. ': expected object' end
  for key in pairs(value) do
    if type(key) ~= 'string' or not allowed[key] then return nil, path .. '.' .. tostring(key) .. ': unknown field' end
  end
  return true
end
local function percent(value)
  -- Decimal hundredths must survive their binary representation (0.29 * 100
  -- can be just below 29). The epsilon only covers representation noise.
  return math.floor(value * 100 + 0.000000001) / 100
end
local function capacity(value) return math.floor(value * 10 + 0.5) / 10 end
function M.value(kind, value, path)
  if kind == 'string' then
    if type(value) ~= 'string' then return nil, path .. ': expected string' end
  elseif kind == 'id' then
    value = M.id(value, true)
    if value == nil then return nil, path .. ': expected record ID string' end
  elseif kind == 'model' then
    if type(value) ~= 'string' or not value:find('%S') then return nil, path .. ': expected model path' end
    value = model_path.normalize(value)
  elseif kind == 'icon' then
    if type(value) ~= 'string' then return nil, path .. ': expected icon path' end
    value = value:lower():gsub('\\', '/')
    if value ~= '' and not value:match('^icons/') then value = 'icons/' .. value end
  elseif kind == 'boolean' then
    if type(value) ~= 'boolean' then return nil, path .. ': expected boolean' end
  elseif kind == 'nonnegative' then
    if not M.finite(value) or value < 0 or value > 3.4028234e38 then
      return nil, path .. ': expected nonnegative finite float'
    end
  elseif kind == 'nonnegative_integer' then
    if not M.integer(value, 0, 2147483647) then return nil, path .. ': expected integer in [0, 2147483647]' end
  elseif kind == 'duration' then
    if not M.integer(value, -1, 2147483647) then return nil, path .. ': expected integer duration >= -1' end
  elseif kind == 'color' then
    if not M.integer(value, 0, 16777215) then return nil, path .. ': expected packed RGB integer in [0, 16777215]' end
  elseif kind == 'capacity' then
    -- Both existing parsers convert through float32 before writing int32
    -- tenths. This is the largest float32 capacity whose scaled value fits.
    if not M.finite(value) or value < 0 or value > 214748352 then
      return nil, path .. ': expected enchant capacity in [0, 214748352]'
    end
    value = capacity(value)
  elseif kind == 'probability' then
    if not M.finite(value) or value < 0 or value > 1 then return nil, path .. ': expected probability in [0, 1]' end
    value = percent(value)
  else
    return nil, path .. ': unsupported field validator'
  end
  return value, nil
end
function M.patch(typeName, raw, path, modelExists)
  local spec = M.types[typeName]
  if not spec then return nil, path .. ': unsupported content type ' .. tostring(typeName) end
  local ok, err = M.object(raw, spec.fields, path)
  if not ok then return nil, err end
  local out = {}
  for key, value in pairs(raw) do
    local normalized, valueError = M.value(spec.fields[key], value, path .. '.' .. key)
    if valueError then return nil, valueError end
    if key == 'model' and modelExists then
      local exists, resolved, reason = modelExists(normalized)
      if exists ~= true then return nil, path .. '.model: ' .. tostring(reason or 'model is unavailable') end
      normalized = resolved or normalized
    end
    out[key] = normalized
  end
  return out, nil
end
-- Native collections and records may throw from indexing. Keep that host
-- boundary separate from field normalization (notably packed Light color).
function M.lookup(object, key)
  local ok, value = pcall(function() return object[key] end)
  if not ok then return nil, tostring(value) end
  return value
end
function M.read(record, field)
  local value, err = M.lookup(record, field)
  if err then return nil, err end
  if field == 'color' and value ~= nil and type(value) ~= 'number' then
    local converted, number = pcall(function()
      return math.floor(value.r * 255 + 0.5) + math.floor(value.g * 255 + 0.5) * 256
        + math.floor(value.b * 255 + 0.5) * 65536
    end)
    if not converted then return nil, 'color components are unavailable' end
    value = number
  end
  return value, nil
end
function M.effective(field, value)
  if field == 'chanceNone' then return percent(value) end
  if field == 'enchantCapacity' then return capacity(value) end
  return value
end
function M.nativeValue(field, value)
  -- Older engines truncate float32 percentages; newer parsers truncate double
  -- percentages. An interior value gives both the same intended stored byte.
  if field == 'chanceNone' and value < 1 then return value + 0.005 end
  return value
end
-- Round to the actual float32 storage domain. Comparing rounded values keeps
-- representable one-ULP edits while tolerating only conversion noise.
function M.float32(value)
  if value == 0 then return 0 end
  local sign, magnitude = value < 0 and -1 or 1, math.abs(value)
  local exponent = math.floor(math.log(magnitude) / math.log(2))
  local power = 2 ^ exponent
  if power > magnitude then exponent = exponent - 1
  elseif magnitude >= power * 2 then exponent = exponent + 1 end
  local quantum = 2 ^ math.max(exponent - 23, -149)
  local scaled = magnitude / quantum
  local rounded = math.floor(scaled)
  local remainder = scaled - rounded
  if remainder > 0.5 or (remainder == 0.5 and rounded % 2 ~= 0) then rounded = rounded + 1 end
  return sign * rounded * quantum
end
local function capacityReadbacks(value)
  local scaled = M.float32(value) * 10
  local oldStorage = math.floor(M.float32(scaled) + 0.5)
  local newStorage = math.floor(scaled + 0.5)
  local tenth = M.float32(0.1)
  return M.float32(M.float32(oldStorage) * tenth), M.float32(M.float32(newStorage) * tenth)
end
local FLOAT_FIELDS = {weight = true, quality = true, chanceNone = true}
function M.equal(field, actual, desired, raw)
  if not raw then desired = M.effective(field, desired) end
  if not raw and type(actual) == 'number' and type(desired) == 'number' then
    if field == 'enchantCapacity' then
      local oldRead, newRead = capacityReadbacks(desired)
      return M.float32(actual) == oldRead or M.float32(actual) == newRead
    end
    if FLOAT_FIELDS[field] then return M.float32(actual) == M.float32(desired) end
  end
  if type(actual) == 'table' and type(desired) == 'table' then
    if #actual ~= #desired then return false end
    for i = 1, #desired do
      if actual[i].id:lower() ~= desired[i].id:lower() or actual[i].level ~= desired[i].level then return false end
    end
    return true
  end
  return actual == desired or ((actual == nil or actual == '') and desired == '')
end
function M.unchanged(field, actual, desired)
  if field == 'enchantCapacity' and type(actual) == 'number' then
    local oldRead, newRead = capacityReadbacks(M.effective(field, desired))
    -- A value that either supported parser could change is staged. The actual
    -- parser then determines its verified result; neither representable edit
    -- may disappear through a permissive cross-version comparison.
    return M.float32(actual) == oldRead and M.float32(actual) == newRead
  end
  return M.equal(field, actual, desired)
end
function M.store(content, typeName)
  local spec = M.types[typeName]
  if not spec then return nil, 'unsupported content type ' .. tostring(typeName) end
  local ok, records = pcall(function() return content[spec.namespace].records end)
  if not ok or records == nil then return nil, 'content.' .. spec.namespace .. '.records is unavailable' end
  return records, nil
end
function M.entries(record, field)
  local ok, result = pcall(function()
    local out = {}
    for _, entry in ipairs(record[field]) do out[#out + 1] = {id = tostring(entry.id):lower(), level = entry.level} end
    return out
  end)
  if not ok then return nil, tostring(result) end
  return result
end
return M
