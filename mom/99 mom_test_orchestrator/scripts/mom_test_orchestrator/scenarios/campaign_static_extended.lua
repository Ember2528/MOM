local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local S = require('scripts.mom_test_orchestrator.scenarios.support.campaign_static_common')

local ID = 'campaign_static_extended'

return {
  id = ID,
  description = 'Prove reorder stability and one disjoint static addition.',
  run = function()
    local cell = H.requireCurrentInterior(G.CELL)
    S.waitCount(cell, S.A, 1, 'reordered semantic static placement after restart')
    S.waitCount(cell, S.B, 1, 'new disjoint static placement after restart')
    local priorHash = campaign.handoffValue('static.v1.hash')
    local priorCount = tonumber((campaign.handoffValue('static.v1.operations')))
    H.expect(priorCount ~= nil, 'initial static operation count is unavailable')
    local report = S.waitStatus(function(current)
      return current.activeManifestHash ~= priorHash
        and S.operationCount(current) >= priorCount + 1
        and S.staticIdle(current)
    end, 'semantic static addition completion')
    H.expect(S.count(cell, S.A) == 1,
      'source reorder replayed the unchanged static operation')
    S.logStatus('extended', report)
    campaign.logDiagnostics(ID, G.CELL)
    campaign.emitValue('static.v2.hash', report.activeManifestHash)
    campaign.emitValue('static.v2.operations', S.operationCount(report))
    campaign.saveAndExit(ID, 'MOM extended semantic static plan', G.CELL)
  end,
}
