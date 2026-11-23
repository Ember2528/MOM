-- Compiled conjunction of record exclusions, yaw intervals, and tilt limits.
local M = {}

local predicate = require('scripts.mom.contracts.predicate')

local function normalized(value)
  value = tonumber(value)
  if value == nil then return nil end
  return value % 360
end

local function arc(direction, tolerance)
  direction = normalized(direction)
  tolerance = tonumber(tolerance) or 45
  if direction == nil or tolerance < 0 then return {} end
  if tolerance >= 180 then return {{first = 0, last = 360}} end
  local first = (direction - tolerance) % 360
  local last = (direction + tolerance) % 360
  if first <= last then return {{first = first, last = last}} end
  return {
    {first = 0, last = last},
    {first = first, last = 360},
  }
end

local function intersect(left, right)
  local out = {}
  for i = 1, #left do
    for j = 1, #right do
      local first = math.max(left[i].first, right[j].first)
      local last = math.min(left[i].last, right[j].last)
      if first <= last then out[#out + 1] = {first = first, last = last} end
    end
  end
  table.sort(out, function(a, b)
    if a.first ~= b.first then return a.first < b.first end
    return a.last < b.last
  end)
  local merged = {}
  for i = 1, #out do
    local current = out[i]
    local previous = merged[#merged]
    if previous ~= nil and current.first <= previous.last then
      if current.last > previous.last then previous.last = current.last end
    else
      merged[#merged + 1] = current
    end
  end
  return merged
end

function M.build(predicates)
  local out = {
    excludedIds = {},
    yawIntervals = {{first = 0, last = 360}},
    maxTilt = nil,
    requiresOrientation = false,
    requiresYaw = false,
  }
  for i = 1, #(predicates or {}) do
    local value = predicates[i]
    if predicate.isRecordIdExclude(value) then
      for recordId, excluded in pairs(value.excludedIds or {}) do
        if excluded == true then out.excludedIds[recordId] = true end
      end
    elseif predicate.isOrientation(value) then
      out.requiresOrientation = true
      if value.mode == predicate.MODE_FACING then
        out.requiresYaw = true
        out.yawIntervals = intersect(
          out.yawIntervals,
          arc(value.direction, value.tolerance)
        )
      elseif value.mode == predicate.MODE_UPRIGHT then
        local maximum = tonumber(value.maxTilt) or 25
        if out.maxTilt == nil or maximum < out.maxTilt then
          out.maxTilt = maximum
        end
      else
        out.invalidKind = tostring(value.mode)
      end
    else
      out.invalidKind = tostring(value and value.kind)
    end
  end
  return out
end

local function tilt(value)
  value = normalized(value)
  if value == nil then return nil end
  if value > 180 then value = 360 - value end
  return math.abs(value)
end

function M.matches(index, facts)
  if type(index) ~= 'table' then
    return nil, 'target predicate index is invalid'
  end
  if index.invalidKind ~= nil then
    return nil, 'target predicate kind is unsupported: ' .. index.invalidKind
  end
  local recordId = facts and facts.recordId or nil
  if index.excludedIds[recordId] == true then return false, nil end
  if not index.requiresOrientation then return true, nil end
  local orientation = facts and facts.orientation or nil
  if type(orientation) ~= 'table' then return false, nil end
  if index.requiresYaw then
    if #index.yawIntervals == 0 then return false, nil end
    local yaw = normalized(orientation.yawDegrees)
    if yaw == nil then return false, nil end
    local yawMatched = false
    for i = 1, #index.yawIntervals do
      local interval = index.yawIntervals[i]
      if yaw >= interval.first and yaw <= interval.last then
        yawMatched = true
        break
      end
    end
    if not yawMatched then return false, nil end
  end
  if index.maxTilt ~= nil then
    local x = tilt(orientation.tiltXDegrees)
    local y = tilt(orientation.tiltYDegrees)
    if x == nil or y == nil or x > index.maxTilt or y > index.maxTilt then
      return false, nil
    end
  end
  return true, nil
end

return M
