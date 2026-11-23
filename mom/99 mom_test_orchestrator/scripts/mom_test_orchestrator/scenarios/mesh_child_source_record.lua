local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local types = require('openmw.types')
local model_path = require('scripts.mom.contracts.model_path')

local SOURCE = 'furn_de_tapestry_04'
local SCALE = 1.37
local SOURCE_POSITION = {x = 2500, y = 960, z = -311}
local OUTPUT_POSITION = {x = 2520, y = 960, z = -311}

return {
  id = 'mesh_child_source_record',
  description = 'A source-record child selector modifies a generated mesh output and cleans it up.',
  run = function()
    local cell = H.teleportInteriorAtHour(23.0, C.EIGHT_PLATES,
      C.EIGHT_PLATES_SAFE_POSITION, 'Mesh child source-record baseline')
    local function matchingGenerated()
      return H.findFirstObject(cell, function(object)
        if object.enabled == false or H.objectRecordId(object) == SOURCE
            or not H.scaleNear(object.scale, SCALE, 0.02) then return false end
        local ok, record = pcall(types.Static.record, object)
        if not ok or record == nil
            or model_path.normalize(record.model) ~= 'meshes/f/furn_de_tapestry_03.nif' then
          return false
        end
        return H.positionNear(object.position, OUTPUT_POSITION, 2)
      end)
    end
    H.expect(matchingGenerated() == nil, 'Mesh child fixture was already present at baseline')
    H.expect(H.countObjects(cell, function(object)
      return H.objectRecordId(object) == SOURCE and object.enabled ~= false
        and H.positionNear(object.position, SOURCE_POSITION, 2)
    end) == 0, 'Mesh parent fixture was already present at baseline')
    cell = H.advanceLoadedInteriorToHour(12.0, C.EIGHT_PLATES)
    local generated
    H.waitUntil(function() generated = matchingGenerated(); return generated ~= nil end,
      C.LONG_TIMEOUT_FRAMES, 'Generated mesh output received inherited child scale')
    local generatedId = tostring(generated.id)
    cell = H.advanceLoadedInteriorToHour(23.0, C.EIGHT_PLATES)
    H.waitUntil(function()
      return H.findFirstObject(cell, function(object)
        return tostring(object.id) == generatedId and object.enabled ~= false
      end) == nil
    end,
      C.LONG_TIMEOUT_FRAMES, 'Generated mesh output cleaned up after guard closes')
    H.waitUntil(function()
      return H.countObjects(cell, function(object)
        return H.objectRecordId(object) == SOURCE and object.enabled ~= false
          and H.positionNear(object.position, SOURCE_POSITION, 2)
      end) == 0
    end, C.LONG_TIMEOUT_FRAMES, 'Mesh parent source output cleaned up')
  end,
}
