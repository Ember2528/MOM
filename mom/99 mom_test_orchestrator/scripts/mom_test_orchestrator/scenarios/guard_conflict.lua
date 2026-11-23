local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local GUARD_CONFLICT_BOTTLE_RECORD_ID = 'misc_com_bottle_07'
local GUARD_CONFLICT_BOTTLE_POSITION = {
  x = -101.395,
  y = 663.972,
  z = -168.985,
}
-- Position specificity deliberately outranks the record-wide scale action.
-- The loser-only scale effect distinguishes arbitration from executing both.

return {
  id = 'guard_conflict',
  description = 'Semantic arbitration resolves intersecting guard-owned claims coherently.',
  run = function()
    local bottleRecordId = GUARD_CONFLICT_BOTTLE_RECORD_ID
    local bottlePosition = GUARD_CONFLICT_BOTTLE_POSITION
    local tolerance = C.DUPLICATE_TARGET_TOLERANCE

    -- Baseline outside the guard window: bottle should be in its
    -- default enabled state.
    H.advanceToHour(12.0)
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates guard conflict baseline setup')
    local cell = H.requireCurrentInterior(C.EIGHT_PLATES)

    H.waitUntil(function()
      return H.countRecordNearPosition(cell, bottleRecordId, bottlePosition, tolerance) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates bottle baseline enabled outside guard window')

    local bottle = assert(H.findRecordNearPosition(cell, bottleRecordId, bottlePosition, tolerance))
    local baselineScale = bottle.scale

    -- Enter the guard window (20-24).
    cell = H.advanceLoadedInteriorToHour(21.0, C.EIGHT_PLATES)

    -- Observe the winning effect before checking the loser-only property.
    local disabled, disabledError = pcall(H.waitUntil, function()
      return bottle:isValid() and bottle.enabled == false
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates bottle disabled by semantic conflict winner')
    if not disabled then
      error(tostring(disabledError) .. '; ' .. H.runtimeStatusText())
    end

    H.expect(H.scaleNear(bottle.scale, baselineScale, 0.01),
      'Conflict loser scaled the bottle despite the more specific winner')

    -- Leave the guard window
    cell = H.advanceLoadedInteriorToHour(12.0, C.EIGHT_PLATES)

    -- Bottle should still be enabled after the guard window closes
    H.waitUntil(function()
      return H.countRecordNearPosition(cell, bottleRecordId, bottlePosition, tolerance) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates bottle still enabled after guard window closes')
  end,
}
