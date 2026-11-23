-- Declarative composition order, independent of execution and field priority.
-- Sources can order batches without leaking foreign priorities into unrelated
-- native operations. Absence retains ordinary priority/source ordering.
local M = {}
local function integer(value, low, high)
  return type(value) == 'number' and value % 1 == 0 and value >= low and value <= high
end
function M.validate(value, path)
  if value == nil then return true end
  path = path or 'compositionOrder'
  if type(value) ~= 'table' or #value ~= 4 then return nil, path .. ': expected [group, priority, module, entry]' end
  for key in pairs(value) do
    if not integer(key, 1, 4) then return nil, path .. ': expected dense composition tuple' end
  end
  if not integer(value[1], -2147483648, 2147483647)
      or not integer(value[2], -2147483648, 2147483647) or type(value[3]) ~= 'string'
      or not integer(value[4], 0, 2147483647) then
    return nil, path .. ': invalid composition group, priority, module or entry'
  end
  return true
end
function M.less(a, b)
  local left, right = a.compositionOrder, b.compositionOrder
  local ag, bg = left and left[1] or 0, right and right[1] or 0
  if ag ~= bg then return ag < bg end
  local ap, bp = left and left[2] or a.priority or 0, right and right[2] or b.priority or 0
  if ap ~= bp then return ap < bp end
  local am, bm = left and left[3] or '', right and right[3] or ''
  if am ~= bm then return am < bm end
  local ae, be = left and left[4] or a.order or 0, right and right[4] or b.order or 0
  if ae ~= be then return ae < be end
  if a.order ~= b.order then return (a.order or 0) < (b.order or 0) end
  return (a.source or '') < (b.source or '')
end
return M
