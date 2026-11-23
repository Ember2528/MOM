local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')

local ID = 'campaign_starting_door_setup'

return {
  id = ID,
  description = 'Save a moved door while OpenMW reports its moved starting transform.',
  run = function()
    H.advanceToHour(7)
    local cell = H.teleportInteriorReady(
      C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'door restart setup',
      function(current)
        return H.findFirstObject(current, function(object)
          return H.normalizeRecordId(object.recordId) == 'rent_balmora_eight_door'
        end) ~= nil
      end)
    local door = assert(H.findFirstObject(cell, function(object)
      return H.normalizeRecordId(object.recordId) == 'rent_balmora_eight_door'
    end))
    local start = H.copyPosition(door.startingPosition)
    local startYaw = door.startingRotation:getAnglesZYX()
    campaign.emitValue('starting_door.id', door.id)
    campaign.emitValue('starting_door.x', start.x)
    campaign.emitValue('starting_door.y', start.y)
    campaign.emitValue('starting_door.z', start.z)
    campaign.emitValue('starting_door.yaw', startYaw)
    H.advanceToHour(9)
    local desired = H.offsetPosition(start, 24, 0, 0)
    H.waitUntil(function()
      return door:isValid() and H.positionNear(door.position, desired, 1)
    end, C.LONG_TIMEOUT_FRAMES, 'door restart apply')
    H.waitFrames(30)
    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION,
      'door restart save location')
    campaign.saveAndExit(ID, 'MOM starting door restart', C.VASSAMSI_GROTTO)
  end,
}
