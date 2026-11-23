local common = require('scripts.mom_test_orchestrator.scenarios.support.content_phase_common')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local C = require('scripts.mom_test_orchestrator.constants')
local ID = 'campaign_content_phase_setup'
return {id = ID, description = 'Create a fresh current-design save with mixed source definitions and placement.',
  run = function()
    local _, outputId, startup, runtimeHash = common.verify({singleSource = true})
    campaign.emitValue('content.output', outputId)
    campaign.emitValue('content.source', startup.sourceHash)
    campaign.emitValue('content.plan', startup.content.contentHash)
    campaign.emitValue('content.runtime', runtimeHash)
    campaign.saveAndExit(ID, 'MOM mixed content source', C.GUILD_OF_MAGES)
  end}
