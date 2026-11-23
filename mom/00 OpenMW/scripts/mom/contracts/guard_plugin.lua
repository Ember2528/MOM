local M = {}

local function validSegment(value)
  return type(value) == 'string' and value:match('^[a-z][a-z0-9_]*$') ~= nil
end

local function normalizeSegment(value, label)
  if type(value) ~= 'string' then
    error(tostring(label) .. ' must be a string')
  end
  local normalized = value:lower()
  if not validSegment(normalized) then
    error(tostring(label) .. ' must be a lowercase identifier segment')
  end
  return normalized
end

local function normalizeKey(value)
  if value == nil then return nil end
  local normalized = tostring(value):lower()
  if normalized == '' or normalized:find(':', 1, true) then
    error('guard event key must be non-empty and must not contain ":"')
  end
  return normalized
end

function M.guardEvent(namespace, eventName, key)
  local namespaceSegment = normalizeSegment(namespace, 'guard event namespace')
  local eventSegment = normalizeSegment(eventName, 'guard event name')
  local keySegment = normalizeKey(key)
  if keySegment then
    return 'external:' .. namespaceSegment .. ':' .. eventSegment .. ':' .. keySegment
  end
  return 'external:' .. namespaceSegment .. ':' .. eventSegment
end

function M.isValidExternalEvent(eventName)
  if type(eventName) ~= 'string' then return false end
  if eventName:find('::', 1, true) then return false end
  local parts = {}
  for part in eventName:gmatch('[^:]+') do
    parts[#parts + 1] = part
  end
  if #parts < 3 or #parts > 4 then return false end
  if parts[1] ~= 'external' then return false end
  if not validSegment(parts[2]) or not validSegment(parts[3]) then return false end
  if parts[4] ~= nil and parts[4] == '' then return false end
  return true
end

return M
