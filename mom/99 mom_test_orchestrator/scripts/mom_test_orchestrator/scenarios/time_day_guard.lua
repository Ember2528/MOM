local calendar = require('openmw_aux.calendar')
local world = require('openmw.world')

local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local TIME_DAY_POT_RECORD_ID = 'misc_de_pot_redware_01'
local TIME_DAY_POT_POSITION = {
  x = -309.471,
  y = 959.126,
  z = -163.704,
}
local TIME_DAY_POT_TOLERANCE = 8
local M = {
  id = 'time_day_guard',
  description = 'Day-level time guards toggle an Eight Plates target on weekend boundaries.',
}

local function currentWeekday()
  local parts = calendar.formatGameTime('*t')
  return tonumber(parts and parts.wday) or 0
end

local function isWeekend()
  local weekday = currentWeekday()
  return weekday == 1 or weekday == 7
end

local function advanceOneDay()
  local before = currentWeekday()
  world.advanceTime(24)
  H.waitUntil(function() return currentWeekday() ~= before end,
    C.DEFAULT_TIMEOUT_FRAMES, 'next calendar day')
  H.waitForWeatherCatchup(24)
end

local function advanceUntil(predicate, description)
  for _ = 1, 8 do
    if predicate() then return end
    advanceOneDay()
  end
  error('Could not reach ' .. tostring(description))
end

function M.run()
  H.advanceToHour(12.0)
  H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'Eight Plates time day guard setup')
  local cell = H.requireCurrentInterior(C.EIGHT_PLATES)

  advanceUntil(function() return not isWeekend() end, 'weekday baseline')
  H.waitUntil(function()
    return H.countRecordNearPosition(cell, TIME_DAY_POT_RECORD_ID,
      TIME_DAY_POT_POSITION, TIME_DAY_POT_TOLERANCE) > 0
  end, C.DEFAULT_TIMEOUT_FRAMES, 'time day guard weekday baseline enabled')

  advanceUntil(isWeekend, 'weekend guard window')
  H.waitUntil(function()
    return H.recordNearPositionDisabled(cell, TIME_DAY_POT_RECORD_ID,
      TIME_DAY_POT_POSITION, TIME_DAY_POT_TOLERANCE)
  end, C.DEFAULT_TIMEOUT_FRAMES, 'time day guard weekend disable')

  advanceUntil(function() return not isWeekend() end, 'weekday guard close')
  H.waitUntil(function()
    return H.countRecordNearPosition(cell, TIME_DAY_POT_RECORD_ID,
      TIME_DAY_POT_POSITION, TIME_DAY_POT_TOLERANCE) > 0
  end, C.DEFAULT_TIMEOUT_FRAMES, 'time day guard weekday revert')
end

return M
