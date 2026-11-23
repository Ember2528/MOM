local types = require('openmw.types')
local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local B = require('scripts.mom_test_orchestrator.scenarios.support.nested_attach_batch_common')

local SOURCE = 'furn_de_tapestry_04'
local MODEL = 'meshes/f/furn_de_tapestry_02.nif'
local POSITIONS = {{x = 1440, y = 960, z = -311}, {x = 1540, y = 960, z = -311}}

local function generatedAt(cell, position, scaled)
  return H.countObjects(cell, function(obj)
    if not H.objectIsInstance(types.Static, obj)
        or not H.positionNear(obj.position, position, 8)
        or H.objectRecordId(obj) == SOURCE then return false end
    local record = types.Static.record(obj)
    local model = tostring(record and record.model or ''):lower():gsub('\\', '/')
    if not model:match('^meshes/') then model = 'meshes/' .. model end
    return model == MODEL and (not scaled or H.scaleNear(obj.scale, 1.2, 0.02))
  end)
end

return {
  id = 'nested_attach_outputs',
  description = 'Generated mesh outputs anchor further attachments and source-filtered descendants.',
  run = function()
    local cell = H.teleportInteriorAtHour(23, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'nested attachment baseline')
    H.waitUntil(function()
      return generatedAt(cell, POSITIONS[1]) == 0 and generatedAt(cell, POSITIONS[2]) == 0
    end, C.LONG_TIMEOUT_FRAMES, 'nested attachments absent before guard')
    B.wait(cell, false, 'abbreviated batch absent before guard')
    cell = H.advanceLoadedInteriorToHour(12, C.EIGHT_PLATES)
    H.waitUntil(function()
      return generatedAt(cell, POSITIONS[1], true) == 1
        and generatedAt(cell, POSITIONS[2], true) == 1
    end, C.LONG_TIMEOUT_FRAMES, 'two inherited mesh chains modified by descendants')
    B.wait(cell, true, 'abbreviated batch matches, disables, and modifies expected outputs')
    cell = H.advanceLoadedInteriorToHour(23, C.EIGHT_PLATES)
    H.waitUntil(function()
      return generatedAt(cell, POSITIONS[1]) == 0 and generatedAt(cell, POSITIONS[2]) == 0
    end, C.LONG_TIMEOUT_FRAMES, 'nested attachments removed after guard')
    B.wait(cell, false, 'abbreviated batch removed after guard')
  end,
}
