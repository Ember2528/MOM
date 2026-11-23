local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_actor_local_verify'

return {
  id = ID,
  description = 'Resume one actor-local command and finalize one durable kill operation.',
  run = function()
    local cell = H.requireCurrentInterior(G.CELL)
    H.waitUntil(function()
      local actor = G.findActor(cell)
      return actor ~= nil and H.objectIsDead(actor)
        and H.runtimeOperationTargetCount('kill_actor', 'ref', 'rat') == 1
    end, 1200, 'actor-local command completion after restart')
    H.waitFrames(20)
    H.expect(H.runtimeOperationTargetCount('kill_actor', 'ref', 'rat') == 1,
      'actor-local command produced more than one terminal operation')
    campaign.logDiagnostics(ID, G.CELL)
  end,
}
