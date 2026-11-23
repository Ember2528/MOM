local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local V = require('scripts.mom_test_orchestrator.scenarios.support.creature_mesh_common')

return {
  id = 'campaign_creature_mesh_verify',
  description = 'Creature record and actor identities survive restart and later withdraw.',
  run = function()
    local cell = V.teleport()
    local source, output = V.waitReady(cell)
    V.expectSame(campaign, source, output)
    cell = H.advanceLoadedInteriorToHour(23, C.EIGHT_PLATES)
    V.waitAbsent(cell)
  end,
}
