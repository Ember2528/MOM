local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local N = require('scripts.mom_test_orchestrator.scenarios.support.nested_place_common')

return {
  id = 'campaign_nested_place_verify',
  description = 'Verify nested outputs survive restart without duplicates, then clean up.',
  run = function()
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION, 'nested Guild after restart')
    local cell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    local guild = N.waitPair(cell, N.GUILD, 'nested Guild after restart')
    N.expectSame(guild, campaign.handoffValue('nested.guild.1'),
      campaign.handoffValue('nested.guild.2'), 'Guild')
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'nested Eight Plates after restart')
    cell = H.requireCurrentInterior(C.EIGHT_PLATES)
    local eight = N.waitPair(cell, N.EIGHT, 'nested Eight Plates after restart')
    N.expectSame(eight, campaign.handoffValue('nested.eight.1'),
      campaign.handoffValue('nested.eight.2'), 'Eight Plates')
    cell = H.advanceLoadedInteriorToHour(12, C.EIGHT_PLATES)
    N.waitAbsent(cell, N.EIGHT, 'nested Eight Plates cleanup after restart')
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION, 'nested Guild cleanup after restart')
    cell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    N.waitAbsent(cell, N.GUILD, 'nested Guild cleanup after restart')
  end,
}
