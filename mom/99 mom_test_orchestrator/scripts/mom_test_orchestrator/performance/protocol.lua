local M = {}

local arrayMarker = {}
local objectMarker = {}

function M.array(values)
  return setmetatable(values or {}, arrayMarker)
end

function M.object(values)
  return setmetatable(values or {}, objectMarker)
end

local function jsonString(value)
  return '"' .. value:gsub('[%z\1-\31\\"]', function(char)
    local escapes = {
      ['\\'] = '\\\\',
      ['"'] = '\\"',
      ['\b'] = '\\b',
      ['\f'] = '\\f',
      ['\n'] = '\\n',
      ['\r'] = '\\r',
      ['\t'] = '\\t',
    }
    return escapes[char] or string.format('\\u%04x', string.byte(char))
  end) .. '"'
end

local function arrayLength(value)
  local count, largest = 0, 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then return nil end
    count = count + 1
    if key > largest then largest = key end
  end
  if count ~= largest then return nil end
  return largest
end

local function encode(value, visiting)
  local kind = type(value)
  if kind == 'nil' then return 'null' end
  if kind == 'boolean' then return value and 'true' or 'false' end
  if kind == 'string' then return jsonString(value) end
  if kind == 'number' then
    assert(value == value and value ~= math.huge and value ~= -math.huge,
      'JSON does not support non-finite numbers')
    return string.format('%.17g', value)
  end
  assert(kind == 'table', 'JSON does not support ' .. kind)
  assert(not visiting[value], 'JSON does not support cyclic tables')
  visiting[value] = true

  local metatable = getmetatable(value)
  local length = nil
  if metatable ~= objectMarker then length = arrayLength(value) end
  if metatable == arrayMarker then
    length = assert(arrayLength(value), 'marked JSON array is not contiguous')
  end

  local out = {}
  if length ~= nil then
    for i = 1, length do out[i] = encode(value[i], visiting) end
    visiting[value] = nil
    return '[' .. table.concat(out, ',') .. ']'
  end

  local keys = {}
  for key in pairs(value) do
    assert(type(key) == 'string', 'JSON object keys must be strings')
    keys[#keys + 1] = key
  end
  table.sort(keys)
  for i = 1, #keys do
    local key = keys[i]
    out[i] = jsonString(key) .. ':' .. encode(value[key], visiting)
  end
  visiting[value] = nil
  return '{' .. table.concat(out, ',') .. '}'
end

function M.encode(value)
  return encode(value, {})
end

function M.write(runtime, path, value)
  assert(type(runtime) == 'table' and type(runtime.writeAtomic) == 'function',
    'performance runtime with atomic writer is required')
  assert(type(path) == 'string' and path ~= '', 'performance result path is required')
  return runtime:writeAtomic(path, M.encode(value) .. '\n')
end

return M
