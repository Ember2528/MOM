local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local R = require('scripts.mom_test_orchestrator.scenarios.support.runtime_contract_helpers')

return {
  id = 'runtime_broad_loaded_cell_scope',
  description = 'Runtime-broad state remains scoped while known exterior targets recover across adjacent cells.',
  run = function()
    H.advanceToHour(2.0)
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
    H.teleportExterior(C.BALMORA_EXTERIOR.gridX, C.BALMORA_EXTERIOR.gridY,
      H.exteriorCellCenter(C.BALMORA_EXTERIOR.gridX, C.BALMORA_EXTERIOR.gridY),
      'Balmora exterior runtime-broad baseline')
    local exteriorCell = H.requireCurrentExterior(C.BALMORA_EXTERIOR.gridX, C.BALMORA_EXTERIOR.gridY)
    local bannerObj = nil
    H.waitUntil(function()
      bannerObj = R.objectNear(exteriorCell,
        C.BROAD_LOADED_CELL_RECORD_ID, C.BROAD_LOADED_CELL_POSITION, 32)
      return bannerObj ~= nil and bannerObj.enabled ~= false
        and H.scaleNear(bannerObj.scale, 1.0, 0.02)
    end, C.EXTERIOR_REVERT_TIMEOUT_FRAMES, 'runtime-broad target enabled outside guard',
      C.EXTERIOR_REVERT_TIMEOUT_SECONDS)
    local bannerRefId = tostring(bannerObj.id)

    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION,
      'move away before runtime-broad loaded-cell modify')
    H.advanceToHour(12.0)

    H.teleportExterior(C.BALMORA_EXTERIOR.gridX, C.BALMORA_EXTERIOR.gridY + 1,
      H.exteriorCellCenter(C.BALMORA_EXTERIOR.gridX, C.BALMORA_EXTERIOR.gridY + 1),
      'Balmora adjacent exterior recovery check')
    H.requireCurrentExterior(C.BALMORA_EXTERIOR.gridX, C.BALMORA_EXTERIOR.gridY + 1)
    H.waitUntil(function()
      return R.objectDisabledByRefId(bannerRefId)
        and R.objectScaleNearByRefId(bannerRefId, 0.85, 0.02)
    end, C.EXTERIOR_REVERT_TIMEOUT_FRAMES, 'known runtime-broad target disabled from adjacent exterior',
      C.EXTERIOR_REVERT_TIMEOUT_SECONDS)

    H.teleportExterior(C.BALMORA_EXTERIOR.gridX, C.BALMORA_EXTERIOR.gridY,
      H.exteriorCellCenter(C.BALMORA_EXTERIOR.gridX, C.BALMORA_EXTERIOR.gridY),
      'Balmora exterior runtime-broad loaded-cell modify check')
    exteriorCell = H.requireCurrentExterior(C.BALMORA_EXTERIOR.gridX, C.BALMORA_EXTERIOR.gridY)
    H.waitUntil(function()
      local obj = R.objectNear(exteriorCell,
        C.BROAD_LOADED_CELL_RECORD_ID, C.BROAD_LOADED_CELL_POSITION, 32)
      return obj ~= nil and obj.enabled == false and H.scaleNear(obj.scale, 0.85, 0.02)
    end, C.EXTERIOR_REVERT_TIMEOUT_FRAMES, 'runtime-broad loaded-cell modify disabled target',
      C.EXTERIOR_REVERT_TIMEOUT_SECONDS)

    H.advanceToHour(2.0)
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
    local restored, restoreError = pcall(H.waitUntil, function()
      local obj = R.objectNear(exteriorCell,
        C.BROAD_LOADED_CELL_RECORD_ID, C.BROAD_LOADED_CELL_POSITION, 32)
      return obj ~= nil and obj.enabled ~= false and H.scaleNear(obj.scale, 1.0, 0.02)
    end, C.EXTERIOR_REVERT_TIMEOUT_FRAMES, 'runtime-broad loaded-cell modify restored target',
      C.EXTERIOR_REVERT_TIMEOUT_SECONDS)
    if not restored then
      error(tostring(restoreError) .. '; state='
        .. R.fallbackTargetStateSummary(exteriorCell))
    end
  end,
}
