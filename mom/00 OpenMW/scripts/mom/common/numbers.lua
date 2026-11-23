-- Shared numeric validation and option normalization.
local M = {}

function M.isInteger(value)
  return type(value) == 'number' and value % 1 == 0
end

function M.isFinite(value)
  return type(value) == 'number' and value == value
    and value ~= math.huge and value ~= -math.huge
end

-- Use the uncoerced fallback only when the supplied value cannot become a number.
function M.positiveInteger(value, default)
  value = tonumber(value)
  if value == nil then value = default end
  if type(value) ~= 'number' or value < 1 or value % 1 ~= 0
      or value == math.huge then
    return nil
  end
  return value
end

return M
