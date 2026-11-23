local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local SCOPE_EIGHT_PLATES_TARGET_RECORD_ID = 'misc_de_goblet_03'
local SCOPE_EIGHT_PLATES_TARGET_POSITION = {
  x = 401.737,
  y = 1147.238,
  z = -187.558,
}
local SCOPE_EIGHT_PLATES_TARGET_TOLERANCE = 16
local SCOPE_GUILD_TARGET_RECORD_ID = 'furn_de_lecturn'
local SCOPE_GUILD_TARGET_POSITION = {
  x = 375.726,
  y = -431.812,
  z = -705.556,
}
local SCOPE_GUILD_TARGET_TOLERANCE = 16
-- Config: balmora_scope_cross_cell_example.yaml
--
-- Guard (6-20 exclusive) owns two actions:
--   1. Disable a keyed lectern in Guild of Mages:
--      furn_de_lecturn at (375.726, -431.812, -705.556)
--   2. Disable a keyed goblet in Eight Plates:
--      misc_de_goblet_03 at (401.737, 1147.238, -187.558)
--
-- Both targets are selected by exact starting-position keys so only
-- one specific object per cell is affected.

return {
  id = 'scope_cross_cell',
  description = 'Guard-owned actions with exact cell scope apply/revert correctly across Guild and Eight Plates.',
  run = function()
    local guildRecordId = SCOPE_GUILD_TARGET_RECORD_ID
    local guildPosition = SCOPE_GUILD_TARGET_POSITION
    local guildTolerance = SCOPE_GUILD_TARGET_TOLERANCE
    local eightPlatesRecordId = SCOPE_EIGHT_PLATES_TARGET_RECORD_ID
    local eightPlatesPosition = SCOPE_EIGHT_PLATES_TARGET_POSITION
    local eightPlatesTolerance = SCOPE_EIGHT_PLATES_TARGET_TOLERANCE

    -- Night baseline (outside 6-20 window): both targets should be
    -- in their default enabled state.
    H.advanceToHour(2.0)
    H.teleportInteriorReady(
      C.GUILD_OF_MAGES,
      C.GUILD_SAFE_POSITION,
      'Guild keyed lectern baseline enabled at night',
      function(cell)
        return H.recordNearPositionEnabled(cell, guildRecordId, guildPosition, guildTolerance)
      end)

    -- Eight Plates keyed goblet baseline
    H.teleportInteriorReady(
      C.EIGHT_PLATES,
      C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates keyed goblet baseline enabled at night',
      function(cell)
        return H.recordNearPositionEnabled(cell, eightPlatesRecordId,
          eightPlatesPosition, eightPlatesTolerance)
      end)

    -- Day (inside 6-20 window): both should be disabled
    H.advanceToHour(12.0)
    local guildDisabled, guildDisabledError = pcall(H.teleportInteriorReady,
      C.GUILD_OF_MAGES,
      C.GUILD_SAFE_POSITION,
      'Guild keyed lectern disabled during day window',
      function(cell)
        return H.recordNearPositionDisabled(cell, guildRecordId, guildPosition, guildTolerance)
      end)
    if not guildDisabled then
      error(tostring(guildDisabledError) .. '; ' .. H.runtimeStatusText())
    end

    H.teleportInteriorReady(
      C.EIGHT_PLATES,
      C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates keyed goblet disabled during day window',
      function(cell)
        return H.recordNearPositionDisabled(cell, eightPlatesRecordId,
          eightPlatesPosition, eightPlatesTolerance)
      end)

    -- Night again: both should revert
    H.advanceToHour(23.0)
    H.teleportInteriorReady(
      C.GUILD_OF_MAGES,
      C.GUILD_SAFE_POSITION,
      'Guild keyed lectern re-enabled after day window closes',
      function(cell)
        return H.recordNearPositionEnabled(cell, guildRecordId, guildPosition, guildTolerance)
      end)

    H.teleportInteriorReady(
      C.EIGHT_PLATES,
      C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates keyed goblet re-enabled after day window closes',
      function(cell)
        return H.recordNearPositionEnabled(cell, eightPlatesRecordId,
          eightPlatesPosition, eightPlatesTolerance)
      end)
  end,
}
