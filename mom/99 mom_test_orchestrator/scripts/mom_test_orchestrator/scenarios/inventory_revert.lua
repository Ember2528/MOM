local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local core = require('openmw.core')
local guard_provider = require('scripts.mom_test_orchestrator.guard_provider')

local CRATE_POSITION = {x = -65.124, y = 305.476, z = 37.0}
local GOLD_COUNT = 50
local TOGGLE = 'inventory_revert'

local function activate(value)
  assert(guard_provider.set(TOGGLE, value))
  core.sendGlobalEvent('MOM_GuardEvent', {
    event = 'external:harness:toggle_changed:' .. TOGGLE,
  })
end

return {
  id = 'inventory_revert',
  description = 'Guard-owned inventory adds exactly 50 gold and restores the resolved container baseline.',
  run = function()
    activate(false)
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates inventory revert baseline')
    local cell = H.requireCurrentInterior(C.EIGHT_PLATES)
    local crate = H.findRecordNearPosition(cell, 'crate_01_eggs', CRATE_POSITION, 32)
    H.expect(crate ~= nil, 'Egg crate not found in Eight Plates')

    -- Resolve leveled contents as external setup, as if the player had opened
    -- the crate. This fixture's guard cannot open until its own input is ready;
    -- another scenario's clock change must not start read-only capture early.
    local inventory = assert(H.containerInventory(crate), 'Egg crate inventory unavailable')
    if not inventory:isResolved() then inventory:resolve() end
    H.expect(inventory:isResolved(), 'Egg crate fixture did not resolve')
    local baselineGold = H.countContainerRecord(crate, C.REVERT_GOLD_ID)
    H.expect(baselineGold == 0, 'Egg crate baseline unexpectedly contains gold')

    activate(true)
    H.waitUntil(function()
      return H.countContainerRecord(crate, C.REVERT_GOLD_ID) == baselineGold + GOLD_COUNT
    end, C.LONG_TIMEOUT_FRAMES, 'egg crate contains exactly the added gold')

    activate(false)
    H.waitUntil(function()
      return H.countContainerRecord(crate, C.REVERT_GOLD_ID) == baselineGold
    end, C.LONG_TIMEOUT_FRAMES, 'egg crate restores its exact gold baseline')
  end,
}
