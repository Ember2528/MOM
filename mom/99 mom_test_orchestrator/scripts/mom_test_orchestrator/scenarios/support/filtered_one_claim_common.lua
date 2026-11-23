local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local M = {}
local slots = {
  {name = 'matching', record = 'furn_de_tapestry_02', x = 5220},
  {name = 'excluded', record = 'furn_de_tapestry_03', x = 5340},
}
function M.wait(cell, label)
  local function count(record, x)
    return H.countRecordNearPosition(cell, record, {x = x, y = 1850, z = -311}, 8)
  end
  H.waitUntil(function()
    return count(slots[1].record, slots[1].x) == 1 and count(slots[2].record, slots[2].x) == 1
  end, C.LONG_TIMEOUT_FRAMES, label)
  H.waitFrames(60)
  H.expect(count('furn_de_tapestry_03', 5240) == 0 and count('furn_de_tapestry_02', 5320) == 0,
    label .. ': wrong child won arbitration')
  local objects = {}
  for _, slot in ipairs(slots) do
    H.expect(count(slot.record, slot.x) == 1, label .. ': missing or duplicate ' .. slot.name)
    local obj = assert(H.findRecordNearPosition(cell, slot.record, {x = slot.x, y = 1850, z = -311}, 8))
    objects[slot.name] = tostring(obj.id)
  end
  return objects
end
return M
