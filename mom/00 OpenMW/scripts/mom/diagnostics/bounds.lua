-- Shared reporting policy. Lifecycle codecs retain their separate wire limits.
local M = {SAMPLE_LIMIT = 8, TEXT_LIMIT = 2048}

function M.text(value, limit, suffix)
  local text = tostring(value)
  limit = limit or M.TEXT_LIMIT
  if #text <= limit then return text end
  return text:sub(1, limit) .. (suffix == nil and '...' or suffix)
end

function M.sample(values, limit, transform)
  local count = #(values or {})
  limit = limit or M.SAMPLE_LIMIT
  local out = {}
  for i = 1, math.min(count, limit) do
    out[i] = transform and transform(values[i]) or values[i]
  end
  return out, count > limit, count
end

return M
