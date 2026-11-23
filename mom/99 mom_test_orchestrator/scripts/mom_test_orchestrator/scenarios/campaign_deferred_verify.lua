local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_deferred_verify'

return {
  id = ID,
  description = 'Close the restored guard while unloaded, then require terminal cleanup.',
  run = function()
    G.setToggle('campaign_deferred', false)
    local cell = G.teleport()
    G.waitAbsent(cell, G.DEFERRED, 'deferred cleanup after restart and revisit')
    campaign.logDiagnostics(ID, G.CELL)
  end,
}
