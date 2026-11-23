local common = require('scripts.mom_test_orchestrator.scenarios.support.content_phase_common')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local C = require('scripts.mom_test_orchestrator.constants')
local ID = 'campaign_content_phase_resave'
return {id = ID, description = 'Reload current-design content and save again without repeated list or placement work.',
  run = function()
    common.verify({singleSource = true, reloaded = true})
    campaign.saveAndExit(ID, 'MOM mixed content second save', C.GUILD_OF_MAGES)
  end}
