local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local N = require('scripts.mom_test_orchestrator.scenarios.support.nested_attach_restart_common')
local B = require('scripts.mom_test_orchestrator.scenarios.support.nested_attach_batch_common')
local ID = 'campaign_nested_attach_setup'
return {
  id = ID,
  description = 'Save generated nested attachments from an unrelated cell.',
  run = function()
    local cell = H.teleportInteriorAtHour(12, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'nested attach inactive baseline')
    N.waitAbsent(cell, 'nested attach inactive baseline')
    B.wait(cell, false, 'abbreviated batch inactive baseline')
    cell = H.advanceLoadedInteriorToHour(2, C.EIGHT_PLATES)
    local found = N.waitReady(cell, 'nested attach setup')
    N.emit(campaign, found)
    B.emit(campaign, B.wait(cell, true, 'abbreviated batch setup'))
    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION, 'nested attach unrelated save cell')
    campaign.saveAndExit(ID, 'MOM nested attachments', C.VASSAMSI_GROTTO)
  end,
}
