local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local R = require('scripts.mom_test_orchestrator.scenarios.support.respawning_container_common')
local ID = 'campaign_respawning_container_verify'

return {
  id = ID,
  description = 'Restart preserves exact native respawning source/output identities and current harvested inventory on revert.',
  run = function()
    local cell = H.requireCurrentInterior(R.CELL)
    local state = {
      sourceId = campaign.handoffValue('respawn.source_id'),
      outputId = campaign.handoffValue('respawn.output_id'),
      playerItems = assert(tonumber((campaign.handoffValue('respawn.player_items')))),
      playerGold = assert(tonumber((campaign.handoffValue('respawn.player_gold')))),
    }
    R.expectHarvested(cell, state)
    R.revert(cell, state)
    R.reactivate(cell, state)
    campaign.logDiagnostics(ID, R.CELL)
  end,
}
