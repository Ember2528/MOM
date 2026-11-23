local H = require('scripts.mom_test_orchestrator.helpers')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local C = require('scripts.mom_test_orchestrator.scenarios.support.campaign_container_common')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_container_apply_boundary'

return {
  id = ID,
  description = 'Save across real between-tick container-transfer apply boundaries.',
  run = function()
    local phase = campaign.handoffValue('container.phase')
    local cell
    if phase == 'apply_pending' then
      G.setToggle('campaign_container_transfer', false)
      cell = C.teleport()
      H.waitUntil(function() return C.source(cell) ~= nil end,
        1200, 'container campaign source placement')
      local source = C.source(cell)
      H.expect(H.countContainerRecord(source, C.ITEM_RECORD) == 0,
        'container campaign source item baseline was not empty')
      H.addContainerRecord(source, C.ITEM_RECORD, C.ITEM_COUNT)
      C.waitBaseline(cell, 'container campaign initial baseline')

      G.setToggle('campaign_container_transfer', true)
      H.waitUntil(function()
        return C.output(cell) ~= nil
      end, 1200, 'container output created before transfer flush')
      C.logState(cell, 'apply-pending-save')
      campaign.saveAndExit(ID, 'MOM container apply pending', G.CELL)
    elseif phase == 'apply_committed' then
      cell = H.requireCurrentInterior(G.CELL)
      G.setToggle('campaign_container_transfer', true)
      C.logState(cell, 'prior-apply-recovery')
      C.waitTransferred(cell, 'container apply recovery after restart')
      C.logState(cell, 'apply-committed-save')
      campaign.saveAndExit(ID, 'MOM container apply committed', G.CELL)
    else
      error('unknown container apply phase: ' .. tostring(phase), 0)
    end
  end,
}
