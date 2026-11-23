local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_reversible_setup'

return {
  id = ID,
  description = 'Apply reversible placement and save before process exit.',
  run = function()
    G.setToggle('campaign_reversible', false)
    local cell = G.teleport()
    H.expect(G.count(cell, G.REVERSIBLE) == 0,
      'reversible campaign fixture was not at its absent baseline')
    G.setToggle('campaign_reversible', true)
    G.waitPresent(cell, G.REVERSIBLE, 'reversible campaign placement apply')
    campaign.saveAndExit(ID, 'MOM campaign reversible applied', G.CELL)
  end,
}
