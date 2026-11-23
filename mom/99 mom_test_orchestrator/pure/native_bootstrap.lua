-- The host prepends original source bytes, module paths and argv. This loader
-- supplies test package/loadfile behavior; compilation and execution belong to
-- the selected OpenMW engine, including its native compiler and bindings.
local core = require('openmw.core')
local util = require('openmw.util')
local finished = false

local function run()
  print('MOM pure runtime: ' .. tostring(_VERSION))
  local authority = select('sandbox.bypass')
  local environment = setmetatable({
    arg = arguments,
    package = {loaded = {}, preload = {}, path = ''},
    collectgarbage = assert(authority.collectgarbage, 'pure native lane requires real GC authority'),
  }, {__index = _G})
  environment._G = environment
  local package = environment.package
  local loading = {}

  function environment.loadfile(path)
    local source = sources[path]
    if source == nil then return nil, 'source file is unavailable: ' .. tostring(path) end
    local ok, result = pcall(util.loadCode, source, environment)
    if not ok then return nil, tostring(path) .. ': ' .. tostring(result) end
    -- loadCode derives its chunk name from the source text. Keep those bytes
    -- intact and attach the snapshot path at the loader boundary instead.
    local function finish(succeeded, ...)
      if not succeeded then error(tostring(path) .. ': ' .. tostring((...)), 0) end
      return ...
    end
    return function(...)
      return finish(pcall(result, ...))
    end
  end

  function environment.require(name)
    assert(package.loaded[name] ~= loading,
      "loop or previous error loading module '" .. tostring(name) .. "'")
    if package.loaded[name] then return package.loaded[name] end
    local loader = package.preload[name]
    if loader == nil then
      local path = assert(modules[name], 'module not found: ' .. tostring(name))
      loader = assert(environment.loadfile(path))
    end
    package.loaded[name] = loading
    local result = loader(name)
    if result ~= nil then package.loaded[name] = result end
    if package.loaded[name] == loading then package.loaded[name] = true end
    return package.loaded[name]
  end

  package.preload['pure.source_files'] = function()
    return {
      read = function(path)
        if sources[path] == nil then return nil, 'source file is unavailable' end
        return sources[path]
      end,
      exists = function(path) return sources[path] ~= nil end,
      luaFiles = function(root)
        local prefix, files = root .. '/', {}
        for path in pairs(sources) do
          if path:sub(1, #prefix) == prefix and path:sub(-4) == '.lua' then
            files[#files + 1] = path
          end
        end
        table.sort(files)
        return files
      end,
    }
  end
  assert(environment.loadfile(arguments[1] .. '/mom/99 mom_test_orchestrator/pure/run.lua'))()
end

return {
  engineHandlers = {
    onUpdate = function()
      if finished then return end
      finished = true
      local ok, failure = pcall(run)
      if not ok then print('MOM pure contract failure: ' .. tostring(failure)) end
      print('MOM_PURE_RESULT:' .. (ok and 'passed' or 'failed'))
      core.quit()
    end,
  },
}
