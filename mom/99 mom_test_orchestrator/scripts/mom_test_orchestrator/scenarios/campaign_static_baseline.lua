local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local S = require('scripts.mom_test_orchestrator.scenarios.support.campaign_static_common')

local ID = 'campaign_static_baseline'

return {
  id = ID,
  description = 'Prove the semantic static fixture positions are initially empty.',
  run = function()
    local cell = G.teleport()
    H.waitFrames(120)
    H.expect(S.count(cell, S.A) == 0 and S.count(cell, S.B) == 0,
      'semantic static fixture positions are not empty in the base cell')
    campaign.logDiagnostics(ID, G.CELL)
  end,
}
