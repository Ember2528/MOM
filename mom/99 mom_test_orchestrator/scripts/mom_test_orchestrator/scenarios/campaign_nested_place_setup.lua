local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local N = require('scripts.mom_test_orchestrator.scenarios.support.nested_place_common')

local ID = 'campaign_nested_place_setup'
return {
  id = ID,
  description = 'Save nested placements from an unrelated cell while the guard is active.',
  run = function()
    local cell = H.teleportInteriorAtHour(12, C.EIGHT_PLATES,
      C.EIGHT_PLATES_SAFE_POSITION, 'nested restart inactive baseline')
    N.waitAbsent(cell, N.EIGHT, 'nested Eight Plates baseline')
    cell = H.advanceLoadedInteriorToHour(2, C.EIGHT_PLATES)
    local eight = N.waitPair(cell, N.EIGHT, 'nested Eight Plates setup')
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'nested restart Guild setup')
    cell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    local guild = N.waitPair(cell, N.GUILD, 'nested Guild setup')
    campaign.emitValue('nested.eight.1', eight[1])
    campaign.emitValue('nested.eight.2', eight[2])
    campaign.emitValue('nested.guild.1', guild[1])
    campaign.emitValue('nested.guild.2', guild[2])
    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION,
      'nested restart unrelated save cell')
    campaign.saveAndExit(ID, 'MOM nested placements', C.VASSAMSI_GROTTO)
  end,
}
