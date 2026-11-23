-- Exports shared value, world, control, and diagnostic helpers.
local modules = {
  (require('scripts.mom_test_orchestrator.support.values')),
  (require('scripts.mom_test_orchestrator.support.world')),
  (require('scripts.mom_test_orchestrator.support.control')),
  (require('scripts.mom_test_orchestrator.support.diagnostics')),
  (require('scripts.mom_test_orchestrator.support.actor_observation')),
}

local M = {}

for i = 1, #modules do
  for name, value in pairs(modules[i]) do
    assert(M[name] == nil, 'duplicate harness helper export: ' .. tostring(name))
    M[name] = value
  end
end

return M
