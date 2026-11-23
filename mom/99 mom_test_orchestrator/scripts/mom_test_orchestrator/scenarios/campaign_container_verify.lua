local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local C = require('scripts.mom_test_orchestrator.scenarios.support.campaign_container_common')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_container_verify'

return {
  id = ID,
  description = 'Verify the final interrupted transfer revert restores one exact baseline.',
  run = function()
    local cell = H.requireCurrentInterior(G.CELL)
    G.setToggle('campaign_container_transfer', false)
    C.waitBaseline(cell, 'container transfer final restart recovery')
    H.waitFrames(20)
    C.waitBaseline(cell, 'container transfer stable final baseline')
    campaign.logDiagnostics(ID, G.CELL)
  end,
}
