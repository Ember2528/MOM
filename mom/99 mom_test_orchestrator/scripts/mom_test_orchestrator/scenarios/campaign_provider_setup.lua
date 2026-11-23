local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_provider_setup'

return {
  id = ID,
  description = 'Save one active and one inactive external-provider operation.',
  run = function()
    G.setToggle('campaign_provider_active', false)
    G.setToggle('campaign_provider_inactive', false)
    local cell = G.teleport()
    H.expect(G.count(cell, G.PROVIDER_ACTIVE) == 0
        and G.count(cell, G.PROVIDER_INACTIVE) == 0,
      'provider campaign fixtures were not at their absent baseline')
    G.setToggle('campaign_provider_active', true)
    G.waitPresent(cell, G.PROVIDER_ACTIVE, 'provider campaign active placement')
    H.expect(G.count(cell, G.PROVIDER_INACTIVE) == 0,
      'provider campaign inactive placement applied unexpectedly')
    campaign.saveAndExit(ID, 'MOM campaign provider active', G.CELL)
  end,
}
