local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local C = require('scripts.mom_test_orchestrator.scenarios.support.campaign_container_common')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_container_revert_boundary'

return {
  id = ID,
  description = 'Save across a real between-tick container-transfer revert boundary.',
  run = function()
    local cell = H.requireCurrentInterior(G.CELL)
    G.setToggle('campaign_container_transfer', true)
    C.waitTransferred(cell, 'container transfer survived restart before revert')

    G.setToggle('campaign_container_transfer', false)
    H.waitUntil(function()
      local source = C.source(cell)
      return source ~= nil
        and (H.countContainerRecord(source, C.ITEM_RECORD) == C.ITEM_COUNT
          or C.output(cell) == nil)
    end, 1200, 'container revert began returning items before save')
    C.logState(cell, 'revert-pending-save')
    campaign.saveAndExit(ID, 'MOM container revert pending', G.CELL)
  end,
}
