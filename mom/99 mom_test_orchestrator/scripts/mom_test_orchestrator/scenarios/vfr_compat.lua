local V = require('scripts.mom_test_orchestrator.scenarios.support.vfr_common')
local H = require('scripts.mom_test_orchestrator.helpers')

return {
  id = 'vfr_compat',
  description = 'VFR lowers to native Static/Container replacement, authoritative KEEP, SSS arbitration and native plant refill.',
  run = function()
    local _, state = V.setup()
    H.waitFrames(30)
    V.verify(V.teleport(), state)
  end,
}
