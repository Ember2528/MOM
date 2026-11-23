local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local core = require('openmw.core')

local MARKER_RECORD_ID = C.CHILD_LANTERN_RECORD_ID
local MARKER_TOLERANCE = 32
local WEATHER_THUNDERSTORM = 5

local MARKER_POSITIONS = {
  { x = -21680.0, y = -12240.0, z = 930.0 },
  { x = -21600.0, y = -12240.0, z = 930.0 },
  { x = -21520.0, y = -12240.0, z = 930.0 },
  { x = -21440.0, y = -12240.0, z = 930.0 },
  { x = -21680.0, y = -12160.0, z = 930.0 },
  { x = -21600.0, y = -12160.0, z = 930.0 },
  { x = -21520.0, y = -12160.0, z = 930.0 },
  { x = -21440.0, y = -12160.0, z = 930.0 },
}

local function waitForMarkerCount(cell, expected, description)
  H.waitUntil(function()
    return H.placementsMatch(cell, MARKER_RECORD_ID, MARKER_POSITIONS,
      expected == 0 and 0 or 1, MARKER_TOLERANCE)
  end, C.LONG_TIMEOUT_FRAMES, description)
end

local function finishWeatherTransition(cell, expected)
  H.settleWeatherTransitions()
  local current = core.weather.getCurrent(cell)
  assert(current and current.scriptId == expected,
    'weather transition completed with weather ' .. tostring(current and current.scriptId)
      .. ', expected ' .. tostring(expected))
end

return {
  id = 'guard_boundary_weather_stress',
  description = 'A weather window places and removes every authored marker.',
  run = function()
    local gridX = C.BALMORA_EXTERIOR.gridX
    local gridY = C.BALMORA_EXTERIOR.gridY

    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
    H.teleportExterior(gridX, gridY,
      H.exteriorCellCenter(gridX, gridY), 'Balmora exterior weather boundary setup')
    local cell = H.requireCurrentExterior(gridX, gridY)

    waitForMarkerCount(cell, 0, 'weather boundary clear baseline')

    -- Queue clear behind rain before requesting rain again. OpenMW does not
    -- expose that queue through getNext, and a same-weather request alone
    -- would leave clear queued to replace rain later.
    H.settleWeatherTransitions()
    local current = core.weather.getCurrent(cell)
    if current and current.scriptId == C.WEATHER_RAIN then
      H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
      H.settleWeatherTransitions()
      current = core.weather.getCurrent(cell)
    end
    assert(current and current.scriptId ~= C.WEATHER_RAIN,
      'could not prepare a non-rain weather for the conflict')
    local region = assert(core.regions.records[C.WEST_GASH_REGION:lower()])
    local rain, clear
    for _, record in pairs(core.weather.records) do
      if record.scriptId == C.WEATHER_RAIN then rain = record end
      if record.scriptId == C.WEATHER_CLEAR then clear = record end
    end
    assert(rain and clear, 'weather records unavailable')
    core.weather.changeWeather(region.id, rain)
    core.weather.changeWeather(region.id, clear)
    assert(core.weather.getNext(cell).scriptId == C.WEATHER_RAIN,
      'failed to prepare queued weather conflict')
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_RAIN)
    finishWeatherTransition(cell, C.WEATHER_RAIN)
    waitForMarkerCount(cell, #MARKER_POSITIONS, 'weather boundary rain opens')

    H.changeWeather(C.WEST_GASH_REGION, WEATHER_THUNDERSTORM)
    waitForMarkerCount(cell, 0, 'weather boundary rain closes')
  end,
}
