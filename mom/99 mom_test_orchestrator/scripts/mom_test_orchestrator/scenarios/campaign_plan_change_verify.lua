local H = require('scripts.mom_test_orchestrator.helpers')
local I = require('openmw.interfaces')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local P = require('scripts.mom_test_orchestrator.scenarios.support.campaign_plan_change_common')

local ID = 'campaign_plan_change_verify'

return {
  id = ID,
  description = 'Converge saved v1 work to the v2 plan during process startup.',
  run = function()
    local cell = H.requireCurrentInterior(G.CELL)
    G.setToggle('campaign_plan_change', true)
    P.waitCount(cell, P.V1, 0, 'stale plan cleanup after restart')
    P.waitCount(cell, P.V2, 1, 'replacement plan operation after restart')
    local report = I.MOM.compileReport({log = false})
    H.expect(report.status == 'running'
        and report.activeManifestHash ~= campaign.handoffValue('plan.v1.hash'),
      'startup plan-change campaign did not compile a distinct replacement plan')
    H.expect(P.count(cell, P.V1) == 0,
      'stale plan operation reappeared after startup convergence')
    campaign.logDiagnostics(ID, G.CELL)
  end,
}
