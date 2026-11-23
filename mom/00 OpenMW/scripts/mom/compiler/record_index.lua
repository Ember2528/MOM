local M = {}
local model_path = require('scripts.mom.contracts.model_path')
local ref_type = require('scripts.mom.contracts.ref_type')
local ref_selector = require('scripts.mom.contracts.ref_selector')
local canonical = require('scripts.mom.contracts.canonical')
local openmw_types = require('openmw.types')
local openmw_core_ok, openmw_core = pcall(require, 'openmw.core')
local LIVE_REF_TYPE_ORDER = ref_type.names()
local function appendRecordStore(out, byType, typeName, records)
  if type(typeName) ~= 'string' or records == nil or byType[typeName] ~= nil then return end
  out[#out + 1] = records
  byType[typeName] = records
end
local function coreFactionRecords()
  if not openmw_core_ok or not openmw_core then return nil end
  local ok, factions = pcall(function() return openmw_core.factions end)
  if not ok or not factions then return nil end
  return factions.records
end
local function buildRecordStores()
  local out = {}
  local byType = {}
  for typeName, api in pairs(openmw_types) do
    local records = type(typeName) == 'string' and api and api.records or nil
    appendRecordStore(out, byType, typeName, records)
  end
  appendRecordStore(out, byType, 'Faction', coreFactionRecords())
  return out, byType
end
local RECORD_STORES, RECORD_STORES_BY_TYPE = buildRecordStores()
local function ensureMeshTypeBucket(meshMap, meshPath, typeName)
  local byType = meshMap[meshPath]
  if not byType then
    byType = {}
    meshMap[meshPath] = byType
  end
  local bucket = byType[typeName]
  if bucket then return bucket end
  bucket = {}
  byType[typeName] = bucket
  return bucket
end
local function buildContext()
  return {
    recordPresence = {},
    liveRefTypes = {},
    meshMatches = {},
    modelRecordTypeOrder = LIVE_REF_TYPE_ORDER,
  }
end
local function modelBasename(path)
  if path == nil then return nil end
  local str = tostring(path):lower()
  return str:match('[^/\\]+$') or str
end
local function ensureSet(root, key)
  local set = root[key]
  if set then return set end
  set = {}
  root[key] = set
  return set
end
local function mergeMeshTypeSet(existing, incoming)
  if existing == true or incoming == true or incoming == nil then
    return true
  end
  if type(incoming) ~= 'table' then
    return existing
  end
  local merged = type(existing) == 'table' and existing or {}
  for typeName in pairs(incoming) do
    merged[typeName] = true
  end
  return merged
end
function M.contentFileActive(filename)
  local files = openmw_core_ok and openmw_core and openmw_core.contentFiles
  local list = files and files.list
  if list == nil then return nil end
  for _, name in ipairs(list) do
    if tostring(name):lower() == filename then return true end
  end
  return false
end
function M.build(queries)
  local ctx = buildContext()
  queries = queries or {}
  local wantedIds = queries.recordIds or {}
  local wantedMeshTypes = queries.meshPathTypes or {}
  local wantedMeshBasenames = nil
  local wantedMeshBasenamesByType = nil
  local wantedMeshesByNormalizedPath = nil
  local wantedMeshTypesByNormalizedPath = nil
  local needIds = next(wantedIds) ~= nil
  local needMeshes = next(wantedMeshTypes) ~= nil
  if needMeshes then
    wantedMeshBasenames = {}
    wantedMeshBasenamesByType = {}
    wantedMeshesByNormalizedPath = {}
    wantedMeshTypesByNormalizedPath = {}
    for meshPath, requestedTypes in pairs(wantedMeshTypes) do
      local normalized = model_path.normalize(meshPath) or tostring(meshPath):lower()
      local basename = modelBasename(normalized)
      local typeSet = mergeMeshTypeSet(
        wantedMeshTypesByNormalizedPath[normalized],
        requestedTypes
      )
      if normalized then
        wantedMeshesByNormalizedPath[normalized] = true
        wantedMeshTypesByNormalizedPath[normalized] = typeSet
      end
      if basename and (typeSet == nil or typeSet == true) then
        wantedMeshBasenames[basename] = true
      elseif basename then
        for typeName in pairs(typeSet) do
          ensureSet(wantedMeshBasenamesByType, typeName)[basename] = true
        end
      end
    end
  end
  local function recordsForType(typeName)
    local api = openmw_types[typeName]
    local records = api and api.records or nil
    assert(records, 'record index missing records store for type ' .. tostring(typeName))
    return records
  end
  local function markLiveRefType(recordId, typeName)
    local existing = ctx.liveRefTypes[recordId]
    if existing == nil then
      ctx.liveRefTypes[recordId] = typeName
    elseif existing ~= typeName then
      ctx.liveRefTypes[recordId] = false
    end
  end
  local function recordStoreContains(recordId)
    for i = 1, #RECORD_STORES do
      if RECORD_STORES[i][recordId] ~= nil then
        return true
      end
    end
    return false
  end
  local function recordStoreContainsType(recordId, typeSet)
    for typeName in pairs(typeSet or {}) do
      local records = RECORD_STORES_BY_TYPE[typeName]
      if records and records[recordId] ~= nil then
        return true, typeName
      end
    end
    return false, nil
  end
  local function resolveRecordIds()
    for recordId in pairs(wantedIds) do
      local lowered = tostring(recordId):lower()
      local foundLiveRef = false
      for i = 1, #LIVE_REF_TYPE_ORDER do
        local typeName = LIVE_REF_TYPE_ORDER[i]
        local records = recordsForType(typeName)
        if records[lowered] ~= nil then
          foundLiveRef = true
          markLiveRefType(lowered, typeName)
        end
      end
      ctx.recordPresence[lowered] = foundLiveRef or recordStoreContains(lowered)
    end
  end
  local function scanTypeModels(typeName)
    local records = recordsForType(typeName)
    local count = #records
    if count <= 0 then return end
    local typedBasenames = wantedMeshBasenamesByType and wantedMeshBasenamesByType[typeName] or nil
    for i = 1, count do
      local record = records[i]
      if record then
        local recordId = record.id and tostring(record.id):lower() or nil
        local modelValue = record.model
        local basename = modelBasename(modelValue)
        local basenameWanted = basename and (
          wantedMeshBasenames[basename] or typedBasenames and typedBasenames[basename])
        local normalizedModel = basenameWanted
          and model_path.normalize(modelValue) or nil
        local typeSet = normalizedModel and wantedMeshTypesByNormalizedPath[normalizedModel] or nil
        local typeMatches = typeSet == nil or typeSet == true or typeSet[typeName] == true
        if normalizedModel and wantedMeshesByNormalizedPath[normalizedModel] and typeMatches and recordId then
          markLiveRefType(recordId, typeName)
          ctx.recordPresence[recordId] = true
          local bucket = ensureMeshTypeBucket(ctx.meshMatches, normalizedModel, typeName)
          bucket[#bucket + 1] = recordId
        end
      end
    end
  end
  if needIds then
    resolveRecordIds()
  end
  if needMeshes then
    local scanAllTypes = next(wantedMeshBasenames) ~= nil
    local wantedTypes = {}
    for typeName in pairs(wantedMeshBasenamesByType) do
      wantedTypes[typeName] = true
    end
    for i = 1, #LIVE_REF_TYPE_ORDER do
      local typeName = LIVE_REF_TYPE_ORDER[i]
      if scanAllTypes or wantedTypes[typeName] == true then
        scanTypeModels(typeName)
      end
    end
  end
  function ctx.recordExists(recordId, typeSet)
    local lowered = recordId and tostring(recordId):lower() or nil
    if not lowered then return nil, 'missing_record_id' end
    if typeSet ~= nil then
      local typedExists, typeName = recordStoreContainsType(lowered, typeSet)
      if typedExists then return true, nil, typeName end
      local broadExists = ctx.recordPresence[lowered]
      if broadExists == nil then
        broadExists = recordStoreContains(lowered)
        ctx.recordPresence[lowered] = broadExists
      end
      if broadExists == true then
        return false, 'wrong_record_type'
      end
      return false, 'invalid_record_id'
    end
    local exists = ctx.recordPresence[lowered]
    if exists == nil then
      exists = recordStoreContains(lowered)
      ctx.recordPresence[lowered] = exists
    end
    return exists == true, exists == true and nil or 'invalid_record_id'
  end
  function ctx.resolveLiveRefType(recordId)
    local lowered = recordId and tostring(recordId):lower() or nil
    if not lowered then return nil, 'missing_record_id' end
    local resolved = ctx.liveRefTypes[lowered]
    if resolved == false then
      return false, 'ambiguous_record_type'
    end
    if resolved == nil then
      if ctx.recordExists(lowered) then
        return nil, 'not_live_ref_record'
      end
      return nil, 'invalid_record_id'
    end
    return resolved, nil
  end
  local queryCache = {}
  function ctx.resolveRecordQuery(query)
    local key = canonical.assertHash(query)
    if queryCache[key] then return queryCache[key] end
    local out, allowedTypes = {}, nil
    if query.type ~= nil then
      allowedTypes = {}
      for _, typeName in ipairs(query.type) do allowedTypes[typeName] = true end
    end
    local function consider(record, typeName)
      local rawId = record and record.id or nil
      local id = rawId ~= nil and tostring(rawId):lower() or nil
      if id and ref_selector.matchesRecord(query, id, typeName,
          query.mwscript ~= nil and record.mwscript or nil) then
        out[#out + 1] = {typeName = typeName, recordId = id}
      end
    end
    if query.none ~= true then
      for _, typeName in ipairs(LIVE_REF_TYPE_ORDER) do
        if allowedTypes == nil or allowedTypes[typeName] then
          local records = recordsForType(typeName)
          if query.recordId ~= nil then
            local seen = {}
            for _, recordId in ipairs(query.recordId) do
              local id = tostring(recordId):lower()
              if not seen[id] then
                seen[id] = true
                consider(records[id], typeName)
              end
            end
          else
            for i = 1, #records do consider(records[i], typeName) end
          end
        end
      end
    end
    table.sort(out, function(a, b)
      if a.typeName ~= b.typeName then return a.typeName < b.typeName end
      return a.recordId < b.recordId
    end)
    queryCache[key] = out
    return out
  end
  function ctx.resolveMeshTypes(meshPath)
    local normalized = model_path.normalize(meshPath)
    if not normalized then return nil, 'missing_mesh_path' end
    local byType = ctx.meshMatches[normalized]
    if byType == nil then
      return nil, 'unknown_mesh_path'
    end
    return byType, nil
  end
  return ctx
end
return M
