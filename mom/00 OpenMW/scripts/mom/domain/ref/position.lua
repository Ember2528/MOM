local M = {}
local POSITION_DECIMALS = 3
local POSITION_FMT = '%.' .. tostring(POSITION_DECIMALS) .. 'f'
local function quantize(value)
  if type(value) ~= 'number' then return nil end
  return string.format(POSITION_FMT, value)
end
function M.normalizePosition(value)
  if type(value) ~= 'table' and type(value) ~= 'userdata' then return nil end
  local x = value.x
  local y = value.y
  local z = value.z
  if type(x) == 'number' and type(y) == 'number' and type(z) == 'number' then
    return { x = x, y = y, z = z }
  end
  local ax = value[1]
  local ay = value[2]
  local az = value[3]
  if type(ax) == 'number' and type(ay) == 'number' and type(az) == 'number' then
    return { x = ax, y = ay, z = az }
  end
  return nil
end
function M.positionsEqual(a, b)
  local left = M.normalizePosition(a)
  local right = M.normalizePosition(b)
  if not (left and right) then return false end
  return quantize(left.x) == quantize(right.x)
    and quantize(left.y) == quantize(right.y)
    and quantize(left.z) == quantize(right.z)
end
function M.keyForPosition(value)
  local position = M.normalizePosition(value)
  if not position then return nil end
  local x = quantize(position.x)
  local y = quantize(position.y)
  local z = quantize(position.z)
  if not (x and y and z) then return nil end
  return table.concat({ x, y, z }, ',')
end
return M
