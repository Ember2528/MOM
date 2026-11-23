local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local NARROWED_SACK_RECORD_ID = 'com_sack_01'
local NARROWED_SACK_POSITION = {
  x = 1050.0,
  y = 880.0,
  z = -311.0,
}
local NARROWED_URN_RECORD_ID = 'urn_01'
local NARROWED_URN_POSITION = {
  x = 1060.0,
  y = 890.0,
  z = -311.0,
}
local NARROWED_DAGGER_ID = 'iron dagger'
local NARROWED_DAGGER_COUNT = 3
-- Config: balmora_child_actions_example.yaml, balmora_child_inventory_narrowed variant.
--
-- Guard (6-20 exclusive) owns a place_ref that spawns both a com_sack_01
-- at (1050.0, 880.0, -311.0) and an urn_01 at (1060.0, 890.0, -311.0)
-- in Eight Plates. A child inventory action with select.recordId: com_sack_01
-- should narrow to only the sack; the urn must remain empty.
--
-- Expected: during the day window, both containers exist near their
-- target positions. The sack contains 3 iron daggers. The urn
-- contains 0 iron daggers (its inventory was not modified).

return {
  id = 'child_inventory_narrowed',
  description = 'Place sack + urn, child inventory with select.recordId narrows to sack only.',
  run = function()
    local targetTolerance = 24

    local cell = H.teleportInteriorAtHour(23.0, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates child inventory narrowed night baseline')

    H.waitUntil(function()
      return H.countRecordNearPosition(cell, NARROWED_SACK_RECORD_ID, NARROWED_SACK_POSITION, targetTolerance) == 0
        and H.countRecordNearPosition(cell, NARROWED_URN_RECORD_ID, NARROWED_URN_POSITION, targetTolerance) == 0
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates narrowed child sack + urn absent before day guard opens')

    cell = H.advanceLoadedInteriorToHour(12.0, C.EIGHT_PLATES)

    -- Use a tight target radius so we don't grab other Eight Plates containers
    -- with the same record ids from the persistent suite state.
    H.waitUntil(function()
      return H.countRecordNearPosition(cell, NARROWED_SACK_RECORD_ID, NARROWED_SACK_POSITION, targetTolerance) > 0
        and H.countRecordNearPosition(cell, NARROWED_URN_RECORD_ID, NARROWED_URN_POSITION, targetTolerance) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates sack + urn spawned by place_ref')

    local sack = H.findRecordNearPosition(cell, NARROWED_SACK_RECORD_ID, NARROWED_SACK_POSITION, targetTolerance)
    H.expect(sack ~= nil, 'Narrowed sack not found near expected position in Eight Plates')

    local urn = H.findRecordNearPosition(cell, NARROWED_URN_RECORD_ID, NARROWED_URN_POSITION, targetTolerance)
    H.expect(urn ~= nil, 'Narrowed urn not found near expected position in Eight Plates')

    local populated, populateError = pcall(function()
      H.waitUntil(function()
        return H.countContainerRecord(sack, NARROWED_DAGGER_ID)
          >= NARROWED_DAGGER_COUNT
      end, C.LONG_TIMEOUT_FRAMES, 'Sack contains expected dagger count')
    end)
    if not populated then
      error(tostring(populateError)
        .. '; sackDaggers=' .. tostring(H.countContainerRecord(
          sack,
          NARROWED_DAGGER_ID
        ))
        .. '; urnDaggers=' .. tostring(H.countContainerRecord(
          urn,
          NARROWED_DAGGER_ID
        ))
        .. '; ' .. H.runtimeStatusText())
    end

    local sackDaggers = H.countContainerRecord(sack, NARROWED_DAGGER_ID)
    H.expect(
      sackDaggers >= NARROWED_DAGGER_COUNT,
      'Sack dagger count ' .. tostring(sackDaggers) .. ' < expected ' .. tostring(NARROWED_DAGGER_COUNT)
    )

    local urnDaggers = H.countContainerRecord(urn, NARROWED_DAGGER_ID)
    H.expect(
      urnDaggers == 0,
      'Urn should have 0 daggers but has ' .. tostring(urnDaggers)
        .. '; select.recordId narrowing failed'
    )
  end,
}
