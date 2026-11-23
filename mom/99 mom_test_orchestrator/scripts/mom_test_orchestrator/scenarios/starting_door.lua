local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local util = require('openmw.util')

local function yaw(rotation)
  local z = rotation:getAnglesZYX()
  return z
end

local function angleNear(left, right)
  local difference = left - right
  return math.abs(math.atan2(math.sin(difference), math.cos(difference))) < 0.01
end

return {
  id = 'starting_door',
  description = 'A moved door returns to its saved starting transform across repeated guard changes.',
  run = function()
    H.advanceToHour(7)
    local function findDoor(cell)
      return H.findFirstObject(cell, function(object)
        return H.normalizeRecordId(object.recordId) == 'rent_balmora_eight_door'
      end)
    end
    local cell = H.teleportInteriorReady(
      C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'starting door',
      function(current) return findDoor(current) ~= nil end)
    local door = assert(findDoor(cell))
    local start = H.copyPosition(door.startingPosition)
    local startYaw = yaw(door.startingRotation)
    local desired = H.offsetPosition(start, 24, 0, 0)

    -- Startup discovery must save the starting transform before the guard
    -- activates: OpenMW overwrites these fields when a door is teleported.
    H.waitFrames(30)
    local outside = H.offsetPosition(start, 120, 0, 0)
    door:teleport(C.EIGHT_PLATES, H.vector3From(outside), {
      rotation = util.transform.rotateZ(startYaw + math.rad(60)),
    })
    H.waitUntil(function()
      return door:isValid() and H.positionNear(door.position, outside, 1)
    end, C.LONG_TIMEOUT_FRAMES, 'external door move')

    for _ = 1, 2 do
      H.advanceToHour(9)
      H.waitUntil(function()
        return door:isValid() and H.positionNear(door.position, desired, 1)
          and angleNear(yaw(door.rotation), startYaw + math.rad(30))
      end, C.LONG_TIMEOUT_FRAMES, 'door starting transform apply')
      H.advanceToHour(11)
      H.waitUntil(function()
        return door:isValid() and H.positionNear(door.position, start, 1)
          and angleNear(yaw(door.rotation), startYaw)
      end, C.LONG_TIMEOUT_FRAMES, 'door starting transform revert')
    end
  end,
}
