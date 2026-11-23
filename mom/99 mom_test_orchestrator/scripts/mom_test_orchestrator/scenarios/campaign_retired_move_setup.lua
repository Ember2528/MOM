local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local R = require('scripts.mom_test_orchestrator.scenarios.support.retired_move_common')

local ID = 'campaign_retired_move_setup'

return {
  id = ID,
  description = 'Apply a permanent moving child, leave both cells unloaded, and save before guard deactivation.',
  run = function()
    G.setToggle(R.TOGGLE, false)
    G.teleport()
    G.setToggle(R.TOGGLE, true)
    H.waitFrames(60)
    campaign.logDiagnostics(ID .. ':applied', C.EIGHT_PLATES)
    local cell = R.destination()
    H.waitUntil(function() return R.count(cell) == 1 end,
      C.LONG_TIMEOUT_FRAMES, 'permanent child moved generated output')
    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION,
      'retired child unrelated save location')
    campaign.saveAndExit(ID, 'MOM retired moving child', C.VASSAMSI_GROTTO)
  end,
}
