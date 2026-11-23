local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local GUILD_BLUE_POT_IDS = {
  misc_de_pot_blue_01 = true,
}
return {
  id = 'cell_exclude',
  description = 'The Guild-only exclude example disables the blue pot target without touching the Eight Plates cell.',
  run = function()
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'Guild cell exclude setup')
    local guildCell = H.requireCurrentInterior(C.GUILD_OF_MAGES)

    H.waitUntil(function()
      return H.recordSetDisabled(guildCell, GUILD_BLUE_POT_IDS)
    end, C.LONG_TIMEOUT_FRAMES, 'Guild blue pot cell exclude example')

    -- The placement proves that the excluded cell's static work was observed.
    -- Only then is an unchanged blue pot evidence for the exclusion.
    local excluded = H.teleportInteriorReady(C.EIGHT_PLATES,
      C.EIGHT_PLATES_SAFE_POSITION, 'excluded cell witness', function(cell)
        return H.countRecordNearPosition(cell, C.CHILD_LANTERN_RECORD_ID,
          {x = 1200, y = 1750, z = -311}, 16) == 1
      end)
    H.expect(H.countRecords(excluded, GUILD_BLUE_POT_IDS) > 0
        and H.countEnabledRecords(excluded, GUILD_BLUE_POT_IDS)
          == H.countRecords(excluded, GUILD_BLUE_POT_IDS),
      'Cell exclusion changed an Eight Plates blue pot')
  end,
}
