local M = {}
local log = require('scripts.mom.diagnostics.log')
local function copyPrevisitEntries(entries)
  local out = {}
  for i = 1, #(entries or {}) do
    local entry = entries[i]
    if entry and entry.packedCellKey then
      out[#out + 1] = {
        worldspaceKey = entry.worldspaceKey,
        gridX = entry.gridX,
        gridY = entry.gridY,
        packedCellKey = entry.packedCellKey,
      }
    end
  end
  return out
end
function M.acceptsParentTargetKind(behavior, targetKind)
  if not targetKind then return false end
  local accepted = behavior and behavior.acceptedParentTargetKinds
  if not accepted then return false end
  for i = 1, #accepted do
    if accepted[i] == targetKind then
      return true
    end
  end
  return false
end
function M.extractPrevisitEntries(spec, selectionFacts, actionId, lifecycle)
  if spec.previsit ~= true then
    return false, nil
  end
  if lifecycle ~= 'static' then
    log.warn('compile', 'Action %s requested previsit but is classified %s; previsit will be ignored',
      tostring(actionId), tostring(lifecycle))
    return false, nil
  end
  local previsitEntries = selectionFacts and selectionFacts.previsitEntries or nil
  if not (previsitEntries and #previsitEntries > 0) then
    log.warn('compile', 'Action %s requested previsit but does not resolve to exterior cells; previsit will be ignored',
      tostring(actionId))
    return false, nil
  end
  return true, copyPrevisitEntries(previsitEntries)
end
function M.normalizeExactIds(recordIdSpec)
  if not recordIdSpec then return nil end
  local out = {}
  if type(recordIdSpec) == 'string' then
    out[recordIdSpec:lower()] = true
  elseif type(recordIdSpec) == 'table' then
    for _, value in ipairs(recordIdSpec) do
      out[tostring(value):lower()] = true
    end
  end
  if next(out) then return out end
  return nil
end
return M
