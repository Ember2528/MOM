-- Shared predicate contract for authored filter heads and compiled predicate kinds.
local M = {}
M.HEAD_UPRIGHT = 'upright'
M.HEAD_FACING = 'facing'
M.HEAD_EXCLUDE = 'exclude'
M.KIND_ORIENTATION = 'orientation'
M.KIND_RECORD_ID_EXCLUDE = 'record_id_exclude'
M.MODE_UPRIGHT = 'upright'
M.MODE_FACING = 'facing'
local CARDINAL_DIRECTIONS = {
  north = 0,
  east = 90,
  south = 180,
  west = 270,
  northeast = 45,
  southeast = 135,
  southwest = 225,
  northwest = 315,
}
local function normalizeExactIds(values)
  if not values then return nil end
  local out = {}
  if type(values) == 'string' then
    out[values:lower()] = true
  elseif type(values) == 'table' then
    for _, value in ipairs(values) do
      out[tostring(value):lower()] = true
    end
  end
  return next(out) and out or nil
end
local function normalizeDirection(direction, path)
  if type(direction) == 'number' then
    return direction % 360, nil
  end
  if type(direction) == 'string' then
    local lower = direction:lower()
    if CARDINAL_DIRECTIONS[lower] ~= nil then
      return CARDINAL_DIRECTIONS[lower], nil
    end
  end
  return nil,
    string.format('%s.direction: unrecognized orientation direction %s', tostring(path), tostring(direction))
end
local function validateTupleArray(tuple, path)
  local count = #tuple
  for key in pairs(tuple) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > count then
      return path .. '.' .. tostring(key) .. ': is not allowed; expected predicate tuple array'
    end
  end
  return nil
end
local function validateTupleArity(tuple, path, maxArity)
  local arrayErr = validateTupleArray(tuple, path)
  if arrayErr then return arrayErr end
  if #tuple > maxArity then
    return path .. ': tuple is too long'
  end
  return nil
end
function M.kind(predicate)
  return type(predicate) == 'table' and predicate.kind or nil
end
function M.isOrientation(predicate)
  return M.kind(predicate) == M.KIND_ORIENTATION
end
function M.isRecordIdExclude(predicate)
  return M.kind(predicate) == M.KIND_RECORD_ID_EXCLUDE
end
function M.compileTuple(tuple, path)
  path = tostring(path or 'predicate')
  if type(tuple) ~= 'table' or #tuple == 0 then
    return nil, path .. ': expected non-empty predicate tuple'
  end
  local head = tuple[1]
  if type(head) ~= 'string' then
    return nil, path .. ': predicate tuple head must be a string, got ' .. type(head)
  end
  local headLower = head:lower()
  if headLower == M.HEAD_UPRIGHT then
    local lengthErr = validateTupleArity(tuple, path, 2)
    if lengthErr then return nil, lengthErr end
    local maxTilt = 25
    if tuple[2] ~= nil then
      if type(tuple[2]) ~= 'number' then
        return nil, path .. ': upright maxTilt must be a number'
      end
      maxTilt = tuple[2]
    end
    return {
      kind = M.KIND_ORIENTATION,
      mode = M.MODE_UPRIGHT,
      maxTilt = maxTilt,
    }, nil
  elseif headLower == M.HEAD_FACING then
    local lengthErr = validateTupleArity(tuple, path, 3)
    if lengthErr then return nil, lengthErr end
    if tuple[2] == nil then
      return nil, path .. ': facing requires a direction'
    end
    local tolerance = 45
    if tuple[3] ~= nil then
      if type(tuple[3]) ~= 'number' then
        return nil, path .. ': facing tolerance must be a number'
      end
      tolerance = tuple[3]
    end
    local direction, directionErrors = normalizeDirection(tuple[2], path)
    if directionErrors then
      return nil, directionErrors
    end
    return {
      kind = M.KIND_ORIENTATION,
      mode = M.MODE_FACING,
      direction = direction,
      tolerance = tolerance,
    }, nil
  elseif headLower == M.HEAD_EXCLUDE then
    local arrayErr = validateTupleArray(tuple, path)
    if arrayErr then return nil, arrayErr end
    if #tuple < 2 then
      return nil, path .. ': exclude requires at least one record id'
    end
    local ids = {}
    for i = 2, #tuple do
      if type(tuple[i]) ~= 'string' then
        return nil, path .. '[' .. tostring(i) .. ']: exclude ids must be strings'
      end
      ids[#ids + 1] = tuple[i]
    end
    return {
      kind = M.KIND_RECORD_ID_EXCLUDE,
      excludedIds = normalizeExactIds(ids),
    }, nil
  end
  return nil, path .. ': unknown predicate head: ' .. tostring(head)
end
return M
