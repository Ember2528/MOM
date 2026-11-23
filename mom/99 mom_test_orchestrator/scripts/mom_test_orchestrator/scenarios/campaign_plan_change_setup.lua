local H = require('scripts.mom_test_orchestrator.helpers')
local I = require('openmw.interfaces')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local P = require('scripts.mom_test_orchestrator.scenarios.support.campaign_plan_change_common')

local ID = 'campaign_plan_change_setup'

return {
  id = ID,
  description = 'Install the initial state plan and save its concrete operation.',
  run = function()
    G.setToggle('campaign_plan_change', false)
    local cell = G.teleport()
    H.expect(P.count(cell, P.V1) == 0 and P.count(cell, P.V2) == 0,
      'plan-change fixture was not at its absent baseline')
    G.setToggle('campaign_plan_change', true)
    P.waitCount(cell, P.V1, 1, 'initial plan active operation')
    local before = I.MOM.compileReport({log = false})
    campaign.emitValue('plan.v1.hash', before.activeManifestHash)
    campaign.saveAndExit(
      ID,
      'MOM saved the initial semantic plan operation',
      G.CELL
    )
  end,
}
