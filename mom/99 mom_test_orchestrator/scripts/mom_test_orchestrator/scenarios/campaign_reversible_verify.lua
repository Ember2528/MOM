local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_reversible_verify'

return {
  id = ID,
  description = 'Load applied placement, close guard, and restore exact baseline.',
  run = function()
    local cell = H.requireCurrentInterior(G.CELL)
    H.expect(G.count(cell, G.REVERSIBLE) == 1,
      'reversible campaign operation did not survive save/process restart')
    G.setToggle('campaign_reversible', false)
    G.waitAbsent(cell, G.REVERSIBLE, 'reversible campaign exact baseline restore')
    campaign.logDiagnostics(ID, G.CELL)
  end,
}
