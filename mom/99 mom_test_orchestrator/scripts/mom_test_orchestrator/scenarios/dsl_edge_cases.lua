local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local EDGE_WEATHER_SIGNPOST_RECORD_ID = 'furn_de_signpost_02'
local EDGE_WEATHER_SIGNPOST_POSITION = {
  x = -22512.762,
  y = -13476.332,
  z = 645.224,
}
local EDGE_QUEST_POT_RECORD_ID = 'misc_de_pot_green_01'
local EDGE_QUEST_POT_POSITION = {
  x = -306.213,
  y = 936.541,
  z = -120.932,
}
local EDGE_QUEST_STAGE = 60
local EDGE_SCALAR_HOUR = 10.0
local function requireObjectNear(cell, recordId, position, tolerance, description)
  local obj = H.findRecordNearPosition(cell, recordId, position, tolerance or 32)
  H.expect(obj ~= nil, tostring(description or recordId) .. ' not found near expected position')
  return obj
end

return {
  id = 'dsl_edge_cases',
  description = 'Balmora DSL edge cases: variant gates, previsit/chance, scalar guards, filters, and match cell selection.',
  run = function()
    local gridX = C.BALMORA_EXTERIOR.gridX
    local gridY = C.BALMORA_EXTERIOR.gridY

    H.setQuestStage(C.KNIGHT_AKAY_QUEST, 0)
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
    H.advanceToHour(2.0)

    H.teleportExterior(gridX, gridY,
      H.exteriorCellCenter(gridX, gridY), 'Balmora exterior DSL edge setup')
    local exteriorCell = H.requireCurrentExterior(gridX, gridY)

    H.waitUntil(function()
      local banner = H.findRecordNearPosition(exteriorCell,
        C.EDGE_PREVISIT_BANNER_RECORD_ID,
        C.EDGE_PREVISIT_BANNER_POSITION, 32)
      return banner ~= nil
        and banner.enabled == false
        and H.scaleNear(banner.scale, 0.75, 0.02)
    end, C.LONG_TIMEOUT_FRAMES, 'previsit region static action disabled and scaled banner')

    local signpost = requireObjectNear(exteriorCell,
      EDGE_WEATHER_SIGNPOST_RECORD_ID,
      EDGE_WEATHER_SIGNPOST_POSITION, 32,
      'weather signpost baseline')
    H.expect(signpost.enabled ~= false, 'Weather signpost should start enabled')

    H.advanceToHour(EDGE_SCALAR_HOUR)
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_RAIN)
    H.waitUntil(function()
      return H.recordNearPositionDisabled(exteriorCell,
        EDGE_WEATHER_SIGNPOST_RECORD_ID,
        EDGE_WEATHER_SIGNPOST_POSITION, 32)
    end, C.LONG_TIMEOUT_FRAMES, 'time/weather guard disabled signpost')

    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
    H.waitUntil(function()
      return H.countRecordNearPosition(exteriorCell,
        EDGE_WEATHER_SIGNPOST_RECORD_ID,
        EDGE_WEATHER_SIGNPOST_POSITION, 32) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'time/weather guard reverted signpost')

    H.setQuestStage(C.KNIGHT_AKAY_QUEST, 0)
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates DSL quest scalar setup')
    local eightPlates = H.requireCurrentInterior(C.EIGHT_PLATES)

    local pot = requireObjectNear(eightPlates,
      EDGE_QUEST_POT_RECORD_ID,
      EDGE_QUEST_POT_POSITION, 32,
      'quest scalar pot baseline')
    H.expect(pot.enabled ~= false, 'Quest scalar pot should start enabled')

    H.setQuestStage(C.KNIGHT_AKAY_QUEST, EDGE_QUEST_STAGE)
    H.waitUntil(function()
      return H.recordNearPositionDisabled(eightPlates,
        EDGE_QUEST_POT_RECORD_ID,
        EDGE_QUEST_POT_POSITION, 32)
    end, C.LONG_TIMEOUT_FRAMES, 'quest scalar guard disabled filtered pot')

    H.setQuestStage(C.KNIGHT_AKAY_QUEST, 0)
    H.waitUntil(function()
      return H.countRecordNearPosition(eightPlates,
        EDGE_QUEST_POT_RECORD_ID,
        EDGE_QUEST_POT_POSITION, 32) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'quest scalar guard reverted filtered pot')
  end,
}
