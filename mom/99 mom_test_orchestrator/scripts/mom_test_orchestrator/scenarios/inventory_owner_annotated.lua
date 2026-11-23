local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local GALBEDIR_RECORD_ID = 'galbedir'
return {
  id = 'inventory_owner_annotated',
  description = 'Inventory owner tuple with a trailing predicate filters out one Galbedir owner entry while an unfiltered sibling entry still applies.',
  run = function()
    local ownerRecordId = GALBEDIR_RECORD_ID

    H.advanceToHour(12.0)
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'Guild inventory owner trailing predicate baseline')
    local cell = H.requireCurrentInterior(C.GUILD_OF_MAGES)

    local owner = H.findFirstObject(cell, function(obj)
      return H.objectRecordId(obj) == ownerRecordId
    end)
    H.expect(owner ~= nil, 'Galbedir not found for trailing-predicate owner baseline')

    local baselineGold = H.countInventoryRecord(owner, C.REVERT_GOLD_ID)
    local expectedGoldCount = baselineGold + 2

    cell = H.advanceLoadedInteriorToHour(21.0, C.GUILD_OF_MAGES)

    owner = H.findFirstObject(cell, function(obj)
      return H.objectRecordId(obj) == ownerRecordId
    end)
    H.expect(owner ~= nil, 'Galbedir not found during trailing-predicate owner window')

    H.waitUntil(function()
      return H.countInventoryRecord(owner, C.REVERT_GOLD_ID) >= expectedGoldCount
    end, C.LONG_TIMEOUT_FRAMES, 'Trailing-predicate owner tuple adds gold to Galbedir during guard window')

    H.expect(H.countInventoryRecord(owner, C.REVERT_GOLD_ID) == expectedGoldCount,
      'Filtered owner tuple should not stack with the unfiltered sibling entry on Galbedir')

    cell = H.advanceLoadedInteriorToHour(12.0, C.GUILD_OF_MAGES)

    owner = H.findFirstObject(cell, function(obj)
      return H.objectRecordId(obj) == ownerRecordId
    end)
    H.expect(owner ~= nil, 'Galbedir not found after trailing-predicate owner window')

    local reverted, revertError = pcall(function()
      H.waitUntil(function()
        return H.countInventoryRecord(owner, C.REVERT_GOLD_ID) == baselineGold
      end, C.LONG_TIMEOUT_FRAMES,
        'Trailing-predicate owner tuple reverts Galbedir gold after guard window closes')
    end)
    if not reverted then
      error(tostring(revertError)
        .. '; baselineGold=' .. tostring(baselineGold)
        .. '; currentGold=' .. tostring(H.countInventoryRecord(
          owner,
          C.REVERT_GOLD_ID
        ))
        .. '; ' .. H.runtimeStatusText())
    end
  end,
}
