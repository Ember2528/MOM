local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local SSS_STATIC_SOURCE_RECORD_ID = 'furn_de_signpost_04'
local SSS_STATIC_SOURCE_POSITION = {
  x = -22734.947,
  y = -13993.239,
  z = 766.431,
}
local SSS_IGNORED_STATIC_RECORD_ID = 'furn_de_signpost_02'
local SSS_IGNORED_STATIC_POSITION = {
  x = -22512.762,
  y = -13476.332,
  z = 645.224,
}
local DOR_STATIC_SOURCE_RECORD_ID = 'furn_de_tapestry_04'
local DOR_STATIC_TARGET_RECORD_ID = 'furn_de_tapestry_03'
local DOR_STATIC_POSITIONS = {
  { x = 1132.31, y = 1156.87, z = -150.124 },
  { x = 1388.21, y = 897.352, z = -150.124 },
}
local DOR_SPECIFIC_SOURCE_RECORD_ID = 'furn_de_rug_01'
local DOR_SPECIFIC_TARGET_RECORD_ID = 'furn_de_rug_02'
local DOR_EXCLUDED_TARGET_RECORD_ID = 'furn_de_rug_big_01'
local DOR_SPECIFIC_POSITION = {
  x = 1023.33,
  y = 902.391,
  z = -378.355,
}
local function enabledReplacementNear(cell, originalRecordId, position, tolerance)
  return H.countObjects(cell, function(obj)
    return obj.enabled ~= false
      and H.positionNear(obj.position, position, tolerance or 32)
      and H.objectRecordId(obj) ~= H.normalizeRecordId(originalRecordId)
  end)
end

local function runtimeDiagnostics(cell)
  local objects = {}
  H.eachCellObject(cell, function(obj)
    if H.positionNear(obj.position, SSS_STATIC_SOURCE_POSITION, 64) then
      local position = H.copyPosition(obj.position)
      objects[#objects + 1] = string.format('%s:%s:%s:(%.1f,%.1f,%.1f)',
        tostring(obj.id), tostring(obj.recordId), tostring(obj.enabled ~= false),
        position.x, position.y, position.z)
    end
  end)
  return H.runtimeStatusText() .. ' objects={' .. table.concat(objects, ',') .. '}'
end

return {
  id = 'compat_formats',
  description = 'SSS and DOR compatibility configs load and translate into observable Balmora replacements.',
  run = function()
    local gridX = C.BALMORA_EXTERIOR.gridX
    local gridY = C.BALMORA_EXTERIOR.gridY

    H.teleportExterior(gridX, gridY,
      H.exteriorCellCenter(gridX, gridY), 'Balmora exterior SSS compat setup')
    local exteriorCell = H.requireCurrentExterior(gridX, gridY)

    local sssApplied, sssError = pcall(function()
      H.waitUntil(function()
        return H.recordNearPositionDisabled(exteriorCell,
            SSS_STATIC_SOURCE_RECORD_ID,
            SSS_STATIC_SOURCE_POSITION, 32)
          and enabledReplacementNear(exteriorCell,
            SSS_STATIC_SOURCE_RECORD_ID,
            SSS_STATIC_SOURCE_POSITION, 32) > 0
      end, C.LONG_TIMEOUT_FRAMES, 'SSS compat replaced scriptless Static mesh')
    end)
    if not sssApplied then
      error(tostring(sssError) .. '; ' .. runtimeDiagnostics(exteriorCell))
    end

    H.expect(enabledReplacementNear(exteriorCell,
      SSS_IGNORED_STATIC_RECORD_ID,
      SSS_IGNORED_STATIC_POSITION, 32) == 0,
      'SSS ignore_records should skip ignored Static replacement')

    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates DOR compat setup')
    local eightPlates = H.requireCurrentInterior(C.EIGHT_PLATES)

    for i = 1, #DOR_STATIC_POSITIONS do
      local pos = DOR_STATIC_POSITIONS[i]
      H.waitUntil(function()
        return H.recordNearPositionDisabled(eightPlates,
            DOR_STATIC_SOURCE_RECORD_ID,
            pos, 32)
          and H.countRecordNearPosition(eightPlates,
            DOR_STATIC_TARGET_RECORD_ID,
            pos, 32) > 0
      end, C.LONG_TIMEOUT_FRAMES, 'DOR compat replaced Eight Plates static ' .. tostring(i))
    end

    H.waitUntil(function()
      return H.recordNearPositionDisabled(eightPlates,
          DOR_SPECIFIC_SOURCE_RECORD_ID,
          DOR_SPECIFIC_POSITION, 32)
        and H.countRecordNearPosition(eightPlates,
          DOR_SPECIFIC_TARGET_RECORD_ID,
          DOR_SPECIFIC_POSITION, 32) > 0
    end, C.LONG_TIMEOUT_FRAMES, 'DOR compat applied specific-cell managed candidate')

    H.expect(H.countRecordNearPosition(eightPlates,
      DOR_EXCLUDED_TARGET_RECORD_ID,
      DOR_SPECIFIC_POSITION, 32) == 0,
      'DOR excludedCell candidate should not apply inside Eight Plates')
  end,
}
