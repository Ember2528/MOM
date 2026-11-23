local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local M = {}
M.EIGHT = {x = 1340, y = 920, z = -311}
M.GUILD = {x = 500, y = 600, z = -100}
local RECORD = 'light_de_paper_lantern_off'

function M.ids(cell, position)
  local ids, scaled = {}, 0
  H.eachCellObject(cell, function(obj)
    if H.objectRecordId(obj) == H.normalizeRecordId(RECORD)
        and H.positionNear(obj.position, position, 8) then
      ids[#ids + 1] = tostring(obj.id)
      if obj.enabled ~= false and H.scaleNear(obj.scale, 1.2, 0.02) then
        scaled = scaled + 1
      end
    end
  end)
  table.sort(ids)
  return ids, scaled
end

function M.waitPair(cell, position, label)
  H.waitUntil(function()
    local ids, scaled = M.ids(cell, position)
    return #ids == 2 and scaled == 2
  end, C.LONG_TIMEOUT_FRAMES, label)
  H.waitFrames(30)
  local ids, scaled = M.ids(cell, position)
  H.expect(#ids == 2 and scaled == 2 and ids[1] ~= ids[2],
    label .. ': expected exactly two distinct, scaled outputs')
  return ids
end

function M.waitAbsent(cell, position, label)
  H.waitUntil(function()
    local ids = M.ids(cell, position)
    return #ids == 0
  end, C.LONG_TIMEOUT_FRAMES, label)
end

function M.expectSame(actual, first, second, label)
  H.expect(actual[1] == first and actual[2] == second,
    label .. ': output object identities changed across restart')
end

return M
