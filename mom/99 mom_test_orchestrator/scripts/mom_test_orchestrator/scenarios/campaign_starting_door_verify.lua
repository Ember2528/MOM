local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')

local ID = 'campaign_starting_door_verify'

return {
  id = ID,
  description = 'Restore a moved door to its retained starting transform after a fresh process.',
  run = function()
    local refId = campaign.handoffValue('starting_door.id')
    local start = {
      x = assert(tonumber((campaign.handoffValue('starting_door.x')))),
      y = assert(tonumber((campaign.handoffValue('starting_door.y')))),
      z = assert(tonumber((campaign.handoffValue('starting_door.z')))),
    }
    local startYaw = assert(tonumber((campaign.handoffValue('starting_door.yaw'))))
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'door restart verification')
    H.advanceToHour(11)
    H.waitUntil(function()
      local door = H.getObjectByRefId(refId)
      if door == nil or not H.positionNear(door.position, start, 1) then return false end
      local yaw = door.rotation:getAnglesZYX()
      local difference = yaw - startYaw
      return math.abs(math.atan2(math.sin(difference), math.cos(difference))) < 0.01
    end, C.LONG_TIMEOUT_FRAMES, 'door starting transform after restart')
    campaign.logDiagnostics(ID, C.EIGHT_PLATES)
  end,
}
