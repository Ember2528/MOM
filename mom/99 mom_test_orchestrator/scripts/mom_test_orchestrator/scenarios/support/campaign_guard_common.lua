local core = require('openmw.core')

local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local guard_provider = require('scripts.mom_test_orchestrator.guard_provider')

local M = {
  CELL = C.EIGHT_PLATES,
  RECORD = 'light_de_paper_lantern_off',
  REVERSIBLE = {x = 1200.0, y = 720.0, z = -311.0},
  PROVIDER_ACTIVE = {x = 1280.0, y = 720.0, z = -311.0},
  PROVIDER_INACTIVE = {x = 1360.0, y = 720.0, z = -311.0},
  DEFERRED = {x = 1440.0, y = 720.0, z = -311.0},
  LOGICAL_MOVE = {x = 820.0, y = 860.0, z = -244.0},
  ACTOR = {x = 1520.0, y = 720.0, z = -311.0},
}

local function eventName(key)
  return 'external:harness:toggle_changed:' .. tostring(key)
end

function M.setToggle(key, value)
  assert(guard_provider.set(key, value == true))
  core.sendGlobalEvent('MOM_GuardEvent', {
    event = eventName(key),
    payload = {ignoredByMOM = true},
  })
  H.waitFrames(10)
end

function M.emit(key)
  core.sendGlobalEvent('MOM_GuardEvent', {
    event = eventName(key),
    payload = {ignoredByMOM = true},
  })
  H.waitFrames(10)
end

function M.teleport()
  H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
    'process-boundary guard campaign setup')
  return H.requireCurrentInterior(C.EIGHT_PLATES)
end

function M.count(cell, position)
  return H.countRecordNearPosition(cell, M.RECORD, position, 16)
end

function M.waitPresent(cell, position, description)
  H.waitUntil(function() return M.count(cell, position) == 1 end,
    C.LONG_TIMEOUT_FRAMES, description)
end

function M.waitAbsent(cell, position, description)
  H.waitUntil(function() return M.count(cell, position) == 0 end,
    C.LONG_TIMEOUT_FRAMES, description)
end

function M.findMovedChest(cell)
  return H.findClosestObject(cell, function(obj)
    return H.objectRecordId(obj) == 'chest_small_01_ingredie'
      and H.positionNear(obj.position, M.LOGICAL_MOVE, 96)
  end, M.LOGICAL_MOVE)
end

function M.findActor(cell)
  return H.findFirstObject(cell, function(obj)
    return H.objectRecordId(obj) == 'rat'
      and H.sameStartingIdentity(obj, M.CELL, M.ACTOR, 8)
  end)
end

return M
