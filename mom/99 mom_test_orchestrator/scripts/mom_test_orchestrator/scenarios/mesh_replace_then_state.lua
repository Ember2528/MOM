local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local GUILD_MESH_SOURCE_RECORD_ID = 'furn_de_rope_03'
-- Config: balmora_mesh_replace_then_state_example.yaml
--
-- Static action: attach replaces furn_de_rope_03 with a tapestry mesh,
-- disabling the original.
--
-- Guard (20-24 exclusive): modify disables furn_de_rope_03
-- by its original record id. This validates that state targeting still
-- resolves through the mesh-replacement provenance chain.

return {
  id = 'mesh_replace_then_state',
  description = 'Static mesh replacement applies and state actions still target replaced refs by original identity.',
  run = function()
    -- Establish the static replacement's disabled-original baseline in daytime.
    H.advanceToHour(12.0)
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'Guild of Mages mesh replace setup')
    local guildCell = H.requireCurrentInterior(C.GUILD_OF_MAGES)

    local originalSet = { [GUILD_MESH_SOURCE_RECORD_ID] = true }
    H.waitUntil(function()
      return H.recordSetDisabled(guildCell, originalSet)
    end, C.LONG_TIMEOUT_FRAMES, 'Guild rope originals disabled after mesh replacement')

    -- The guard targets the original record identity. Opening it preserves the
    -- disabled state; closing it must not undo the static replacement.
    guildCell = H.advanceLoadedInteriorToHour(21.0, C.GUILD_OF_MAGES)

    -- The original remains disabled while the guard is open.
    H.waitUntil(function()
      return H.recordSetDisabled(guildCell, originalSet)
    end, C.LONG_TIMEOUT_FRAMES, 'Guild rope originals disabled during guard window')

    -- The static attach's disableOriginal effect persists after guard reversion.
    guildCell = H.advanceLoadedInteriorToHour(12.0, C.GUILD_OF_MAGES)

    H.waitUntil(function()
      return H.recordSetDisabled(guildCell, originalSet)
    end, C.LONG_TIMEOUT_FRAMES, 'Guild rope originals stay disabled after guard window closes (static attach persists)')
  end,
}
