-- Canonical scalar identity helpers for interior/exterior cells, regions, and
-- worldspaces. These shapes are used as stable keys across compiler/runtime code.
local M = {}
local isInteger = require('scripts.mom.common.numbers').isInteger

local DEFAULT_WORLDSPACE = 'sys::default'
M.DEFAULT_WORLDSPACE = DEFAULT_WORLDSPACE

local function lowerString(value)
  if value == nil then return nil end
  return tostring(value):lower()
end

function M.normalizeWorldspace(value)
  if value == nil then return DEFAULT_WORLDSPACE end
  local str = tostring(value)
  if str == '' then return DEFAULT_WORLDSPACE end
  return str:lower()
end

local function validateExteriorCoords(x, y)
  local nx = tonumber(x)
  local ny = tonumber(y)
  if not isInteger(nx) or not isInteger(ny) then
    return nil, 'exterior coords must be integer x/y values'
  end
  -- Normalize signed zero before encoding the canonical scalar key.
  if nx == 0 then nx = 0 end
  if ny == 0 then ny = 0 end
  return true, nil, nx, ny
end

local function packExteriorCoords(x, y)
  local ok, err, nx, ny = validateExteriorCoords(x, y)
  if not ok then return nil, err end
  -- A delimited pair remains collision-free across the engine's complete
  -- integer coordinate domain. Numeric packing would necessarily impose an
  -- arbitrary world boundary or lose precision in Lua's number type.
  return tostring(nx) .. ',' .. tostring(ny)
end

function M.normalizePair(value)
  if type(value) ~= 'table' then return nil end
  local x = tonumber(value.x ~= nil and value.x or value[1])
  local y = tonumber(value.y ~= nil and value.y or value[2])
  local ok, err, nx, ny = validateExteriorCoords(x, y)
  if not ok then return nil, err end
  x, y = nx, ny
  return { x = x, y = y }
end

function M.exteriorKey(worldspace, x, y)
  local coordFragment = packExteriorCoords(x, y)
  if coordFragment == nil then return nil end
  return M.normalizeWorldspace(worldspace) .. '|' .. coordFragment
end

function M.parseExteriorKey(value)
  if value == nil then return nil end
  local worldspace, x, y = tostring(value):match('^(.-)|(-?%d+),(-?%d+)$')
  if not worldspace then return nil end
  return {
    kind = 'exterior',
    key = M.exteriorKey(worldspace, tonumber(x), tonumber(y)),
    worldspace = M.normalizeWorldspace(worldspace),
    gridX = tonumber(x),
    gridY = tonumber(y),
  }
end

function M.interiorKey(value)
  return lowerString(value)
end

function M.regionKey(region, maybeRegion)
  local normalizedRegion = lowerString(maybeRegion ~= nil and maybeRegion or region)
  if normalizedRegion == nil or normalizedRegion == '' then return nil end
  return normalizedRegion
end

function M.worldspaceKey(worldspace)
  return M.normalizeWorldspace(worldspace)
end

function M.packedCellKeyForCoords(x, y)
  return packExteriorCoords(x, y)
end

function M.unpackExteriorCoords(packedCellKey)
  if type(packedCellKey) ~= 'string' then
    return nil, nil, 'invalid packed exterior cell key'
  end
  local x, y = packedCellKey:match('^(-?%d+),(-?%d+)$')
  local ok, err, nx, ny = validateExteriorCoords(x, y)
  if not ok or packExteriorCoords(nx, ny) ~= packedCellKey then
    return nil, nil, err or 'invalid packed exterior cell key'
  end
  return nx, ny, nil
end

function M.fromSignature(signature, fallbackId)
  if type(signature) ~= 'table' then
    local key = M.interiorKey(fallbackId)
    return key and {
      kind = 'interior',
      key = key,
      id = fallbackId,
      idLower = key,
      interiorKey = key,
    } or nil
  end

  if signature.isExterior == true then
    local worldspace = M.normalizeWorldspace(signature.worldspaceKey or signature.worldSpaceId)
    local key = M.exteriorKey(worldspace, signature.gridX, signature.gridY)
    if key then
      local regionKey = M.regionKey(signature.regionKey or signature.regionId or signature.region)
      return {
        kind = 'exterior',
        key = key,
        id = signature.id,
        idLower = M.interiorKey(signature.id),
        isExterior = true,
        regionKey = regionKey,
        worldspaceKey = M.worldspaceKey(worldspace),
        gridX = tonumber(signature.gridX),
        gridY = tonumber(signature.gridY),
        packedCellKey = M.packedCellKeyForCoords(signature.gridX, signature.gridY),
      }
    end
  end

  local id = signature.id or fallbackId
  local key = M.interiorKey(id)
  return key and {
    kind = 'interior',
    key = key,
    id = id,
    idLower = key,
    interiorKey = key,
    isExterior = false,
  } or nil
end

function M.fromCellObject(cellObj, fallbackId)
  if not cellObj then
    return M.fromSignature(nil, fallbackId)
  end
  local id = cellObj.id or fallbackId
  if cellObj.isExterior == true then
    local worldspace = M.normalizeWorldspace(cellObj.worldSpaceId)
    local key = M.exteriorKey(worldspace, cellObj.gridX, cellObj.gridY)
    if key then
      local gridX = tonumber(cellObj.gridX)
      local gridY = tonumber(cellObj.gridY)
      return {
        kind = 'exterior',
        key = key,
        id = id,
        idLower = M.interiorKey(id),
        isExterior = true,
        regionKey = M.regionKey(cellObj.region),
        worldspaceKey = M.worldspaceKey(worldspace),
        gridX = gridX,
        gridY = gridY,
        packedCellKey = M.packedCellKeyForCoords(gridX, gridY),
      }
    end
  end
  local key = M.interiorKey(id)
  return key and {
    kind = 'interior',
    key = key,
    id = id,
    idLower = key,
    interiorKey = key,
    isExterior = false,
  } or nil
end

return M
