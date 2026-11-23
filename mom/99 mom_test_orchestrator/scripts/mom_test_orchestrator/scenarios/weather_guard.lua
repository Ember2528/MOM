local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local EIGHT_PLATES_BANNER_RECORD_ID = 'furn_banner_tavern_eightplates'
local EIGHT_PLATES_BANNER_POSITION = {
  x = -21726.260,
  y = -12176.084,
  z = 932.626,
}
return {
  id = 'weather_guard',
  description = 'Weather guard disables exterior banner on rain and reverts on clear.',
  run = function()
    local gridX = C.BALMORA_EXTERIOR.gridX
    local gridY = C.BALMORA_EXTERIOR.gridY

    -- Start exterior in clear weather so the banner is present.
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
    H.teleportExterior(gridX, gridY,
      H.exteriorCellCenter(gridX, gridY), 'Balmora exterior weather setup')
    local cell = H.requireCurrentExterior(gridX, gridY)

    -- Baseline: banner enabled under clear skies.
    H.waitUntil(function()
      return H.countRecordNearPosition(cell,
        EIGHT_PLATES_BANNER_RECORD_ID,
        EIGHT_PLATES_BANNER_POSITION, 32) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'weather guard clear baseline')

    -- Rain opens the guard and disables the banner.
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_RAIN)
    H.waitUntil(function()
      return H.recordNearPositionDisabled(cell,
        EIGHT_PLATES_BANNER_RECORD_ID,
        EIGHT_PLATES_BANNER_POSITION, 32)
    end, C.LONG_TIMEOUT_FRAMES, 'weather guard rain disable')

    -- Clear weather closes the guard and restores the banner.
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
    H.waitUntil(function()
      return H.countRecordNearPosition(cell,
        EIGHT_PLATES_BANNER_RECORD_ID,
        EIGHT_PLATES_BANNER_POSITION, 32) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'weather guard clear revert')

  end,
}
