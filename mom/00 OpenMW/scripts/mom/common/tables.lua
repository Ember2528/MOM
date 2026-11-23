local M = {}
local next = next
local EMPTY_TABLE = {}

--- Shallow-copy a dense array.
function M.copyArray(values)
  local out = {}
  for i = 1, #(values or EMPTY_TABLE) do
    out[i] = values[i]
  end
  return out
end

--- Compare dense arrays, treating nil and false as empty arrays.
function M.sameArray(left, right)
  if #(left or EMPTY_TABLE) ~= #(right or EMPTY_TABLE) then return false end
  for i = 1, #(left or EMPTY_TABLE) do
    if left[i] ~= right[i] then return false end
  end
  return true
end

--- Shallow-copy a hash table or mixed table.
function M.copyObject(value)
  local out = {}
  for key, entry in pairs(value or EMPTY_TABLE) do
    out[key] = entry
  end
  return out
end

--- Return the keys of a table in ascending order.
function M.sortedKeys(values)
  local out = {}
  for key in pairs(values or EMPTY_TABLE) do
    out[#out + 1] = key
  end
  table.sort(out)
  return out
end

--- Return true when a table has at least one nonnumeric key.
function M.hasNamedKeys(value)
  for key in pairs(value or EMPTY_TABLE) do
    if type(key) ~= 'number' then return true end
  end
  return false
end

--- Return true for a dense 1-based array table.
function M.isArray(value)
  if type(value) ~= 'table' then return false end
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = count + 1
    if key > maximum then maximum = key end
  end
  return count == maximum
end

--- Return true for an object-like table, including an empty table.
function M.isObject(value)
  return type(value) == 'table' and (next(value) == nil or M.hasNamedKeys(value))
end

--- Format a child field path for diagnostics.
function M.fieldPath(path, key)
  if type(key) == 'string' then
    return tostring(path) .. '.' .. key
  end
  return tostring(path) .. '[' .. tostring(key) .. ']'
end

--- Return an unknown-key diagnostic for object-like validation, or nil.
function M.validateAllowedKeys(value, allowedKeys, path)
  for key in pairs(value or EMPTY_TABLE) do
    if not allowedKeys[key] then
      return string.format('%s: is not allowed', M.fieldPath(path, key))
    end
  end
  return nil
end

--- Describe the shape of a value for diagnostic messages.
--- Returns 'array', 'object', 'table', or the Lua type name.
function M.describeShape(value)
  if type(value) ~= 'table' then return type(value) end
  local hasArray = false
  local hasMap = false
  for key in pairs(value) do
    if type(key) == 'number' then hasArray = true else hasMap = true end
  end
  if hasArray and not hasMap then return 'array' end
  if hasMap and not hasArray then return 'object' end
  return 'table'
end

return M
