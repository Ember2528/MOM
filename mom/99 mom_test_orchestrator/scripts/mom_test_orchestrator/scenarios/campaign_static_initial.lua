local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local S = require('scripts.mom_test_orchestrator.scenarios.support.campaign_static_common')

local ID = 'campaign_static_initial'

return {
  id = ID,
  description = 'Apply one semantic static operation and record its durable count.',
  run = function()
    local cell = G.teleport()
    S.waitCount(cell, S.A, 1, 'initial semantic static placement')
    H.expect(S.count(cell, S.B) == 0,
      'future static marker existed in the initial startup plan')
    local report = S.waitStatus(function(current)
      return S.staticIdle(current) and S.operationCount(current) > 0
    end, 'terminal initial static plan')
    S.logStatus('initial', report)
    campaign.logDiagnostics(ID, G.CELL)
    campaign.emitValue('static.v1.hash', report.activeManifestHash)
    campaign.emitValue('static.v1.operations', S.operationCount(report))
    campaign.saveAndExit(ID, 'MOM initial semantic static plan', G.CELL)
  end,
}
