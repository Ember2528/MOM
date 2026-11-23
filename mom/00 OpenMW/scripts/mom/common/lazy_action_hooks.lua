-- Built-in descriptors expose compiler metadata during discovery. Resolve
-- their explicitly listed native runtime hooks together at first activation;
-- bound executors then call those functions directly, without lazy wrappers.
local M = {}

function M.bind(descriptor, moduleName, hooks)
  return setmetatable(descriptor, {
    __index = function(self, key)
      if hooks[key] == nil then return nil end
      local runtime = require(moduleName)
      for name, source in pairs(hooks) do
        rawset(self, name, runtime[source == true and name or source])
      end
      setmetatable(self, nil)
      return rawget(self, key)
    end,
  })
end

return M
