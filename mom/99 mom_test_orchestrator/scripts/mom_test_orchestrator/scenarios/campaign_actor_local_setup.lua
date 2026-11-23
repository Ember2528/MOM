local I = require('openmw.interfaces')
local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_actor_local_setup'

return {
  id = ID,
  description = 'Save on a real between-tick boundary right after dispatching an actor-local kill command.',
  run = function()
    G.setToggle('campaign_actor_kill', false)
    G.setToggle('campaign_actor_spawn', false)
    local cell = G.teleport()
    H.expect(G.findActor(cell) == nil,
      'actor-local campaign fixture was not at its absent baseline')
    G.setToggle('campaign_actor_spawn', true)
    H.waitUntil(function()
      local actor = G.findActor(cell)
      return actor ~= nil and not H.objectIsDead(actor)
    end, 1200, 'actor-local campaign living target')

    G.setToggle('campaign_actor_kill', true)
    H.waitUntil(function()
      local actor = G.findActor(cell)
      local selfcheck = I.MOM and I.MOM.selfcheck and I.MOM.selfcheck() or nil
      local counts = selfcheck and selfcheck.runtime and selfcheck.runtime.counts or nil
      return (counts ~= nil and (counts.activeCommands or 0) > 0)
        or (actor ~= nil and H.objectIsDead(actor))
    end, 1200, 'actor-local kill dispatch or completion before save')
    campaign.saveAndExit(ID, 'MOM campaign actor-local pending', G.CELL)
  end,
}
