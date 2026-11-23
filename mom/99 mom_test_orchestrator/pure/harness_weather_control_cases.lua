-- Exercise the harness weather control against OpenMW's hidden transition queue.
local M = {}
local test_support = require('pure.test_support')
local expect = test_support.expect

local function queuedOppositeWeatherIsDrained(injectRegionTransition)
  local clear, rain, thunder = {scriptId = 0}, {scriptId = 4}, {scriptId = 5}
  local cell = {isExterior = true, region = 'west gash region'}
  local state = {current = clear, next = rain, queued = clear, time = 100,
    advanceQueued = false, fastForwardDelay = nil, fastForwardCount = 0}
  local core = {
    regions = {records = {['west gash region'] = {id = 'west gash region'}}},
    getGameTime = function() return state.time end,
    getRealTime = function() return 0 end,
    weather = {
      records = {clear, rain, thunder},
      getCurrent = function() return state.current end,
      getNext = function() return state.next end,
      changeWeather = function(_, requested)
        if state.next == nil and requested ~= state.current then
          state.next = requested
        elseif state.next ~= nil and requested ~= state.next then
          state.queued = requested
        end
      end,
    },
  }
  local substitutions = {
    ['scripts.mom_test_orchestrator.constants'] = {DEFAULT_TIMEOUT_FRAMES = 50, LONG_TIMEOUT_FRAMES = 50},
    ['scripts.mom_test_orchestrator.support.values'] = {
      normalizeRecordId = function(value) return value and tostring(value):lower() end,
    },
    ['scripts.mom_test_orchestrator.support.world'] = {currentCell = function() return cell end},
    ['openmw_aux.calendar'] = {},
    ['openmw.core'] = core,
    ['openmw.types'] = {},
    ['openmw.world'] = {advanceTime = function(hours)
      state.advanceQueued = hours
    end},
  }
  local moduleName = 'scripts.mom_test_orchestrator.support.control'
  local previous = {[moduleName] = package.loaded[moduleName]}
  for name, value in pairs(substitutions) do
    previous[name] = package.loaded[name]
    package.loaded[name] = value
  end
  package.loaded[moduleName] = nil
  local ok, failure = xpcall(function()
    local control = require(moduleName)
    local task = coroutine.create(function() control.changeWeather('west gash region', 4) end)
    for _ = 1, 20 do
      local resumed, reason = coroutine.resume(task)
      expect(resumed, tostring(reason))
      if coroutine.status(task) == 'dead' then break end
      -- OpenMW queues advanceTime; weather's fast-forward is applied on a
      -- later world update, not when the Lua call is scheduled.
      if state.fastForwardDelay ~= nil then
        state.fastForwardDelay = state.fastForwardDelay - 1
        if state.fastForwardDelay == 0 then
          state.current = state.queued or state.next or state.current
          state.next, state.queued = nil, nil
          state.fastForwardDelay = nil
          state.fastForwardCount = state.fastForwardCount + 1
          -- A new regional weather update can begin just after the first
          -- queued transition is drained.
          if injectRegionTransition and state.fastForwardCount == 1 then
            state.next = thunder
          end
        end
      end
      if state.advanceQueued then
        state.time = state.time + state.advanceQueued * 3600
        state.advanceQueued, state.fastForwardDelay = false, 2
      end
    end
    expect(coroutine.status(task) == 'dead', 'weather request did not finish')
    expect(state.fastForwardCount >= (injectRegionTransition and 2 or 1)
        and state.queued == nil,
      'weather request accepted rain while an older clear remained queued')
    expect((state.next or state.current).scriptId == 4,
      'weather request did not leave rain as the effective weather')
    state.current, state.next = state.next or state.current, nil
    expect(state.current.scriptId == 4 and state.queued == nil,
      'queued clear replaced rain after helper readiness')
  end, test_support.traceback)
  package.loaded[moduleName] = previous[moduleName]
  for name in pairs(substitutions) do package.loaded[name] = previous[name] end
  if not ok then error(failure, 0) end
end

function M.run()
  return test_support.runCases('pure harness weather control', {
    {'queued opposite weather is drained', function() queuedOppositeWeatherIsDrained(false) end},
    {'queued opposite weather is drained after transition', function() queuedOppositeWeatherIsDrained(true) end},
  }, {auditPolicy = 'every_commit'})
end

return M
