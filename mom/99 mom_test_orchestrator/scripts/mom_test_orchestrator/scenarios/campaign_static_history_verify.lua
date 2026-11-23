local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local S = require('scripts.mom_test_orchestrator.scenarios.support.campaign_static_common')

local ID = 'campaign_static_history_verify'

return {
  id = ID,
  description = 'Verify static history remains stable across another real restart.',
  run = function()
    local cell = H.requireCurrentInterior(G.CELL)
    S.waitCount(cell, S.A, 1, 'historical static placement after second restart')
    S.waitCount(cell, S.B, 1, 'current static placement after second restart')
    local expectedHash = campaign.handoffValue('static.v3.hash')
    local expectedCount = tonumber((campaign.handoffValue(
      'static.v3.operations'
    )))
    local report = S.waitStatus(function(current)
      return current.activeManifestHash == expectedHash
        and S.operationCount(current) >= expectedCount
        and S.staticIdle(current)
    end, 'stable static history after restart')
    H.waitFrames(120)
    H.expect(S.count(cell, S.A) == 1 and S.count(cell, S.B) == 1,
      'static history replayed or disappeared after restart')
    S.logStatus('verify', report)
    campaign.logDiagnostics(ID, G.CELL)
  end,
}
