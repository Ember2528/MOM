local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local V = require('scripts.mom_test_orchestrator.scenarios.support.vfr_common')
local ID = 'campaign_vfr_setup'

return {
  id = ID,
  description = 'Save native VFR outputs after plant refill, harvest and player deposit.',
  run = function()
    local _, state = V.setup()
    for _, key in ipairs({'sourceId', 'outputId', 'staticOutputId', 'keepId',
      'decorationAId', 'decorationBId', 'playerItems', 'playerGold'}) do
      campaign.emitValue('vfr.' .. key, state[key])
    end
    campaign.saveAndExit(ID, 'MOM campaign VFR native outputs', V.CELL)
  end,
}
