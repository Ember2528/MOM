local ROOT = 'scripts/mom_test_orchestrator/performance/'
local CONTRACT_SOURCES = {
  ROOT .. 'cases/integration.lua',
  ROOT .. 'integration_definitions.lua',
  ROOT .. 'protocol.lua',
  ROOT .. 'runner.lua',
  ROOT .. 'unsafe_runtime.lua',
  'host/launch.py',
  'host/scenario_inventory.py',
  'scripts/mom_test_orchestrator/scenario_inventory.lua',
}

local catalog = require('scripts.mom_test_orchestrator.scenario_inventory')
local seen = {}
for _, id in ipairs(catalog.integration) do
  for _, path in ipairs(catalog.fixtures[id]) do
    if not seen[path] then
      seen[path] = true
      CONTRACT_SOURCES[#CONTRACT_SOURCES + 1] = 'fixtures/data/' .. path
    end
  end
end
table.sort(CONTRACT_SOURCES)

local definitions = {
  {
    id = 'integration_loaded_cell_scan',
    version = 3,
    category = 'engine_world',
    unit = 'microseconds_per_operation',
    modes = {integration = true},
    operations = 25,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {scope = 'player-loaded-cell'},
  },
  {
    id = 'integration_selfcheck',
    version = 2,
    category = 'public_runtime',
    unit = 'microseconds_per_operation',
    modes = {integration = true},
    operations = 5,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {boundary = 'I.MOM.selfcheck'},
  },
  {
    id = 'integration_compile_report',
    version = 2,
    category = 'compiler_compat',
    unit = 'microseconds_per_operation',
    modes = {integration = true},
    operations = 20,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {boundary = 'I.MOM.compileReport'},
  },
}

for i = 1, #definitions do
  definitions[i].contractSources = CONTRACT_SOURCES
end

return definitions
