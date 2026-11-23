local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local S = require('scripts.mom_test_orchestrator.scenarios.support.campaign_static_common')

local ID = 'campaign_static_removed'

return {
  id = ID,
  description = 'Retain removed static world history and its operation evidence.',
  run = function()
    local cell = H.requireCurrentInterior(G.CELL)
    S.waitCount(cell, S.A, 1, 'removed static placement retained as world history')
    S.waitCount(cell, S.B, 1, 'current static placement after action removal')
    local priorHash = campaign.handoffValue('static.v2.hash')
    local priorCount = tonumber((campaign.handoffValue('static.v2.operations')))
    H.expect(priorCount ~= nil, 'extended static operation count is unavailable')
    local report = S.waitStatus(function(current)
      return current.activeManifestHash ~= priorHash
        and S.operationCount(current) >= priorCount
        and S.staticIdle(current)
    end, 'removed static history stabilization')
    H.expect(S.count(cell, S.A) == 1 and S.count(cell, S.B) == 1,
      'static removal replayed or erased historical world state')
    S.logStatus('removed', report)
    campaign.logDiagnostics(ID, G.CELL)
    campaign.emitValue('static.v3.hash', report.activeManifestHash)
    campaign.emitValue('static.v3.operations', S.operationCount(report))
    campaign.saveAndExit(ID, 'MOM retained static history', G.CELL)
  end,
}
