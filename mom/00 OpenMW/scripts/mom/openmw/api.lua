-- OpenMW API namespaces can be userdata; pure tests supply table-backed
-- namespaces. Accept both representations at the engine boundary.
local M = {}

function M.isNamespace(value)
  local valueType = type(value)
  return valueType == 'table' or valueType == 'userdata'
end

function M.dependency(dependencies, key, moduleName)
  if dependencies[key] ~= nil then return dependencies[key], nil end
  local ok, value = pcall(require, moduleName)
  if not ok then return nil, tostring(value) end
  return value, nil
end

function M.call(fn, ...)
  if type(fn) ~= 'function' then return nil, 'engine function is unavailable' end
  local ok, first, second, third = pcall(fn, ...)
  if not ok then return nil, tostring(first) end
  return first, second, third
end

local function indexField(value, key)
  return value[key]
end

function M.property(value, key)
  local ok, result = pcall(indexField, value, key)
  if not ok then return nil, tostring(result) end
  return result, nil
end

function M.readCall(fn, label, ...)
  if type(fn) ~= 'function' then return nil, tostring(label) .. ' is unavailable' end
  local ok, first, second = pcall(fn, ...)
  if not ok then return nil, tostring(first) end
  if first == nil and second ~= nil then return nil, tostring(second) end
  return first, nil
end

function M.invoke(fn, label, ...)
  if type(fn) ~= 'function' then return nil, tostring(label) .. ' is unavailable' end
  local ok, first, second = pcall(fn, ...)
  if not ok then return nil, tostring(first) end
  if first == false or (first == nil and second ~= nil) then
    return nil, tostring(second or (tostring(label) .. ' failed'))
  end
  return true, nil
end

return M
