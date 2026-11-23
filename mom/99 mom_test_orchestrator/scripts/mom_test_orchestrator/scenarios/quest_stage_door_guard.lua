local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local RENT_DOOR_RECORD_ID = 'rent_balmora_eight_door'
local RENT_DOOR_POSITION = {
  x = 960.696,
  y = 1020.348,
  z = -256.0,
}
return {
  id = 'quest_stage_door_guard',
  description = 'The Eight Plates rent door follows the quest-stage guard and re-enables after the stage drops.',
  run = function()
    H.setQuestStage(C.KNIGHT_AKAY_QUEST, 0)
    H.advanceToHour(23.0)
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates quest stage setup')
    local cell = H.requireCurrentInterior(C.EIGHT_PLATES)

    -- Night baseline: rent door present
    H.waitUntil(function()
      return H.countRecordNearPosition(cell, RENT_DOOR_RECORD_ID, RENT_DOOR_POSITION, 32) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates rent door night baseline')

    -- Opening the quest guard disables the door.
    H.setQuestStage(C.KNIGHT_AKAY_QUEST, 20)
    H.waitUntil(function()
      return H.recordNearPositionDisabled(cell, RENT_DOOR_RECORD_ID, RENT_DOOR_POSITION, 32)
    end, C.LONG_TIMEOUT_FRAMES, 'quest-stage rent door disable')

    -- Closing the quest guard restores the door.
    H.setQuestStage(C.KNIGHT_AKAY_QUEST, 0)
    H.waitUntil(function()
      return H.countRecordNearPosition(cell, RENT_DOOR_RECORD_ID, RENT_DOOR_POSITION, 32) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'quest-stage rent door revert')
  end,
}
