local R = require('scripts.mom_test_orchestrator.scenarios.support.respawning_container_common')

return {
  id = 'respawning_container_replacement',
  description = 'Untouched plant stays unresolved during capture, transfers native contents on apply, and preserves harvests across refill and revert.',
  run = function()
    local cell, state = R.prepareHarvestedReplacement()
    R.revert(cell, state)
    R.reactivate(cell, state)
  end,
}
