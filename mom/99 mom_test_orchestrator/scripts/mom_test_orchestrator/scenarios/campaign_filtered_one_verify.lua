local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local F = require('scripts.mom_test_orchestrator.scenarios.support.filtered_one_claim_common')
return {id = 'campaign_filtered_one_verify', description = 'Recover filtered child arbitration results.', run = function()
  H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'filtered child after restart')
  local found = F.wait(H.requireCurrentInterior(C.EIGHT_PLATES), 'filtered child after restart')
  for key, id in pairs(found) do H.expect(id == campaign.handoffValue('filtered.' .. key), 'object identity changed after restart: ' .. key) end
end}
