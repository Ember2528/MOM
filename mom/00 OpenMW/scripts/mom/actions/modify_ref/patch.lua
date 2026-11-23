-- Normalizes and clones modify_ref patch payloads. Detached patch objects
-- prevent runtime mutation from changing authored or compiler tables.
local M = {}
local ownership = require('scripts.mom.domain.ref.ownership')
local function cloneVec3(v)
  if not v then return nil end
  return { x = v.x, y = v.y, z = v.z }
end
local function clonePosition(position)
  if not position then return nil end
  local out = cloneVec3(position)
  out.mode = position.mode
  return out
end
local cloneOwner = ownership.copy
local function cloneRotation(rotation)
  if not rotation then return nil end
  return {
    mode = rotation.mode,
    yaw = rotation.yaw,
    pitch = rotation.pitch,
    roll = rotation.roll,
  }
end
local function cloneScale(scale)
  if not scale then return nil end
  return {
    mode = scale.mode,
    value = scale.value,
  }
end
local function cloneCellSpec(cell)
  if not cell then return nil end
  return {
    key = cell.key,
    id = cell.id,
    isExterior = cell.isExterior == true,
    worldspaceKey = cell.worldspaceKey,
    gridX = cell.gridX,
    gridY = cell.gridY,
    packedCellKey = cell.packedCellKey,
    interiorKey = cell.interiorKey,
  }
end
local function cloneRelocate(relocate)
  if not relocate then return nil end
  return {
    cell = cloneCellSpec(relocate.cell),
    position = cloneVec3(relocate.position),
    rotation = relocate.rotation and {
      yaw = relocate.rotation.yaw,
      pitch = relocate.rotation.pitch,
      roll = relocate.rotation.roll,
    } or nil,
  }
end
local function copyPatchInto(dst, patch)
  if not patch then return dst end
  if patch.enabled ~= nil then dst.enabled = patch.enabled end
  if patch.owner ~= nil then dst.owner = cloneOwner(patch.owner) end
  if patch.position ~= nil then dst.position = clonePosition(patch.position) end
  if patch.rotation ~= nil then dst.rotation = cloneRotation(patch.rotation) end
  if patch.scale ~= nil then dst.scale = cloneScale(patch.scale) end
  if patch.relocate ~= nil then dst.relocate = cloneRelocate(patch.relocate) end
  return dst
end
local function copyPatch(patch)
  if not patch then return nil end
  local out = copyPatchInto({}, patch)
  return next(out) and out or nil
end
local function overlayPatch(dst, src)
  if not src then return dst end
  dst = copyPatch(dst) or {}
  copyPatchInto(dst, src)
  return next(dst) and dst or nil
end
local function normalizeOwnerId(value, path)
  if value == nil then return nil, nil end
  if type(value) ~= 'string' or value == '' then
    return nil, path .. ': expected non-empty string'
  end
  return tostring(value):lower(), nil
end
local function isInteger(value)
  return type(value) == 'number' and value == math.floor(value)
end
local function validateModeFields(value, path)
  for key in pairs(value) do
    if key ~= 'by' and key ~= 'to' then
      return nil, path .. '.' .. tostring(key) .. ': is not allowed'
    end
  end
  return true, nil
end
local function normalizeVector3(value, path)
  if type(value) ~= 'table' or #value ~= 3 then
    return nil, path .. ': expected [x, y, z] array'
  end
  for key in pairs(value) do
    if key ~= 1 and key ~= 2 and key ~= 3 then
      return nil, path .. ': expected [x, y, z] array'
    end
  end
  local x = tonumber(value[1])
  local y = tonumber(value[2])
  local z = tonumber(value[3])
  if x == nil or y == nil or z == nil then
    return nil, path .. ': expected numeric [x, y, z] array'
  end
  return { x = x, y = y, z = z }, nil
end
local function normalizeScale(value, path)
  if type(value) == 'number' then
    return { mode = 'set', value = value }, nil
  end
  if type(value) ~= 'table' then
    return nil, path .. ': expected number or object'
  end
  local valid, fieldError = validateModeFields(value, path)
  if not valid then return nil, fieldError end
  local modeCount = 0
  local normalized = nil
  if value.by ~= nil then
    local by = tonumber(value.by)
    if by == nil then return nil, path .. '.by: expected number' end
    normalized = { mode = 'scaleBy', value = by }
    modeCount = modeCount + 1
  end
  if value.to ~= nil then
    local to = tonumber(value.to)
    if to == nil then return nil, path .. '.to: expected number' end
    normalized = { mode = 'set', value = to }
    modeCount = modeCount + 1
  end
  if modeCount == 0 then
    return nil, path .. ': expected .by or .to'
  end
  if modeCount > 1 then
    return nil, path .. ': by and to cannot be combined'
  end
  return normalized, nil
