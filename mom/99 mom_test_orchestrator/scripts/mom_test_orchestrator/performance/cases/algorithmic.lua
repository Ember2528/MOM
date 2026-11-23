local cases = {}
local ROOT = 'scripts/mom_test_orchestrator/performance/'
local SHARED_CONTRACT_SOURCES = {
  ROOT .. 'cases/algorithmic.lua',
  'scripts/mom_test_orchestrator/manifest_fixture.lua',
  ROOT .. 'cases/algorithmic/support.lua',
  ROOT .. 'protocol.lua',
  ROOT .. 'runner.lua',
  ROOT .. 'unsafe_runtime.lua',
}

local function define(id, definition, execute)
  assert(type(id) == 'string' and id ~= '', 'performance case id is required')
  assert(type(definition) == 'table', 'performance case definition is required')
  assert(type(execute) == 'function', 'performance case execute function is required')
  definition.id = id
  definition.version = definition.version or 1
  definition.unit = 'microseconds_per_operation'
  definition.modes = definition.modes or {standalone = true, embedded = true}
  definition.execute = execute
  cases[#cases + 1] = definition
end

local function defineFrom(source, extraSources)
  local contractSources = {}
  for i = 1, #SHARED_CONTRACT_SOURCES do
    contractSources[#contractSources + 1] = SHARED_CONTRACT_SOURCES[i]
  end
  contractSources[#contractSources + 1] = ROOT .. 'cases/algorithmic/' .. source
  for i = 1, #(extraSources or {}) do
    contractSources[#contractSources + 1] =
      ROOT .. 'cases/algorithmic/' .. extraSources[i]
  end
  table.sort(contractSources)

  return function(id, definition, execute)
    definition.contractSources = contractSources
    define(id, definition, execute)
  end
end

local registerRuntime = require('scripts.mom_test_orchestrator.performance.cases.algorithmic.runtime')
local compilerCases = require('scripts.mom_test_orchestrator.performance.cases.algorithmic.compiler')
local registerStatic = require('scripts.mom_test_orchestrator.performance.cases.algorithmic.static')
local registerPersistence = require('scripts.mom_test_orchestrator.performance.cases.algorithmic.persistence')
local registerContainer = require('scripts.mom_test_orchestrator.performance.cases.algorithmic.container')

registerRuntime(defineFrom('runtime.lua'))
compilerCases.register(defineFrom('compiler.lua'))
registerStatic(defineFrom('static.lua'))
registerPersistence(defineFrom('persistence.lua'))
registerContainer(defineFrom('container.lua'))

return cases
