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
  id = 'starting_transform',
  description = 'Relative transforms ignore a previous external move and revert to engine starting values.',
  run = function()
    H.advanceToHour(3)
    local cell = H.teleportInteriorReady(
      C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION, 'starting transform chest',
      function(current) return H.findGuildChest(current) ~= nil end)
    local chest = assert(H.findGuildChest(cell))
    local start = H.copyPosition(chest.startingPosition)
    local startYaw = yaw(chest.startingRotation)
    local outside = H.offsetPosition(start, 128, 96, 0)
    chest:teleport(C.GUILD_OF_MAGES, H.vector3From(outside), {
      rotation = util.transform.rotateZ(startYaw + math.rad(90)),
    })
    H.waitUntil(function()
      return chest:isValid() and H.positionNear(chest.position, outside, 1)
    end, C.LONG_TIMEOUT_FRAMES, 'external chest move')

    local desired = H.offsetPosition(start, 48, -16, 8)
    H.advanceToHour(5)
    H.waitUntil(function()
      return chest:isValid() and H.positionNear(chest.position, desired, 1)
        and angleNear(yaw(chest.rotation), startYaw + math.rad(45))
    end, C.LONG_TIMEOUT_FRAMES, 'relative starting transform apply')

    H.advanceToHour(7)
    H.waitUntil(function()
      return chest:isValid() and H.positionNear(chest.position, start, 1)
        and angleNear(yaw(chest.rotation), startYaw)
    end, C.LONG_TIMEOUT_FRAMES, 'starting transform revert')
  end,
}
