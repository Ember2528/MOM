-- Authoritative harness state exposed through the orchestrator interface.
local M = {}

local values = {}
local available = true

function M.read(program)
  if not available then return nil, 'harness toggle provider unavailable' end
  local key = type(program) == 'table' and program.key or nil
  if type(key) ~= 'string' or key == '' then return nil, 'harness toggle key is invalid' end
  local value = values[key]
  if type(value) ~= 'boolean' then return nil, 'harness toggle state is unavailable' end
  return value, nil
end

function M.set(key, value)
  if type(key) ~= 'string' or key == '' or type(value) ~= 'boolean' then
    return nil, 'harness toggle update is invalid'
  end
  values[key] = value
  return true, nil
end

function M.setAvailable(value)
  available = value == true
end

function M.reset()
  values = {}
  available = true
end

return M
