local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local ID = 'campaign_logical_move_verify'

return {
  id = ID,
  description = 'Resolve the moved source identity after restart and restore it.',
  run = function()
    local refId = campaign.handoffValue('logical_move.ref_id')
    local startingCellId = campaign.handoffValue('logical_move.starting_cell')
    local startingPosition = {
      x = assert(tonumber((campaign.handoffValue('logical_move.starting_x')))),
      y = assert(tonumber((campaign.handoffValue('logical_move.starting_y')))),
      z = assert(tonumber((campaign.handoffValue('logical_move.starting_z')))),
    }
    H.requireCurrentInterior(C.VASSAMSI_GROTTO)
    local beforeVisit = H.getObjectByRefId(refId)
    print(string.format('[MOMCampaign][LOOKUP] phase=before_destination_visit valid=%s cell=%s',
      tostring(beforeVisit ~= nil), tostring(beforeVisit and beforeVisit.cell and beforeVisit.cell.id)))
    if beforeVisit and beforeVisit.startingCell then
      H.expect(H.sameStartingIdentity(beforeVisit, startingCellId, startingPosition, 0.01),
        'direct lookup returned a different starting identity before destination visit')
    end
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'logical-move campaign destination after restart')
    local cell = H.requireCurrentInterior(C.EIGHT_PLATES)
    local moved = G.findMovedChest(cell)
    H.expect(moved ~= nil and H.scaleNear(moved.scale, 0.8),
      'moved logical target did not survive save/process restart')
    H.expect(moved.id == refId
        and H.sameStartingIdentity(moved, startingCellId, startingPosition, 0.01),
      'moved source identity changed across save/process restart')
    local afterVisit = H.getObjectByRefId(refId)
    H.expect(afterVisit ~= nil and afterVisit.id == refId
        and H.sameStartingIdentity(afterVisit, startingCellId, startingPosition, 0.01),
      'direct lookup failed after destination visit')
    G.setToggle('campaign_logical_move', false)
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'logical-move campaign source restore')
    H.waitUntil(function()
      local restored = H.getObjectByRefId(refId)
      return restored ~= nil
        and H.sameStartingIdentity(restored, startingCellId, startingPosition, 0.01)
        and H.normalizeCellId(restored.cell and restored.cell.id)
          == H.normalizeCellId(C.GUILD_OF_MAGES)
        and H.scaleNear(restored.scale, 1.0)
    end, C.LONG_TIMEOUT_FRAMES, 'logical identity restore after restart')
    campaign.logDiagnostics(ID, C.GUILD_OF_MAGES)
  end,
}
