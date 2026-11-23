local G = require('scripts.mom_test_orchestrator.scenarios.support.group1_common')

return {
  id = 'inventory_ensure',
  description = 'Ensure preserves excess additions and never restores consumed inventory on withdrawal.',
  run = function()
    G.toggle('inventory_ensure', false)
    local crate = G.crate()
    G.seed(crate)
    G.withdraw(crate)
  end,
}
