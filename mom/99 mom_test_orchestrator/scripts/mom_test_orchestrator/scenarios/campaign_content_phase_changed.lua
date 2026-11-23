local common = require('scripts.mom_test_orchestrator.scenarios.support.content_phase_common')
return {id = 'campaign_content_phase_changed',
  description = 'Restart with edited LOAD definitions while retaining the same saved GLOBAL placement.',
  run = function()
    common.verify({singleSource = true, reloaded = true, changedDefinitions = true})
  end}
