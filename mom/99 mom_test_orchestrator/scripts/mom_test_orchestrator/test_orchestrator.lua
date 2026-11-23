local optionsOk, runOptions = pcall(require, 'scripts.mom_test_orchestrator.run_options')
if optionsOk and type(runOptions) == 'table' and runOptions.mode == 'performance' then
  return {}
end

local runner = require('scripts.mom_test_orchestrator.runner')
local guard_provider = require('scripts.mom_test_orchestrator.guard_provider')

return {
  interfaceName = 'MOMTestOrchestrator',
  interface = {
    version = 1,
    run = runner.run,
    status = runner.status,
    report = runner.report,
    read = guard_provider.read,
  },
  engineHandlers = {
    onInit = runner.onInit,
    onLoad = runner.onLoad,
    onUpdate = runner.onUpdate,
    onActorActive = runner.onActorActive,
  },
}
