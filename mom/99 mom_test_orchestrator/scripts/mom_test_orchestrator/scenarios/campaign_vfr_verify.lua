local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local V = require('scripts.mom_test_orchestrator.scenarios.support.vfr_common')

return {
  id = 'campaign_vfr_verify',
  description = 'A fresh engine retains exact native VFR source/output IDs, KEEP, harvest and deposits.',
  run = function()
    local state = {}
    for _, key in ipairs({'sourceId', 'outputId', 'staticOutputId', 'keepId',
      'decorationAId', 'decorationBId'}) do
      state[key] = campaign.handoffValue('vfr.' .. key)
    end
    state.playerItems = tonumber((campaign.handoffValue('vfr.playerItems')))
    state.playerGold = tonumber((campaign.handoffValue('vfr.playerGold')))
    V.verify(V.teleport(), state)
  end,
}
