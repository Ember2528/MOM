local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local core = require('openmw.core')
local world = require('openmw.world')
local provider = require('scripts.mom_test_orchestrator.guard_provider')

local M = {GOLD = 'gold_001', CRATE = 'crate_01_eggs'}
local CRATE_START = {x = -65.124, y = 305.476, z = 37.0}

function M.toggle(key, value)
  assert(provider.set(key, value))
  core.sendGlobalEvent('MOM_GuardEvent', {
    event = 'external:harness:toggle_changed:' .. key,
  })
end

function M.ref(number)
  return world.getObjectByFormId(core.getFormId('Morrowind.esm', number))
end

function M.crate()
  H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'group 1 fixture')
  local cell = H.requireCurrentInterior(C.EIGHT_PLATES)
  local crate
  H.waitUntil(function()
    crate = H.findRecordNearPosition(cell, M.CRATE, CRATE_START, 16)
    return crate ~= nil
  end, C.LONG_TIMEOUT_FRAMES, 'group 1 egg crate')
  local inventory = assert(H.containerInventory(crate), 'egg crate inventory unavailable')
  if not inventory:isResolved() then inventory:resolve() end
  H.expect(inventory:isResolved(), 'egg crate inventory did not resolve')
  return crate
end

function M.count(crate, expected, description)
  H.waitUntil(function()
    return H.countContainerRecord(crate, M.GOLD) == expected
  end, C.LONG_TIMEOUT_FRAMES, description)
end

function M.settled()
  H.waitUntil(function()
    local report = H.momInterface().selfcheck()
    local runtime = report.runtime or {}
    local counts, queues = runtime.counts or {}, runtime.queues or {}
    local state = queues.state or {}
    return report.ok == true and counts.scheduledOperations == 0
      and counts.activeCommands == 0 and counts.awaitingCompletions == 0
      and (state.queued or 0) == 0 and (state.pendingOwners or 0) == 0
  end, C.LONG_TIMEOUT_FRAMES, 'inventory operation completion')
end

function M.seed(crate)
  H.expect(H.countContainerRecord(crate, M.GOLD) == 0, 'ensure baseline is not empty')
  H.addContainerRecord(crate, M.GOLD, 2)
  M.count(crate, 2, 'ensure baseline gold')
  M.toggle('inventory_ensure', true)
  M.count(crate, 10, 'minimum inventory creates only the deficit')
  M.settled()
  H.addContainerRecord(crate, M.GOLD, 7)
  M.count(crate, 17, 'outside inventory additions')
  H.waitFrames(30)
  H.expect(H.countContainerRecord(crate, M.GOLD) == 17, 'ensure trimmed outside additions')
end

function M.withdraw(crate)
  M.toggle('inventory_ensure', false)
  M.count(crate, 9, 'withdraw only the eight ensured copies')
  M.settled()
  M.toggle('inventory_ensure', true)
  M.count(crate, 10, 'reopen ensures the new one-item deficit')
  M.settled()
  local inventory = assert(H.containerInventory(crate))
  local destination = assert(H.actorInventory(H.player()))
  for _, item in ipairs(inventory:findAll(M.GOLD)) do item:moveInto(destination) end
  M.count(crate, 0, 'consume ensured inventory')
  M.toggle('inventory_ensure', false)
  H.waitFrames(90)
  H.expect(H.countContainerRecord(crate, M.GOLD) == 0, 'ensure withdrawal recreated consumed inventory')
end

return M
