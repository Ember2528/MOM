local repoRoot = assert(arg[1], 'repository root argument is required')

package.path = table.concat({
  repoRoot .. '/mom/00 OpenMW/?.lua',
  repoRoot .. '/mom/99 mom_test_orchestrator/?.lua',
  package.path,
}, ';')

local algorithmic = require('scripts.mom_test_orchestrator.performance.cases.algorithmic')
local integration = require('scripts.mom_test_orchestrator.performance.integration_definitions')
local protocol = require('scripts.mom_test_orchestrator.performance.protocol')
local cases = {}
for i = 1, #algorithmic do cases[#cases + 1] = algorithmic[i] end
for i = 1, #integration do cases[#cases + 1] = integration[i] end
local workloads = protocol.array()
for i = 1, #cases do
  local case = cases[i]
  assert(case.requiresFreshProcess == nil
      or type(case.requiresFreshProcess) == 'boolean',
    'requiresFreshProcess must be boolean: ' .. tostring(case.id))
  local modes = protocol.array()
  for _, mode in ipairs({'standalone', 'embedded', 'integration'}) do
    if case.modes[mode] then modes[#modes + 1] = mode end
  end
  local contractSources = protocol.array()
  for _, source in ipairs(case.contractSources or {}) do
    contractSources[#contractSources + 1] = source
  end
  workloads[#workloads + 1] = {
    id = case.id,
    version = case.version,
    category = case.category,
    modes = modes,
    operations = case.operations,
    minimumSampleSeconds = case.minimumSampleSeconds,
    gcPolicy = case.gcPolicy,
    semantics = case.semantics,
    requiresFreshProcess = case.requiresFreshProcess == true,
    contractSources = contractSources,
  }
end
io.stdout:write(protocol.encode({schemaVersion = 3, workloads = workloads}), '\n')
