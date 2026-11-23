local common = require('scripts.mom_test_orchestrator.scenarios.support.content_phase_common')
return {id = 'content_phase_mixed',
  description = 'One source supplies LOAD definitions and one GLOBAL placement without cross-phase actions.',
  run = function() common.verify() end}
