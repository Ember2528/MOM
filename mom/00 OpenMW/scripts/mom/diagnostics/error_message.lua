-- Deterministic rendering for errors that cross MOM module boundaries.
-- Callers may return scalar messages, arrays, or structured error objects;
-- diagnostics must retain nested detail without exposing table addresses.
local M = {}

local MAX_PARTS = 32
local MAX_DEPTH = 8
local MAX_PART_LENGTH = 2048

local function appendText(parts, value)
  if #parts >= MAX_PARTS or value == nil then return end
  local text = tostring(value)
  if text == '' then return end
  if #text > MAX_PART_LENGTH then
    text = text:sub(1, MAX_PART_LENGTH) .. '...'
  end
  parts[#parts + 1] = text
end

local appendValue

local function appendArray(parts, values, seen, depth)
  for i = 1, #values do
    if #parts >= MAX_PARTS then return end
    appendValue(parts, values[i], seen, depth + 1)
  end
end

appendValue = function(parts, value, seen, depth)
  if #parts >= MAX_PARTS or value == nil or depth > MAX_DEPTH then return end
  if type(value) ~= 'table' then
    appendText(parts, value)
    return
  end
  if seen[value] then return end
  seen[value] = true

  local code = value.code or value.kind
  if code ~= nil then
    local text = tostring(code)
    if value.path ~= nil then text = text .. ' at ' .. tostring(value.path) end
    appendText(parts, text)
  end
  if value.message ~= nil then
    appendValue(parts, value.message, seen, depth + 1)
  elseif value.reason ~= nil then
    appendValue(parts, value.reason, seen, depth + 1)
  elseif code == nil and value.status ~= nil then
    appendText(parts, value.status)
  end

  if value.errors ~= nil then
    appendValue(parts, value.errors, seen, depth + 1)
  end
  if value.error ~= nil then
    appendValue(parts, value.error, seen, depth + 1)
  end
  if value.details ~= nil then
    appendValue(parts, value.details, seen, depth + 1)
  end
  if #value > 0 then
    appendArray(parts, value, seen, depth)
  end
end

function M.message(value, fallback)
  local parts = {}
  appendValue(parts, value, {}, 0)
  if #parts == 0 then return tostring(fallback or 'unknown error') end
  if #parts >= MAX_PARTS then parts[#parts + 1] = '...' end
  return table.concat(parts, ': ')
end

return M
