local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_logical_move_setup'

return {
  id = ID,
  description = 'Move a source ref, verify its new logical target, and save.',
  run = function()
    G.setToggle('campaign_logical_move', false)
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'logical-move campaign source setup')
    local source = H.findGuildChest(H.requireCurrentInterior(C.GUILD_OF_MAGES))
    H.expect(source ~= nil, 'logical-move campaign source chest is unavailable')
    local startingCellId = source.startingCell and source.startingCell.id
    local refId = source.id
    H.expect(refId ~= nil and startingCellId ~= nil and source.startingPosition ~= nil,
      'logical-move source has no starting identity')
    local startingPosition = H.copyPosition(source.startingPosition)
    campaign.emitValue('logical_move.ref_id', refId)
    campaign.emitValue('logical_move.starting_cell', startingCellId)
    campaign.emitValue('logical_move.starting_x', startingPosition.x)
    campaign.emitValue('logical_move.starting_y', startingPosition.y)
    campaign.emitValue('logical_move.starting_z', startingPosition.z)
    G.setToggle('campaign_logical_move', true)
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'logical-move campaign destination')
    local cell = H.requireCurrentInterior(C.EIGHT_PLATES)
    H.waitUntil(function()
      local moved = G.findMovedChest(cell)
      return moved ~= nil and moved.id == refId
        and H.sameStartingIdentity(moved, startingCellId, startingPosition, 0.01)
        and H.scaleNear(moved.scale, 0.8)
    end, C.LONG_TIMEOUT_FRAMES, 'logical-move campaign apply')
    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION,
      'logical-move campaign unrelated save location')
    campaign.saveAndExit(ID, 'MOM campaign moved logical identity', C.VASSAMSI_GROTTO)
  end,
}
