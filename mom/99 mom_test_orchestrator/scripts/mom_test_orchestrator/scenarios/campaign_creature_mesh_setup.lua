local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local V = require('scripts.mom_test_orchestrator.scenarios.support.creature_mesh_common')
local ID = 'campaign_creature_mesh_setup'

return {
  id = ID,
  description = 'Save a generated Creature mesh variant and its source from another cell.',
  run = function()
    local cell = V.teleport(12)
    local source, output = V.waitReady(cell)
    V.emit(campaign, source, output)
    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION,
      'Creature replacement unrelated save cell')
    campaign.saveAndExit(ID, 'MOM Creature mesh replacement', C.VASSAMSI_GROTTO)
  end,
}
