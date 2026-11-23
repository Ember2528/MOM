local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local guard_provider = require('scripts.mom_test_orchestrator.guard_provider')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_provider_verify'

return {
  id = ID,
  description = 'Provider loss preserves active work and applies no inactive work.',
  run = function()
    local cell = H.requireCurrentInterior(G.CELL)
    H.expect(G.count(cell, G.PROVIDER_ACTIVE) == 1
        and G.count(cell, G.PROVIDER_INACTIVE) == 0,
      'provider campaign save did not restore active/inactive world state')
    guard_provider.setAvailable(false)
    G.emit('campaign_provider_active')
    G.emit('campaign_provider_inactive')
    H.waitFrames(20)
    H.expect(G.count(cell, G.PROVIDER_ACTIVE) == 1,
      'unavailable provider tore down an active saved operation')
    H.expect(G.count(cell, G.PROVIDER_INACTIVE) == 0,
      'unavailable provider applied new work')
    campaign.logDiagnostics(ID, G.CELL)
  end,
}
