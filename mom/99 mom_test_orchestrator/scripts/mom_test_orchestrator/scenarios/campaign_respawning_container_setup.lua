local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local R = require('scripts.mom_test_orchestrator.scenarios.support.respawning_container_common')
local ID = 'campaign_respawning_container_setup'

return {
  id = ID,
  description = 'Replace an untouched unresolved plant, then save its native output after reset, harvest, and player item deposit.',
  run = function()
    local _, state = R.prepareHarvestedReplacement()
    campaign.emitValue('respawn.source_id', state.sourceId)
    campaign.emitValue('respawn.output_id', state.outputId)
    campaign.emitValue('respawn.player_items', state.playerItems)
    campaign.emitValue('respawn.player_gold', state.playerGold)
    campaign.saveAndExit(ID, 'MOM campaign harvested respawning output', R.CELL)
  end,
}
