local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local N = require('scripts.mom_test_orchestrator.scenarios.support.nested_attach_restart_common')
local B = require('scripts.mom_test_orchestrator.scenarios.support.nested_attach_batch_common')
return {
  id = 'campaign_nested_attach_verify',
  description = 'Verify generated nested attachments and filtered descendants survive restart and clean up.',
  run = function()
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'nested attach after restart')
    local cell = H.requireCurrentInterior(C.EIGHT_PLATES)
    local found = N.waitReady(cell, 'nested attach after restart')
    N.expectSame(campaign, found)
    B.expectSame(campaign, B.wait(cell, true, 'abbreviated batch after restart'))
    cell = H.advanceLoadedInteriorToHour(12, C.EIGHT_PLATES)
    N.waitAbsent(cell, 'nested attach cleanup after restart')
    B.wait(cell, false, 'abbreviated batch cleanup after restart')
  end,
}
