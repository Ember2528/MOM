local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_deferred_setup'

return {
  id = ID,
  description = 'Persist an applied operation while its target cell is unloaded.',
  run = function()
    G.setToggle('campaign_deferred', false)
    local cell = G.teleport()
    H.expect(G.count(cell, G.DEFERRED) == 0,
      'deferred campaign fixture was not at its absent baseline')
    G.setToggle('campaign_deferred', true)
    G.waitPresent(cell, G.DEFERRED, 'deferred campaign placement apply')
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'unload deferred campaign target')
    campaign.saveAndExit(ID, 'MOM campaign deferred cleanup', C.GUILD_OF_MAGES)
  end,
}
