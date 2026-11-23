-- Cross-layer plain-data validation for source inputs, manifests, runtime
-- messages, and saved ledgers. It has no compiler, runtime, or OpenMW imports.
local M = {}

-- Plain-data boundaries reject metatables; raw traversal needs no __pairs
-- dispatch (or OpenMW's fallback allocation for ordinary tables).
local MAX_DEPTH = 128

local function appendError(errors, path, message)
  errors[#errors + 1] = tostring(path) .. ': ' .. tostring(message)
end

local function finiteNumber(value)
  return value == value and value ~= math.huge and value ~= -math.huge
end

local function formatPath(rootPath, keys, depth)
  if depth == 0 then return tostring(rootPath) end
  local parts = {tostring(rootPath)}
  for i = 1, depth do
    local key = keys[i]
    if type(key) == 'number' then
      parts[#parts + 1] = '[' .. tostring(key) .. ']'
    else
      parts[#parts + 1] = '.' .. tostring(key)
    end
  end
  return table.concat(parts)
end

local function tableShape(value)
  local numericCount = 0
  local maxIndex = 0
  local stringCount = 0
  for key in next, value do
    local keyType = type(key)
    if keyType == 'number' then
      if key < 1 or key % 1 ~= 0 or key ~= key or key == math.huge then
        return 'mixed'
      end
      numericCount = numericCount + 1
      if key > maxIndex then maxIndex = key end
    elseif keyType == 'string' then
      stringCount = stringCount + 1
    end
  end
  if numericCount > 0 then
    if stringCount > 0 or maxIndex ~= numericCount then
      return 'mixed'
    end
    return 'array'
  end
  return 'object'
end

local function inspectTable(value)
  local numericCount = 0
  local maxIndex = 0
  local stringCount = 0
  local hasNonStringNonNumber = false
  for key in next, value do
    local keyType = type(key)
    if keyType == 'number' then
      if key < 1 or key % 1 ~= 0 or key ~= key or key == math.huge then
        return 'mixed', false
      end
      numericCount = numericCount + 1
      if key > maxIndex then maxIndex = key end
    elseif keyType == 'string' then
      stringCount = stringCount + 1
    else
      hasNonStringNonNumber = true
    end
  end
  if numericCount > 0 then
    if stringCount > 0 or hasNonStringNonNumber or maxIndex ~= numericCount then
      return 'mixed', false
    end
    return 'array', false
  end
  return 'object', hasNonStringNonNumber
end

local function sortedStringKeys(value)
  local keys = {}
  for key in next, value do
    if type(key) == 'string' then
      keys[#keys + 1] = key
    end
  end
  if #keys > 1 then table.sort(keys) end
  return keys
end

local function findFirstPath(root, rootPath, target, seen, keys, depth)
  if root == target then return formatPath(rootPath, keys, depth) end
  if type(root) ~= 'table' or getmetatable(root) ~= nil or seen[root] then
    return nil
  end
  seen[root] = true
  local shape, badKeys = inspectTable(root)
  if shape == 'array' then
    for i = 1, #root do
      keys[depth + 1] = i
      local found = findFirstPath(root[i], rootPath, target, seen, keys, depth + 1)
      if found ~= nil then return found end
    end
  elseif shape == 'object' and not badKeys then
    local sorted = sortedStringKeys(root)
    for i = 1, #sorted do
      local key = sorted[i]
      keys[depth + 1] = key
      local found = findFirstPath(root[key], rootPath, target, seen, keys, depth + 1)
      if found ~= nil then return found end
    end
  end
  return nil
end

local validateValue

local function validateTable(value, state, depth)
  if getmetatable(value) ~= nil then
    appendError(state.errors, formatPath(state.rootPath, state.keys, depth), 'metatables are not allowed')
    return
  end
  if state.seen[value] ~= nil then
    local firstPath = findFirstPath(state.root, state.rootPath, value, {}, {}, 0) or state.rootPath
    appendError(
      state.errors,
      formatPath(state.rootPath, state.keys, depth),
      'table is already referenced at ' .. tostring(firstPath)
    )
    return
  end
  state.seen[value] = true
  if depth > state.maxDepth then
    appendError(state.errors, formatPath(state.rootPath, state.keys, depth), 'maximum nesting depth exceeded')
    return
  end

  local shape, hasInvalidKey = inspectTable(value)
  if shape == 'mixed' then
    appendError(state.errors, formatPath(state.rootPath, state.keys, depth), 'tables must be dense arrays or string-keyed objects')
    return
  end

  if shape == 'array' then
    local nextDepth = depth + 1
    for i = 1, #value do
      state.keys[nextDepth] = i
      validateValue(value[i], state, nextDepth)
    end
    return
  end

  if hasInvalidKey then
    local path = formatPath(state.rootPath, state.keys, depth)
    for key in next, value do
      if type(key) ~= 'string' then
        appendError(state.errors, path, 'object keys must be strings, got ' .. type(key))
      end
    end
    return
  end

  local nextDepth = depth + 1
  for key, child in next, value do
    state.keys[nextDepth] = key
    validateValue(child, state, nextDepth)
  end
end

validateValue = function(value, state, depth)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'string' then
    return
  end
  if kind == 'number' then
    if not finiteNumber(value) then
      appendError(state.errors, formatPath(state.rootPath, state.keys, depth), 'numbers must be finite')
    end
    return
  end
  if kind == 'table' then
    validateTable(value, state, depth)
    return
  end
  appendError(state.errors, formatPath(state.rootPath, state.keys, depth), kind .. ' values are not allowed')
end

function M.validate(value, opts)
  opts = opts or {}
  local state = {
    root = value,
    rootPath = opts.path or 'value',
    keys = {},
    errors = {},
    seen = {},
    maxDepth = tonumber(opts.maxDepth) or MAX_DEPTH,
  }
  validateValue(value, state, 0)
  if #state.errors > 0 then
    if #state.errors > 1 then table.sort(state.errors) end
    return nil, state.errors
  end
  return true, nil
end

local detachValue

local function detachTable(value, state, depth)
  if getmetatable(value) ~= nil then
    appendError(state.errors, formatPath(state.rootPath, state.keys, depth), 'metatables are not allowed')
    return nil
  end
  local activeDepth = state.active[value]
  if activeDepth ~= nil then
    appendError(
      state.errors,
      formatPath(state.rootPath, state.keys, depth),
      'cycle references ' .. formatPath(state.rootPath, state.keys, activeDepth)
    )
    return nil
  end
  if depth > state.maxDepth then
    appendError(state.errors, formatPath(state.rootPath, state.keys, depth), 'maximum nesting depth exceeded')
    return nil
  end
  local shape, hasInvalidKey = inspectTable(value)
  if shape == 'mixed' then
    appendError(state.errors, formatPath(state.rootPath, state.keys, depth), 'tables must be dense arrays or string-keyed objects')
    return nil
  end
  state.active[value] = depth
  local out = {}
  local nextDepth = depth + 1
  if shape == 'array' then
    for i = 1, #value do
      state.keys[nextDepth] = i
      out[i] = detachValue(value[i], state, nextDepth)
    end
  elseif hasInvalidKey then
    local path = formatPath(state.rootPath, state.keys, depth)
    for key in next, value do
      if type(key) ~= 'string' then
        appendError(state.errors, path, 'object keys must be strings, got ' .. type(key))
      end
    end
  else
    for key, child in next, value do
      state.keys[nextDepth] = key
      out[key] = detachValue(child, state, nextDepth)
    end
  end
  state.active[value] = nil
  return out
end

detachValue = function(value, state, depth)
  local kind = type(value)
  if kind == 'nil' or kind == 'boolean' or kind == 'string' then return value end
  if kind == 'number' then
    if not finiteNumber(value) then
      appendError(state.errors, formatPath(state.rootPath, state.keys, depth), 'numbers must be finite')
      return nil
    end
    return value
  end
  if kind == 'table' then
    return detachTable(value, state, depth)
  end
  appendError(state.errors, formatPath(state.rootPath, state.keys, depth), kind .. ' values are not allowed')
  return nil
end

-- Copies compiler inputs into a tree. Shared source tables are duplicated,
-- while cycles and runtime values remain invalid.
function M.detach(value, opts)
  opts = opts or {}
  local state = {
    rootPath = opts.path or 'value',
    keys = {},
    active = {},
    errors = {},
    maxDepth = tonumber(opts.maxDepth) or MAX_DEPTH,
  }
  local out = detachValue(value, state, 0)
  if #state.errors > 0 then
    if #state.errors > 1 then table.sort(state.errors) end
    return nil, state.errors
  end
  return out, nil
end

local function cloneValidated(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, child in next, value do out[key] = cloneValidated(child) end
  return out
end

-- Fast isolation copy for trees that already passed plain-data validation.
M.cloneValidated = cloneValidated

local function equalValidated(left, right)
  if left == right then return true end
  local kind = type(left)
  if kind ~= type(right) or kind ~= 'table' then return false end
  local leftCount = 0
  for key, value in next, left do
    leftCount = leftCount + 1
    if not equalValidated(value, right[key]) then return false end
  end
  local rightCount = 0
  for _ in next, right do rightCount = rightCount + 1 end
  return leftCount == rightCount
end

-- Allocation-free equality for trees that already passed plain-data
-- validation. Durable fingerprints still belong to canonical.lua; this is for
-- transient comparisons whose digest would be discarded immediately.
M.equalValidated = equalValidated

M.shape = tableShape
M.sortedStringKeys = sortedStringKeys

return M
