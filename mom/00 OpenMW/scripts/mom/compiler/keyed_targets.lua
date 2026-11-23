-- Parses keyed target strings, including optional coordinate suffixes and
-- mesh-path detection. Resolves supported candidate type sets for selectors.
local M = {}
local model_path_contract = require('scripts.mom.contracts.model_path')
local isFinite = require('scripts.mom.common.numbers').isFinite
local function trim(value)
  if type(value) ~= 'string' then return value end
  return value:match('^%s*(.-)%s*$')
end
function M.isLikelyMeshPath(value)
  if type(value) ~= 'string' then return false end
  local lowered = value:lower()
  return lowered:find('/', 1, true) ~= nil
    or lowered:find('\\', 1, true) ~= nil
    or lowered:sub(-4) == '.nif'
    or lowered:sub(1, 7) == 'meshes/'
end
local function parsePositionSuffix(rawKey)
  local baseKey, coords = tostring(rawKey):match('^(.-),%s*%((.*)%)%s*$')
  if not baseKey then
    return trim(tostring(rawKey)), nil, nil
  end
  local xText, yText, zText = coords:match('^([^,]+),([^,]+),([^,]+)$')
  local x, y, z = tonumber(xText), tonumber(yText), tonumber(zText)
  if not isFinite(x) or not isFinite(y) or not isFinite(z) then
    return nil, nil, 'invalid keyed position suffix; expected `(x, y, z)`'
  end
  return trim(baseKey), {
    x = x,
    y = y,
    z = z,
  }, nil
end
function M.parseSelectorKey(rawKey, opts)
  opts = opts or {}
  local allowMeshPaths = opts.allowMeshPaths ~= false
  if type(rawKey) ~= 'string' or rawKey == '' then
    return nil, 'expected keyed object selector string'
  end
  local baseKey, sourcePosition, parseErr = parsePositionSuffix(rawKey)
  if parseErr then
    return nil, parseErr
  end
  if type(baseKey) ~= 'string' or baseKey == '' then
    return nil, 'expected keyed object selector before optional position suffix'
  end
  if M.isLikelyMeshPath(baseKey) then
    if not allowMeshPaths then
      return nil, 'mesh-path keyed selectors are not supported here'
    end
    local normalizedModel = model_path_contract.normalize(baseKey)
    if not normalizedModel then
      return nil, 'invalid mesh path'
    end
    return {
      sourceKeyKind = 'model_path',
      sourceValue = normalizedModel,
      sourcePosition = sourcePosition,
      rawKey = rawKey,
      rawBaseKey = baseKey,
    }, nil
  end
  return {
    sourceKeyKind = 'record_id',
    sourceValue = tostring(baseKey):lower(),
    sourcePosition = sourcePosition,
    rawKey = rawKey,
    rawBaseKey = baseKey,
  }, nil
end
local function singleCandidateType(typeName)
  return {
    [typeName] = true,
  }
end
local function filterTypes(typeSet, allowedTypes)
  if allowedTypes == nil then return typeSet end
  local out = {}
  for typeName in pairs(typeSet or {}) do
    if allowedTypes[typeName] == true then
      out[typeName] = true
    end
  end
  return next(out) and out or nil
end
function M.resolveSelectorTypes(parsed, opts)
  opts = opts or {}
  local recordCtx = assert(opts.recordCtx, 'resolveSelectorTypes requires recordCtx')
  local typeLabel = opts.typeLabel or 'supported record types'
  if parsed.sourceKeyKind == 'model_path' then
    local meshTypes, meshErr = recordCtx.resolveMeshTypes(parsed.sourceValue)
    if meshTypes == nil then
      return nil, (meshErr == 'unknown_mesh_path' and 'mesh path matches no supported record types')
        or tostring(meshErr)
    end
    local allowedTypes = filterTypes(meshTypes, opts.allowedMeshTypes or opts.allowedTypes)
    if allowedTypes then
      return allowedTypes, nil
    end
    return nil, 'mesh path does not match ' .. tostring(typeLabel)
  end
  local inferredType, inferErr = recordCtx.resolveLiveRefType(parsed.sourceValue)
  if inferredType == nil then
    if inferErr == 'invalid_record_id' then
      return nil, 'invalid record id'
    end
    if inferErr == 'not_live_ref_record' then
      return nil, 'record id is not selectable as a live ref'
    end
    return nil, tostring(inferErr)
  end
  if inferredType == false then
    return nil, 'ambiguous record type'
  end
  local allowedRecordTypes = opts.allowedRecordTypes or opts.allowedTypes
  if allowedRecordTypes ~= nil and allowedRecordTypes[inferredType] ~= true then
    return nil, 'record id does not resolve to ' .. tostring(typeLabel)
  end
  return singleCandidateType(inferredType), nil
end
return M
