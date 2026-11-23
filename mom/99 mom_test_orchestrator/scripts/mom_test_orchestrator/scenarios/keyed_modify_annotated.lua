local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local GUILD_BOWL_RECORD_ID = 'misc_de_bowl_orange_green_01'
local GUILD_BOWL_POSITION = {
  x = -551.686,
  y = 31.301,
  z = -182.292,
}
return {
  id = 'keyed_modify_annotated',
  description = 'Keyed modify with a trailing predicate narrows the Guild bowl tuple to the upright target only.',
  run = function()
    local bowlRecordId = GUILD_BOWL_RECORD_ID
    local bowlPosition = GUILD_BOWL_POSITION
    local bowlTolerance = 8

    H.advanceToHour(2.0)
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'Guild keyed modify trailing predicate baseline')
    local guildCell = H.requireCurrentInterior(C.GUILD_OF_MAGES)

    H.waitUntil(function()
      return H.countRecordNearPosition(guildCell, bowlRecordId, bowlPosition, bowlTolerance) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'Guild keyed bowl baseline enabled before trailing-predicate modify')

    guildCell = H.advanceLoadedInteriorToHour(12.0, C.GUILD_OF_MAGES)

    H.waitUntil(function()
      return H.recordNearPositionDisabled(guildCell, bowlRecordId, bowlPosition, bowlTolerance)
    end, C.LONG_TIMEOUT_FRAMES, 'Trailing-predicate keyed modify disables the target bowl during day window')

    guildCell = H.advanceLoadedInteriorToHour(23.0, C.GUILD_OF_MAGES)

    H.waitUntil(function()
      return H.countRecordNearPosition(guildCell, bowlRecordId, bowlPosition, bowlTolerance) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'Trailing-predicate keyed modify re-enables the target bowl after day window closes')
  end,
}
