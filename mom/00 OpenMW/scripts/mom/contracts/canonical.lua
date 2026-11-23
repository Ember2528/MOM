-- Cross-layer canonical plain-data encoding and semantic fingerprints.
local M = {}

local plain_data = require('scripts.mom.contracts.plain_data')
local strings = require('scripts.mom.common.strings')

local HASH_PREFIX = 'mom64:'
local HASH_HEX_LENGTH = 16
local DEFAULT_MAX_DEPTH = 128

local function encodeString(value)
  return 's' .. tostring(#value) .. ':' .. value
end

local function encodeNumber(value)
  if value == 0 then return 'd0;' end
  return 'd' .. string.format('%.17g', value) .. ';'
end

local function finiteNumber(value)
  return value == value and value ~= math.huge and value ~= -math.huge
end

local function classifyAndCollectKeys(value)
  local numericCount = 0
  local maxIndex = 0
  local keys = nil
  local keyCount = 0
  for key in next, value do
    local keyType = type(key)
    if keyType == 'number' then
      if key < 1 or key % 1 ~= 0 or key ~= key or key == math.huge then
        return nil, nil
      end
      numericCount = numericCount + 1
      if key > maxIndex then maxIndex = key end
    elseif keyType == 'string' then
      if keys == nil then keys = {} end
      keyCount = keyCount + 1
      keys[keyCount] = key
    else
      return nil, nil
    end
  end
  if numericCount > 0 then
    if keyCount > 0 or maxIndex ~= numericCount then return nil, nil end
    return 'array', numericCount
  end
  if keyCount > 1 then table.sort(keys) end
  return 'object', keys
end

local encodeValidatedValue
local hashValidatedValue
local validateAndEncodeValue
local validateAndHashValue

local function hashFragment(state, value)
  state.primary, state.secondary = strings.advanceHashBytes(
    state.primary,
    state.secondary,
    value
  )
end

local function encodeValidatedTable(value, out)
  local shape, meta = classifyAndCollectKeys(value)
  if shape == 'array' then
    out[#out + 1] = 'a' .. tostring(meta) .. '['
    for i = 1, meta do
      encodeValidatedValue(value[i], out)
    end
    out[#out + 1] = ']'
    return
  end
  local count = meta ~= nil and #meta or 0
  out[#out + 1] = 'o' .. tostring(count) .. '{'
  for i = 1, count do
    local key = meta[i]
    out[#out + 1] = encodeString(key)
    encodeValidatedValue(value[key], out)
  end
  out[#out + 1] = '}'
end

encodeValidatedValue = function(value, out)
  local kind = type(value)
  if kind == 'nil' then
    out[#out + 1] = 'z;'
  elseif kind == 'boolean' then
    out[#out + 1] = value and 'b1;' or 'b0;'
  elseif kind == 'number' then
    out[#out + 1] = encodeNumber(value)
  elseif kind == 'string' then
    out[#out + 1] = encodeString(value)
  else
    encodeValidatedTable(value, out)
  end
end

local function hashValidatedTable(value, state)
  local shape, meta = classifyAndCollectKeys(value)
  if shape == 'array' then
    hashFragment(state, 'a' .. tostring(meta) .. '[')
    for i = 1, meta do
      hashValidatedValue(value[i], state)
    end
    hashFragment(state, ']')
    return
  end
  local count = meta ~= nil and #meta or 0
  hashFragment(state, 'o' .. tostring(count) .. '{')
  for i = 1, count do
    local key = meta[i]
    hashFragment(state, encodeString(key))
    hashValidatedValue(value[key], state)
  end
  hashFragment(state, '}')
end

hashValidatedValue = function(value, state)
  local kind = type(value)
  if kind == 'nil' then
    hashFragment(state, 'z;')
  elseif kind == 'boolean' then
    hashFragment(state, value and 'b1;' or 'b0;')
  elseif kind == 'number' then
    hashFragment(state, encodeNumber(value))
  elseif kind == 'string' then
    hashFragment(state, encodeString(value))
  else
    hashValidatedTable(value, state)
  end
end

validateAndEncodeValue = function(value, out, seen, depth, maxDepth)
  local kind = type(value)
  if kind == 'nil' then
    out[#out + 1] = 'z;'
    return true
  elseif kind == 'boolean' then
    out[#out + 1] = value and 'b1;' or 'b0;'
    return true
  elseif kind == 'number' then
    if not finiteNumber(value) then return false end
    out[#out + 1] = encodeNumber(value)
    return true
  elseif kind == 'string' then
    out[#out + 1] = encodeString(value)
    return true
  elseif kind ~= 'table' then
    return false
  end
  if getmetatable(value) ~= nil or seen[value] ~= nil or depth > maxDepth then
    return false
  end
  seen[value] = true
  local shape, meta = classifyAndCollectKeys(value)
  if shape == nil then return false end
  local nextDepth = depth + 1
  if shape == 'array' then
    out[#out + 1] = 'a' .. tostring(meta) .. '['
    for i = 1, meta do
      if not validateAndEncodeValue(value[i], out, seen, nextDepth, maxDepth) then
        return false
      end
    end
    out[#out + 1] = ']'
    return true
  end
  local count = meta ~= nil and #meta or 0
  out[#out + 1] = 'o' .. tostring(count) .. '{'
  for i = 1, count do
    local key = meta[i]
    out[#out + 1] = encodeString(key)
    if not validateAndEncodeValue(value[key], out, seen, nextDepth, maxDepth) then
      return false
    end
  end
  out[#out + 1] = '}'
  return true
end

validateAndHashValue = function(value, state, seen, depth, maxDepth)
  local kind = type(value)
  if kind == 'nil' then
    hashFragment(state, 'z;')
    return true
  elseif kind == 'boolean' then
    hashFragment(state, value and 'b1;' or 'b0;')
    return true
  elseif kind == 'number' then
    if not finiteNumber(value) then return false end
    hashFragment(state, encodeNumber(value))
    return true
  elseif kind == 'string' then
    hashFragment(state, encodeString(value))
    return true
  elseif kind ~= 'table' then
    return false
  end
  if getmetatable(value) ~= nil or seen[value] ~= nil or depth > maxDepth then
    return false
  end
  seen[value] = true
  local shape, meta = classifyAndCollectKeys(value)
  if shape == nil then return false end
  local nextDepth = depth + 1
  if shape == 'array' then
    hashFragment(state, 'a' .. tostring(meta) .. '[')
    for i = 1, meta do
      if not validateAndHashValue(value[i], state, seen, nextDepth, maxDepth) then
        return false
      end
    end
    hashFragment(state, ']')
    return true
  end
  local count = meta ~= nil and #meta or 0
  hashFragment(state, 'o' .. tostring(count) .. '{')
  for i = 1, count do
    local key = meta[i]
    hashFragment(state, encodeString(key))
    if not validateAndHashValue(value[key], state, seen, nextDepth, maxDepth) then
      return false
    end
  end
  hashFragment(state, '}')
  return true
end

function M.encode(value, opts)
  local maxDepth = tonumber(opts and opts.maxDepth) or DEFAULT_MAX_DEPTH
  local out = {}
  if not validateAndEncodeValue(value, out, {}, 0, maxDepth) then
    local _, errors = plain_data.validate(value, opts)
    return nil, errors
  end
  return table.concat(out), nil
end

function M.hash(value, opts)
  local maxDepth = tonumber(opts and opts.maxDepth) or DEFAULT_MAX_DEPTH
  local primary, secondary = strings.beginHashLanes()
  local state = {
    primary = primary,
    secondary = secondary,
  }
  if not validateAndHashValue(value, state, {}, 0, maxDepth) then
    local _, errors = plain_data.validate(value, opts)
    return nil, errors
  end
  return HASH_PREFIX .. strings.formatHashLanes(
    state.primary,
    state.secondary
  ), nil
end

-- Hashes a tree whose plain-data ownership and shape were already established
-- by its boundary. This avoids both a second validation traversal and the
-- complete canonical string allocation on internal trusted paths.
function M.hashValidated(value)
  local primary, secondary = strings.beginHashLanes()
  local state = {
    primary = primary,
    secondary = secondary,
  }
  hashValidatedValue(value, state)
  return HASH_PREFIX .. strings.formatHashLanes(
    state.primary,
    state.secondary
  )
end

function M.formatHashLanes(primary, secondary)
  return HASH_PREFIX .. strings.formatHashLanes(primary, secondary)
end

function M.assertHash(value, opts)
  local hash, errors = M.hash(value, opts)
  if hash then return hash end
  error('canonical hash failed: ' .. table.concat(errors or {}, ' | '), 2)
end

function M.assertHashValidated(value)
  return M.hashValidated(value)
end

-- Extracts a canonical fingerprint's digest for use in a namespaced identity.
function M.hashBody(fingerprint)
  if type(fingerprint) ~= 'string'
      or fingerprint:sub(1, #HASH_PREFIX) ~= HASH_PREFIX then
    return nil, 'expected current canonical fingerprint prefix ' .. HASH_PREFIX
  end
  local body = fingerprint:sub(#HASH_PREFIX + 1)
  if #body ~= HASH_HEX_LENGTH or body:find('[^0-9a-f]') ~= nil then
    return nil, 'expected ' .. tostring(HASH_HEX_LENGTH)
      .. ' lowercase hexadecimal fingerprint characters'
  end
  return body, nil
end

function M.assertHashBody(fingerprint)
  local body, bodyError = M.hashBody(fingerprint)
  if body ~= nil then return body end
  error('canonical hash body failed: ' .. tostring(bodyError), 2)
end

M.HASH_PREFIX = HASH_PREFIX

return M
