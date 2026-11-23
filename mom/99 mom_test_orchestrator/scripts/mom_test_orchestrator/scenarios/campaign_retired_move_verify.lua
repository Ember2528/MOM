local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local R = require('scripts.mom_test_orchestrator.scenarios.support.retired_move_common')

local ID = 'campaign_retired_move_verify'

return {
  id = ID,
  description = 'Recover and remove the moved generated output after child retirement and restart.',
  run = function()
    G.setToggle(R.TOGGLE, false)
    local cell = R.destination()
    H.waitFrames(120)
    campaign.logDiagnostics(ID .. ':cleanup', C.GUILD_OF_MAGES)
    H.waitUntil(function() return R.count(cell) == 0 end,
      C.LONG_TIMEOUT_FRAMES, 'retired moving child parent cleanup')
    G.setToggle(R.TOGGLE, true)
    H.waitUntil(function() return R.count(cell) == 1 end,
      C.LONG_TIMEOUT_FRAMES, 'fresh output after retired child cleanup')
    G.setToggle(R.TOGGLE, false)
    H.waitUntil(function() return R.count(cell) == 0 end,
      C.LONG_TIMEOUT_FRAMES, 'fresh output cleanup')
    campaign.logDiagnostics(ID, C.GUILD_OF_MAGES)
  end,
}
