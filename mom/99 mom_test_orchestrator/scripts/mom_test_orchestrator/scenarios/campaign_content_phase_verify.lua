local common = require('scripts.mom_test_orchestrator.scenarios.support.content_phase_common')
return {id = 'campaign_content_phase_verify',
  description = 'A second reload preserves current-design LOAD definitions and the exact one GLOBAL output.',
  run = function() common.verify({singleSource = true, reloaded = true}) end}