end
local function normalizePosition(value, path)
  if type(value) == 'table' and value[1] ~= nil then
    local vector, vectorErr = normalizeVector3(value, path)
    if not vector then return nil, vectorErr end
    return {
      mode = 'set',
      x = vector.x,
      y = vector.y,
      z = vector.z,
    }, nil
  end
  if type(value) ~= 'table' then
    return nil, path .. ': expected [x, y, z] array or object'
  end
  local valid, fieldError = validateModeFields(value, path)
  if not valid then return nil, fieldError end
  local modeCount = 0
  local normalized = nil
  if value.by ~= nil then
    local vector, vectorErr = normalizeVector3(value.by, path .. '.by')
    if not vector then return nil, vectorErr end
    normalized = {
      mode = 'move',
      x = vector.x,
      y = vector.y,
      z = vector.z,
    }
    modeCount = modeCount + 1
  end
  if value.to ~= nil then
    local vector, vectorErr = normalizeVector3(value.to, path .. '.to')
    if not vector then return nil, vectorErr end
    normalized = {
      mode = 'set',
      x = vector.x,
      y = vector.y,
      z = vector.z,
    }
    modeCount = modeCount + 1
  end
  if modeCount == 0 then
    return nil, path .. ': expected .by or .to'
  end
  if modeCount > 1 then
    return nil, path .. ': by and to cannot be combined'
  end
  return normalized, nil
end
local function normalizeAngles(rawAngles, anglesPath)
  if type(rawAngles) ~= 'table' then
    return nil, anglesPath .. ': expected object'
  end
  local normalized = {}
  local hasAny = false
  for key, raw in pairs(rawAngles) do
    if key ~= 'yaw' and key ~= 'pitch' and key ~= 'roll' then
      return nil, anglesPath .. '.' .. tostring(key) .. ': is not allowed'
    end
    local num = tonumber(raw)
    if num == nil then
      return nil, anglesPath .. '.' .. tostring(key) .. ': expected number'
    end
    normalized[key] = num
    hasAny = true
  end
  if not hasAny then
    return nil, anglesPath .. ': expected at least one angle'
  end
  return normalized, nil
end
local function normalizeRotation(value, path)
  if type(value) ~= 'table' then
    return nil, path .. ': expected object'
  end
  local hasDirectAngles = value.yaw ~= nil or value.pitch ~= nil or value.roll ~= nil
  local hasBy = value.by ~= nil
  local hasTo = value.to ~= nil
  if hasDirectAngles then
    if hasBy or hasTo then
      return nil, path .. ': direct angles cannot be combined with by/to'
    end
    local angles, angleErr = normalizeAngles(value, path)
    if angleErr then return nil, angleErr end
    return { mode = 'set', yaw = angles.yaw, pitch = angles.pitch, roll = angles.roll }, nil
  end
  local valid, fieldError = validateModeFields(value, path)
  if not valid then return nil, fieldError end
  local modeCount = (hasBy and 1 or 0) + (hasTo and 1 or 0)
  if modeCount == 0 then
    return nil, path .. ': expected direct angles or .by/.to object'
  end
  if modeCount > 1 then
    return nil, path .. ': by and to cannot be combined'
  end
  local mode = hasBy and 'rotate' or 'set'
  local key = hasBy and 'by' or 'to'
  local angles, angleErr = normalizeAngles(value[key], path .. '.' .. key)
  if angleErr then return nil, angleErr end
  return { mode = mode, yaw = angles.yaw, pitch = angles.pitch, roll = angles.roll }, nil
