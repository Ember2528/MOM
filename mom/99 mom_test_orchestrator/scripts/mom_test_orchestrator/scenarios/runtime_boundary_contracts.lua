local cases = require('scripts.mom_test_orchestrator.runtime_boundary_contract_cases')
local H = require('scripts.mom_test_orchestrator.helpers')

return {
  id = 'runtime_boundary_contracts',
  description = 'The public MOM boundary exposes one healthy schema-0 runtime.',
  run = function()
    local interface = H.momInterface()
    H.expect(interface ~= nil, 'MOM interface unavailable for runtime boundary contracts')
    cases.runAll(interface)
  end,
}
