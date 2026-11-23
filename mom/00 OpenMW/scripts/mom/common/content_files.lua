local M = {}

function M.activeSet(files)
  local has = files and files.has
  if type(has) == 'function' then
    -- LuaJIT can initialize core before content loading: its list is an eager
    -- snapshot, while has() reads the final engine list. Query membership once
    -- per requested name in this compiler invocation instead of enumerating it.
    return setmetatable({}, {__index = function(active, name)
      local present = has(name)
      assert(type(present) == 'boolean', 'contentFiles.has must return a boolean')
      rawset(active, name, present)
      return present
    end})
  end
  local list = files and files.list
  assert(list ~= nil, 'active content-file API is unavailable')
  local active = {}
  for _, name in ipairs(list) do active[name:lower()] = true end
  return active
end

return M
