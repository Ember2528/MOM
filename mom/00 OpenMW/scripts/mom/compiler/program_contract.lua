local M = {}

local validationHelpers = {}

local function errorPrefix(actionId)
  return 'action:' .. tostring(actionId or 'action') .. '.program'
end

function validationHelpers.appendError(errors, actionId, message)
  errors[#errors + 1] = errorPrefix(actionId) .. ': ' .. tostring(message)
end

function validationHelpers.set(values)
  local out = {}
  for i = 1, #values do
    out[values[i]] = true
  end
  return out
end

function validationHelpers.rejectUnknownKeys(program, allowed, errors, actionId)
  for key in pairs(program) do
    if not allowed[key] then
      validationHelpers.appendError(errors, actionId, tostring(key) .. ': not allowed')
    end
  end
end

function validationHelpers.requireArray(value, path, errors, actionId)
  if value == nil then return nil end
  if type(value) ~= 'table' then
    validationHelpers.appendError(errors, actionId, path .. ': expected array')
    return nil
  end
  for key in pairs(value) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then
      validationHelpers.appendError(errors, actionId, path .. '.' .. tostring(key) .. ': array keys must be positive integers')
      return nil
    end
  end
  return value
end

function validationHelpers.requireNonEmptyArray(value, path, errors, actionId)
  local array = validationHelpers.requireArray(value, path, errors, actionId)
  if array ~= nil and #array == 0 then
    validationHelpers.appendError(errors, actionId, path .. ': expected at least one entry')
  end
  return array
end

function validationHelpers.requireString(value, path, errors, actionId)
  if type(value) ~= 'string' or value == '' then
    validationHelpers.appendError(errors, actionId, path .. ': expected non-empty string')
    return nil
  end
  return value
end

function validationHelpers.requireObject(value, path, errors, actionId)
  if type(value) ~= 'table' then
    validationHelpers.appendError(errors, actionId, path .. ': expected object')
    return nil
  end
  return value
end

function validationHelpers.rejectUnknownObjectKeys(value, allowed, path, errors, actionId)
  if type(value) ~= 'table' then return end
  for key in pairs(value) do
    if not allowed[key] then
      validationHelpers.appendError(errors, actionId, path .. '.' .. tostring(key) .. ': not allowed')
    end
  end
end

local function validateActionProgram(program, compiler, actionId, errors)
  local validateProgram = compiler and compiler.validateProgram or nil
  if validateProgram == nil then
    return
  end
  local ok, err = pcall(validateProgram, program, errors, actionId, validationHelpers)
  if not ok then
    validationHelpers.appendError(errors, actionId, 'validateProgram failed: ' .. tostring(err))
  end
end

local function validateObject(program, actionId, errors)
  if type(program) ~= 'table' then
    validationHelpers.appendError(errors, actionId, 'expected object')
    return false
  end
  return true
end

function M.validateWithCompiler(program, actionId, compiler)
  local errors = {}
  if validateObject(program, actionId, errors) then
    validateActionProgram(program, compiler, actionId, errors)
  end
  if #errors > 0 then return nil, errors end
  return true, nil
end

return M
