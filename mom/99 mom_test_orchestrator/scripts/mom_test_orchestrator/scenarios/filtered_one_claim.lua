local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local F = require('scripts.mom_test_orchestrator.scenarios.support.filtered_one_claim_common')
return {id = 'filtered_one_claim', description = 'Filtered single-row child yields claims to a matching sibling.', run = function()
  H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'filtered child')
  F.wait(H.requireCurrentInterior(C.EIGHT_PLATES), 'filtered child')
end}
