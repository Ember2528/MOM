local G = require('scripts.mom_test_orchestrator.scenarios.support.group1_common')
local C = require('scripts.mom_test_orchestrator.constants')
local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local ID = 'campaign_inventory_ensure_setup'

return {id = ID, description = 'Save ensured inventory with outside additions.', run = function()
  G.toggle('inventory_ensure', false)
  local crate = G.crate()
  G.seed(crate)
  campaign.emitValue('ensure.crate', tostring(crate.id))
  H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION, 'ensure restart save')
  campaign.saveAndExit(ID, 'MOM true minimum inventory', C.VASSAMSI_GROTTO)
end}
