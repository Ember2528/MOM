local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local F = require('scripts.mom_test_orchestrator.scenarios.support.filtered_one_claim_common')
local ID = 'campaign_filtered_one_setup'
return {id = ID, description = 'Save filtered child arbitration results.', run = function()
  H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'filtered child setup')
  local found = F.wait(H.requireCurrentInterior(C.EIGHT_PLATES), 'filtered child setup')
  for key, id in pairs(found) do campaign.emitValue('filtered.' .. key, id) end
  H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION, 'filtered child save')
  campaign.saveAndExit(ID, 'MOM filtered child', C.VASSAMSI_GROTTO)
end}
