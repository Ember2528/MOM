local M = {}
local ref_position = require('scripts.mom.domain.ref.position')
local function clonePosition(position)
  if type(position) ~= 'table' then return nil end
  return {
    x = position.x,
    y = position.y,
    z = position.z,
  }
end
local function normalizedRecordId(recordId)
  if recordId == nil then return nil end
  local normalized = tostring(recordId):lower()
  return normalized ~= '' and normalized or nil
end
local function resolveType(recordCtx, recordId)
  if not (recordCtx and recordCtx.resolveLiveRefType) then return nil end
  local typeName = recordCtx.resolveLiveRefType(recordId)
  return type(typeName) == 'string' and typeName ~= '' and typeName or nil
end
local function buildEntry(entry, recordCtx)
  if type(entry) ~= 'table' then return nil end
  if entry.sourceKeyKind ~= 'record_id' then return nil end
  local recordId = normalizedRecordId(entry.sourceRecordId)
  if not recordId then return nil end
  local typeName = entry.inferredType or resolveType(recordCtx, recordId)
  if not typeName then return nil end
  local positionKey = ref_position.keyForPosition(entry.sourcePosition)
  if not positionKey then return nil end
  return {
    key = table.concat({ typeName, recordId, positionKey }, ':'),
    typeName = typeName,
    recordId = recordId,
    sourceKeyKind = 'record_id',
    sourcePosition = clonePosition(entry.sourcePosition),
    sourcePositionKey = positionKey,
    expandedFromModelPath = entry.sourceExpandedFromModelPath == true,
  }
end
function M.build(entries, opts)
  if type(entries) ~= 'table' or #entries == 0 then return nil end
  local recordCtx = opts and opts.recordCtx or nil
  local out = {}
  local seen = {}
  for i = 1, #entries do
    local direct = buildEntry(entries[i], recordCtx)
    if not direct then return nil end
    if not seen[direct.key] then
      seen[direct.key] = true
      out[#out + 1] = direct
    end
  end
  if #out == 0 then return nil end
  table.sort(out, function(left, right) return left.key < right.key end)
  return {
    expectedCount = #out,
    exactPositionCount = #out,
    entries = out,
  }
end
return M
