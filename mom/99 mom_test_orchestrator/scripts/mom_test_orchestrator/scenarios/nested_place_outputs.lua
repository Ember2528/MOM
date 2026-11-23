local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local RECORD = 'light_de_paper_lantern_off'
local EIGHT_POSITION = {x = 1340, y = 920, z = -311}
local GUILD_POSITION = {x = 500, y = 600, z = -100}

local function count(cell, position, requireScale)
  return H.countObjects(cell, function(obj)
    return H.objectRecordId(obj) == H.normalizeRecordId(RECORD)
      and H.positionNear(obj.position, position, 8)
      and (not requireScale or H.scaleNear(obj.scale, 1.2, 0.02))
  end)
end

return {
  id = 'nested_place_outputs',
  description = 'Each parent output creates child placements in both cells and grandchildren modify them.',
  run = function()
    local cell = H.teleportInteriorAtHour(23, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'nested placement baseline')
    H.waitUntil(function() return count(cell, EIGHT_POSITION) == 0 end,
      C.LONG_TIMEOUT_FRAMES, 'nested placements absent before guard')
    cell = H.advanceLoadedInteriorToHour(12, C.EIGHT_PLATES)
    H.waitUntil(function() return count(cell, EIGHT_POSITION, true) == 2 end,
      C.LONG_TIMEOUT_FRAMES, 'two modified child placements in Eight Plates')
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION, 'nested placement destination')
    cell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    H.waitUntil(function() return count(cell, GUILD_POSITION, true) == 2 end,
      C.LONG_TIMEOUT_FRAMES, 'two modified child placements in Guild of Mages')
    cell = H.advanceLoadedInteriorToHour(23, C.GUILD_OF_MAGES)
    H.waitUntil(function() return count(cell, GUILD_POSITION) == 0 end,
      C.LONG_TIMEOUT_FRAMES, 'nested guild placements removed')
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'nested placement cleanup')
    cell = H.requireCurrentInterior(C.EIGHT_PLATES)
    H.waitUntil(function() return count(cell, EIGHT_POSITION) == 0 end,
      C.LONG_TIMEOUT_FRAMES, 'nested Eight Plates placements removed')
  end,
}
