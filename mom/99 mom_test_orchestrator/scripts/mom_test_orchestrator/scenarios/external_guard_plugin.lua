local core = require('openmw.core')
local I = require('openmw.interfaces')
local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local guard_provider = require('scripts.mom_test_orchestrator.guard_provider')

local TOGGLE_KEY = 'external_guard'
local EVENT_NAME = 'external:harness:toggle_changed:' .. TOGGLE_KEY
local LANTERN_POSITION = {
  x = 1260.0,
  y = 970.0,
  z = -311.0,
}

local function emitToggle(value)
  assert(guard_provider.set(TOGGLE_KEY, value == true))
  local accessible, provider = pcall(function() return I.MOMTestOrchestrator end)
  local readable, read = pcall(function() return provider and provider.read or nil end)
  H.expect(accessible and readable and type(read) == 'function',
    'external guard provider interface is unavailable')
  local readOk, observed, readError = pcall(read, {key = TOGGLE_KEY})
  H.expect(readOk and observed == (value == true),
    'external guard provider interface returned stale authority: ' .. tostring(readError))
  core.sendGlobalEvent('MOM_GuardEvent', {
    event = EVENT_NAME,
    payload = {ignoredByMOM = true},
  })
end

local function runtimeDiagnostics(cell)
  local objects = {}
  H.eachCellObject(cell, function(obj)
    if H.objectRecordId(obj) == H.normalizeRecordId(C.CHILD_LANTERN_RECORD_ID)
        or H.positionNear(obj.position, LANTERN_POSITION, 64) then
      local position = H.copyPosition(obj.position)
      objects[#objects + 1] = string.format('%s:%s:%s:(%.1f,%.1f,%.1f)',
        tostring(obj.id), tostring(obj.recordId), tostring(obj.enabled ~= false),
        position.x, position.y, position.z)
    end
  end)
  return H.runtimeStatusText() .. ' objects={' .. table.concat(objects, ',') .. '}'
end

return {
  id = 'external_guard_plugin',
  description = 'A harness guard plugin receives guardEvent and wakes through MOM_GuardEvent.',
  run = function()
    emitToggle(false)
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates external guard setup')
    local cell = H.requireCurrentInterior(C.EIGHT_PLATES)

    H.expect(H.countRecordNearPosition(cell, C.CHILD_LANTERN_RECORD_ID, LANTERN_POSITION, 16) == 0,
      'external guard lantern should be absent while toggle is false')

    emitToggle(true)
    local applied, applyError = pcall(function()
      H.waitUntil(function()
        return H.countRecordNearPosition(cell, C.CHILD_LANTERN_RECORD_ID, LANTERN_POSITION, 16) > 0
      end, C.LONG_TIMEOUT_FRAMES, 'external guard spawned lantern')
    end)
    if not applied then error(tostring(applyError) .. '; ' .. runtimeDiagnostics(cell)) end

    emitToggle(false)
    H.waitUntil(function()
      return H.countRecordNearPosition(cell, C.CHILD_LANTERN_RECORD_ID, LANTERN_POSITION, 16) == 0
    end, C.LONG_TIMEOUT_FRAMES, 'external guard reverted lantern')
  end,
}
