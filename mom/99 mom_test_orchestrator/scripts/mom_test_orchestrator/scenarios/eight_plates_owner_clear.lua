local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local RENT_CHEST_RECORD_ID = 'de_p_chest_02_empty'
local RENT_CHEST_OWNER_ID = 'dulnea ralaal'
local RENT_CHEST_POSITION = {
  x = 1118.174,
  y = 1444.821,
  z = -361.513,
}
return {
  id = 'eight_plates_owner_clear',
  description = 'Eight Plates rental chest owner clears by day and reverts at night.',
  run = function()
    local cell = H.teleportInteriorAtHour(23.0, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates owner clear night baseline setup')

    H.waitUntil(function()
      local rentChest = H.findRecordNearPosition(cell, RENT_CHEST_RECORD_ID, RENT_CHEST_POSITION, 32)
      return rentChest
        and H.objectOwnerRecordId(rentChest) == RENT_CHEST_OWNER_ID
        and H.objectOwnerFactionId(rentChest) == nil
        and H.objectOwnerFactionRank(rentChest) == nil
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates rental chest owned before day guard opens')

    cell = H.advanceLoadedInteriorToHour(12.0, C.EIGHT_PLATES)

    H.waitUntil(function()
      local rentChest = H.findRecordNearPosition(cell, RENT_CHEST_RECORD_ID, RENT_CHEST_POSITION, 32)
      return rentChest
        and H.objectOwnerRecordId(rentChest) == nil
        and H.objectOwnerFactionId(rentChest) == nil
        and H.objectOwnerFactionRank(rentChest) == nil
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates rental chest owner cleared by day guard')

    cell = H.advanceLoadedInteriorToHour(23.0, C.EIGHT_PLATES)

    H.waitUntil(function()
      local rentChest = H.findRecordNearPosition(cell, RENT_CHEST_RECORD_ID, RENT_CHEST_POSITION, 32)
      return rentChest
        and H.objectOwnerRecordId(rentChest) == RENT_CHEST_OWNER_ID
        and H.objectOwnerFactionId(rentChest) == nil
        and H.objectOwnerFactionRank(rentChest) == nil
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates rental chest owner restored at night')
  end,
}
