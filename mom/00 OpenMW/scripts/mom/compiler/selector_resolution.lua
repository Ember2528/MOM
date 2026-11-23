local M = {}
local tables = require('scripts.mom.common.tables')
local copyArray = tables.copyArray
local sortedTypeNames = tables.sortedKeys
local function copyEntry(entry)
  local out = {}
  for key, value in pairs(entry or {}) do
    if key == 'filters' and type(value) == 'table' then
      out[key] = copyArray(value)
    elseif key ~= 'typeName' and key ~= 'inferredType' then
      out[key] = value
    end
  end
  return out
end
local function appendResolvedRecord(out, candidateTypes, entry, typeName, recordId, opts)
  local resolved = copyEntry(entry)
  resolved.sourceKeyKind = 'record_id'
  resolved.sourceRecordId = recordId
  -- `resolveEntries` is the boundary at which an authored record/model
  -- selector becomes one exact record-type identity. Keep that fact on the
  -- family entry: keyed action programs build their immutable target-match
  -- index from these rows and must not repeat or guess record resolution.
  resolved.inferredType = typeName
  if opts and opts.fromModelPath == true then
    resolved.sourceExpandedFromModelPath = true
  end
  out[#out + 1] = resolved
  candidateTypes[typeName] = true
end
local function resolveRecordEntry(out, candidateTypes, entry, recordCtx, path)
  local recordId = entry and entry.sourceRecordId and tostring(entry.sourceRecordId):lower() or nil
  if not recordId or recordId == '' then
    return nil, { tostring(path or 'target') .. ': missing record id' }
  end
  local typeName = entry.inferredType or entry.typeName
  if not typeName then
    local resolvedType, err = recordCtx.resolveLiveRefType(recordId)
    if not resolvedType then
      return nil, { tostring(path or 'target') .. ': ' .. tostring(err or 'invalid record id') }
    end
    typeName = resolvedType
  end
  appendResolvedRecord(out, candidateTypes, entry, typeName, recordId)
  return true, nil
end
local function appendResolvedModelRecordsForType(out, candidateTypes, entry, byType, recordType)
  local count = 0
  local records = byType and byType[recordType] or nil
  for i = 1, #(records or {}) do
    count = count + 1
    appendResolvedRecord(out, candidateTypes, entry, recordType, records[i],
      { fromModelPath = true })
  end
  return count
end
local function appendResolvedModelRecords(out, candidateTypes, entry, recordCtx, byType, typeName)
  local count = 0
  if typeName then
    return appendResolvedModelRecordsForType(out, candidateTypes, entry, byType, typeName)
  end
  local typeOrder = recordCtx and recordCtx.modelRecordTypeOrder or nil
  if typeOrder then
    for i = 1, #typeOrder do
      count = count + appendResolvedModelRecordsForType(
        out,
        candidateTypes,
        entry,
        byType,
        typeOrder[i]
      )
    end
  else
    local types = sortedTypeNames(byType)
    for i = 1, #types do
      count = count + appendResolvedModelRecordsForType(
        out,
        candidateTypes,
        entry,
        byType,
        types[i]
      )
    end
  end
  return count
end
local function resolveModelEntry(out, candidateTypes, entry, recordCtx, path)
  local modelKey = entry and entry.sourceRecordId or nil
  if not modelKey then
    return nil, { tostring(path or 'target') .. ': missing model path' }
  end
  if not (recordCtx and recordCtx.resolveMeshTypes) then
    return nil, { tostring(path or 'target') .. ': mesh path resolution is unavailable' }
  end
  local byType = recordCtx.resolveMeshTypes(modelKey)
  local count = appendResolvedModelRecords(
    out,
    candidateTypes,
    entry,
    recordCtx,
    byType,
    entry.inferredType or entry.typeName
  )
  if count == 0 then
    return nil, { tostring(path or 'target') .. ': mesh path matches no supported record ids' }
  end
  return true, nil
end
---@return 'ok'|'error' status
---@return table[]|nil entries
---@return string[]|nil errors
---@return table|nil candidateTypes
function M.resolveEntries(entries, opts)
  if type(entries) ~= 'table' then return 'error', nil, { 'target entries must be a table' } end
  local recordCtx = assert(opts and opts.recordCtx, 'selector_resolution.resolveEntries requires recordCtx')
  local pathPrefix = opts.pathPrefix or 'target'
  local out = {}
  local candidateTypes = {}
  for i = 1, #entries do
    local entry = entries[i]
    local path = pathPrefix .. '[' .. tostring(i) .. ']'
    local ok, errors
    if entry and entry.sourceKeyKind == 'model_path' then
      ok, errors = resolveModelEntry(out, candidateTypes, entry, recordCtx, path)
    else
      ok, errors = resolveRecordEntry(out, candidateTypes, entry, recordCtx, path)
    end
    if not ok then return 'error', nil, errors end
  end
  if #out == 0 then return 'error', nil, { pathPrefix .. ': no resolved targets' } end
  return 'ok', out, nil, candidateTypes
end
return M
