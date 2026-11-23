local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local M = {}

function M.objectNear(cell, recordId, position, tolerance)
  return H.findRecordNearPosition(cell, recordId, position, tolerance or 32)
end

function M.objectEnabledNear(cell, recordId, position, tolerance)
  return H.countRecordNearPosition(cell, recordId, position, tolerance or 32) > 0
end

function M.objectDisabledNear(cell, recordId, position, tolerance)
  local obj = M.objectNear(cell, recordId, position, tolerance or 32)
  return obj ~= nil and obj.enabled == false
end

function M.objectDisabledByRefId(refId)
  local obj = H.getObjectByRefId(refId)
  return obj ~= nil and obj.enabled == false
end

function M.objectScaleNearByRefId(refId, expected, tolerance)
  local obj = H.getObjectByRefId(refId)
  return obj ~= nil and H.scaleNear(obj.scale, expected, tolerance or 0.02)
end

function M.fallbackTargetStateSummary(cell)
  local obj = M.objectNear(cell, C.BROAD_LOADED_CELL_RECORD_ID,
    C.BROAD_LOADED_CELL_POSITION, 32)
  if obj == nil then
    return 'missing'
  end
  return string.format('id=%s enabled=%s scale=%s',
    tostring(obj.id), tostring(obj.enabled), tostring(obj.scale))
end

return M