end
local function normalizeOwner(value, path)
  if type(value) ~= 'table' then
    return nil, path .. ': expected object'
  end
  for key in pairs(value) do
    if key ~= 'clear' and key ~= 'recordId' and key ~= 'factionId' and key ~= 'factionRank' then
      return nil, path .. '.' .. tostring(key) .. ': is not allowed'
    end
  end
  if value.clear ~= nil and type(value.clear) ~= 'boolean' then
    return nil, path .. '.clear: expected boolean'
  end
  if value.clear == true then
    if value.recordId ~= nil or value.factionId ~= nil or value.factionRank ~= nil then
      return nil, path .. ': clear cannot be combined with ownership fields'
    end
    return { clear = true }, nil
  end
  local recordId, recordIdErr = normalizeOwnerId(value.recordId, path .. '.recordId')
  if recordIdErr then return nil, recordIdErr end
  local factionId, factionIdErr = normalizeOwnerId(value.factionId, path .. '.factionId')
  if factionIdErr then return nil, factionIdErr end
  local factionRank = value.factionRank
  if factionRank ~= nil and not isInteger(factionRank) then
    return nil, path .. '.factionRank: expected non-negative integer'
  end
  if factionRank ~= nil and factionRank < 0 then
    return nil, path .. '.factionRank: expected non-negative integer'
  end
  if factionRank ~= nil and factionId == nil then
    return nil, path .. '.factionRank: requires factionId'
  end
  if recordId == nil and factionId == nil and factionRank == nil then
    return nil, nil
  end
  return {
    recordId = recordId,
    factionId = factionId,
    factionRank = factionRank,
  }, nil
end
local function normalizeRelocate(value, path)
  if type(value) ~= 'table' then
    return nil, path .. ': expected object'
  end
  for key in pairs(value) do
    if key ~= 'cell' and key ~= 'position' and key ~= 'rotation' then
      return nil, path .. '.' .. tostring(key) .. ': is not allowed'
    end
  end
  if value.cell == nil then
    return nil, path .. '.cell: required'
  end
  if value.position == nil then
    return nil, path .. '.position: required'
  end
  local position, positionErr = normalizePosition(value.position, path .. '.position')
  if positionErr then return nil, positionErr end
  if position.mode ~= 'set' then
    return nil, path .. '.position: cross-cell relocation requires an absolute destination'
  end
  local rotation = nil
  if value.rotation ~= nil then
    rotation, positionErr = normalizeRotation(value.rotation, path .. '.rotation')
    if positionErr then return nil, positionErr end
    if rotation.mode ~= 'set' then
      return nil, path .. '.rotation: cross-cell relocation requires an absolute destination rotation'
    end
    rotation = {
      yaw = rotation.yaw,
      pitch = rotation.pitch,
      roll = rotation.roll,
    }
  end
  return {
    cell = value.cell,
    position = {
      x = position.x,
      y = position.y,
      z = position.z,
    },
    rotation = rotation,
  }, nil
end
function M.normalizePatch(rawPatch, path, allowRelocate)
  if type(rawPatch) ~= 'table' then
    return nil, path .. ': expected object'
  end
  local allowed = {
    enabled = true,
    owner = true,
    position = true,
    rotation = true,
    scale = true,
  }
  if allowRelocate then allowed.relocate = true end
  for key in pairs(rawPatch) do
    if not allowed[key] then
      return nil, path .. '.' .. tostring(key) .. ': is not allowed'
    end
  end
  local patch = {}
  if rawPatch.enabled ~= nil then
    if type(rawPatch.enabled) ~= 'boolean' then
      return nil, path .. '.enabled: expected boolean'
    end
    patch.enabled = rawPatch.enabled
  end
  if rawPatch.owner ~= nil then
    local owner, ownerErr = normalizeOwner(rawPatch.owner, path .. '.owner')
    if ownerErr then return nil, ownerErr end
    if owner ~= nil then patch.owner = owner end
  end
  if rawPatch.position ~= nil then
    local position, positionErr = normalizePosition(rawPatch.position, path .. '.position')
    if positionErr then return nil, positionErr end
    if position ~= nil then patch.position = position end
  end
  if rawPatch.rotation ~= nil then
    local rotation, rotationErr = normalizeRotation(rawPatch.rotation, path .. '.rotation')
    if rotationErr then return nil, rotationErr end
    if rotation ~= nil then
      patch.rotation = rotation
    end
  end
  if rawPatch.scale ~= nil then
    local scale, scaleErr = normalizeScale(rawPatch.scale, path .. '.scale')
    if scaleErr then return nil, scaleErr end
    if scale ~= nil then
      patch.scale = scale
    end
  end
  if allowRelocate and rawPatch.relocate ~= nil then
    local relocate, relocateErr = normalizeRelocate(rawPatch.relocate, path .. '.relocate')
    if relocateErr then return nil, relocateErr end
    if relocate ~= nil then patch.relocate = relocate end
  end
  return patch, nil
end
M.copyPatchInto = copyPatchInto
M.copyPatch = copyPatch
M.overlayPatch = overlayPatch
return M
