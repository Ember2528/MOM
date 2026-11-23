local types = require('openmw.types')
local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local SOURCE = 'furn_de_tapestry_04'
local MODEL = 'meshes/f/furn_de_tapestry_02.nif'
local POSITIONS = {{x = 1940, y = 960, z = -311}, {x = 2040, y = 960, z = -311}}

local function generatedAt(cell, position)
  return H.countObjects(cell, function(obj)
    if not H.objectIsInstance(types.Static, obj) or obj.enabled == false
        or not H.positionNear(obj.position, position, 8)
        or H.objectRecordId(obj) == SOURCE then return false end
    local record = types.Static.record(obj)
    local model = tostring(record and record.model or ''):lower():gsub('\\', '/')
    if not model:match('^meshes/') then model = 'meshes/' .. model end
    return model == MODEL and H.scaleNear(obj.scale, 1.2, 0.02)
  end)
end

return {
  id = 'static_nested_attach_outputs',
  description = 'Static generated outputs anchor nested attachments and a source-filtered child.',
  run = function()
    local cell = H.teleportInteriorAtHour(12, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'static nested attachment')
    H.waitUntil(function()
      return generatedAt(cell, POSITIONS[1]) == 1
        and generatedAt(cell, POSITIONS[2]) == 1
    end, C.LONG_TIMEOUT_FRAMES, 'two static inherited mesh chains modified by descendants')
  end,
}
