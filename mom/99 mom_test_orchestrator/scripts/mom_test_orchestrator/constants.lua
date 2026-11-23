-- Exports shared world, action, guard, and state fixtures.
local modules = {
  (require('scripts.mom_test_orchestrator.fixtures.world')),
  (require('scripts.mom_test_orchestrator.fixtures.actions')),
  (require('scripts.mom_test_orchestrator.fixtures.guards')),
  (require('scripts.mom_test_orchestrator.fixtures.state')),
}

local M = {}

for i = 1, #modules do
  for name, value in pairs(modules[i]) do
    assert(M[name] == nil, 'duplicate harness fixture: ' .. tostring(name))
    M[name] = value
  end
end

return M
