local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local ANNOTATED_PARENT_SACK_RECORD_ID = 'com_sack_01'
local ANNOTATED_PARENT_SACK_POSITION = {
  x = 1070.0,
  y = 900.0,
  z = -311.0,
}
local ANNOTATED_PARENT_URN_RECORD_ID = 'urn_01'
local ANNOTATED_PARENT_URN_POSITION = {
  x = 1080.0,
  y = 910.0,
  z = -311.0,
}
local ANNOTATED_PARENT_DAGGER_ID = 'iron dagger'
local ANNOTATED_PARENT_DAGGER_COUNT = 5
-- Config: balmora_child_actions_example.yaml, balmora_child_inventory_parent_annotated variant.
--
-- Guard (6-20 exclusive) owns a place_ref that spawns both a com_sack_01
-- at (1070.0, 900.0, -311.0) and an urn_01 at (1080.0, 910.0, -311.0)
-- in Eight Plates. A child inventory row uses trailing [exclude, urn_01],
-- which should narrow ordinary child selection and exclude the urn.
--
-- Expected: during the day window, both containers exist near their
-- target positions. The sack contains 5 iron daggers. The urn contains
-- 0 iron daggers.

return {
  id = 'child_inventory_parent_annotated',
  description = 'Place sack + urn, filtered child inventory excludes urn and populates only sack.',
  run = function()
    local targetTolerance = 24

    local cell = H.teleportInteriorAtHour(23.0, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates child inventory filtered night baseline')

    H.waitUntil(function()
      return H.countRecordNearPosition(cell, ANNOTATED_PARENT_SACK_RECORD_ID, ANNOTATED_PARENT_SACK_POSITION, targetTolerance) == 0
        and H.countRecordNearPosition(cell, ANNOTATED_PARENT_URN_RECORD_ID, ANNOTATED_PARENT_URN_POSITION, targetTolerance) == 0
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates filtered child sack + urn absent before day guard opens')

    cell = H.advanceLoadedInteriorToHour(12.0, C.EIGHT_PLATES)

    H.waitUntil(function()
      return H.countRecordNearPosition(cell, ANNOTATED_PARENT_SACK_RECORD_ID, ANNOTATED_PARENT_SACK_POSITION, targetTolerance) > 0
        and H.countRecordNearPosition(cell, ANNOTATED_PARENT_URN_RECORD_ID, ANNOTATED_PARENT_URN_POSITION, targetTolerance) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates filtered child sack + urn spawned by place_ref')

    -- Use a tight target radius so we don't grab other Eight Plates containers
    -- with the same record ids from the persistent suite state.
    local sack = H.findRecordNearPosition(cell, ANNOTATED_PARENT_SACK_RECORD_ID, ANNOTATED_PARENT_SACK_POSITION, targetTolerance)
    H.expect(sack ~= nil, 'Filtered child sack not found near expected position in Eight Plates')

    local urn = H.findRecordNearPosition(cell, ANNOTATED_PARENT_URN_RECORD_ID, ANNOTATED_PARENT_URN_POSITION, targetTolerance)
    H.expect(urn ~= nil, 'Filtered child urn not found near expected position in Eight Plates')

    local populated, populateError = pcall(function()
      H.waitUntil(function()
        return H.countContainerRecord(sack, ANNOTATED_PARENT_DAGGER_ID)
          >= ANNOTATED_PARENT_DAGGER_COUNT
      end, C.LONG_TIMEOUT_FRAMES, 'Filtered child sack contains expected dagger count')
    end)
    if not populated then
      error(tostring(populateError)
        .. '; sackDaggers=' .. tostring(H.countContainerRecord(
          sack,
          ANNOTATED_PARENT_DAGGER_ID
        ))
        .. '; urnDaggers=' .. tostring(H.countContainerRecord(
          urn,
          ANNOTATED_PARENT_DAGGER_ID
        ))
        .. '; ' .. H.runtimeStatusText())
    end

    local sackDaggers = H.countContainerRecord(sack, ANNOTATED_PARENT_DAGGER_ID)
    H.expect(
      sackDaggers >= ANNOTATED_PARENT_DAGGER_COUNT,
      'Filtered child sack dagger count ' .. tostring(sackDaggers) .. ' < expected ' .. tostring(ANNOTATED_PARENT_DAGGER_COUNT)
    )

    local urnDaggers = H.countContainerRecord(urn, ANNOTATED_PARENT_DAGGER_ID)
    H.expect(
      urnDaggers == 0,
      'Filtered child urn should have 0 daggers but has ' .. tostring(urnDaggers)
    )
  end,
}
