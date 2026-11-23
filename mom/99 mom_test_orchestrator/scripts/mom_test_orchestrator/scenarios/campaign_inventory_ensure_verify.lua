local G = require('scripts.mom_test_orchestrator.scenarios.support.group1_common')
local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')

return {id = 'campaign_inventory_ensure_verify', description = 'Recover owned ensure additions across restart.', run = function()
  -- Unknown guard truth on startup holds saved work until the scenario publishes it.
  local crate = G.crate()
  H.expect(tostring(crate.id) == campaign.handoffValue('ensure.crate'), 'ensure owner identity changed on restart')
  G.count(crate, 17, 'saved ensured inventory retains outside additions')
  G.withdraw(crate)
end}
