-- Derive possible physical cells from family-owned capture tokens.
local M = {}
local cell_identity = require('scripts.mom.domain.cell.identity')

function M.cellAt(cell, position)
  local key = type(cell) == 'table' and (cell.key or cell.id) or nil
  if type(key) ~= 'string' or key == '' then return nil end
  local exterior = cell_identity.parseExteriorKey(key)
  if (cell.isExterior == true or exterior ~= nil) and type(position) == 'table'
      and type(position.x) == 'number' and type(position.y) == 'number' then
    return cell_identity.exteriorKey(cell.worldspaceKey or (exterior and exterior.worldspace),
      math.floor(position.x / 8192), math.floor(position.y / 8192))
  end
  return key:lower()
end

-- Capture only the possible starting and configured destination cells.
-- Transform coordinates remain engine-owned and are read when the ref exists.
function M.forTransform(starting, patch)
  if patch.position == nil and patch.relocate == nil then return nil end
  local start = M.cellAt(starting.cell, starting.position)
  local cell = patch.relocate and patch.relocate.cell or starting.cell
  local position = patch.relocate and patch.relocate.position or patch.position
  if patch.position and patch.position.mode == 'move' then
    position = {x = starting.position.x + patch.position.x,
      y = starting.position.y + patch.position.y}
  end
  local destination = M.cellAt(cell, position)
  if start == nil or destination == nil then return nil, 'position recovery cells unavailable' end
  return start == destination and {start} or {start, destination}, nil
end

function M.fromOperation(operation)
  local cells, seen = {}, {}
  local function addKey(key)
    if type(key) ~= 'string' or key == '' then return end
    key = key:lower()
    if not seen[key] then seen[key] = true; cells[#cells + 1] = key end
  end
  local function add(cell)
    addKey(type(cell) == 'table' and (cell.key or cell.id) or nil)
  end
  for _, name in ipairs({'revertToken', 'applyToken', 'transitionToken'}) do
    local token = operation[name]
    if type(token) == 'table' and type(token.patch) == 'table'
        and (token.patch.position ~= nil or token.patch.relocate ~= nil) then
      if not (type(operation.operationState) == 'table'
          and operation.operationState.recoverySourceCell ~= nil) then
        add(token.baseline and token.baseline.cell)
      end
      if type(token.recoveryCells) ~= 'table' then
        return nil, 'modify_ref recovery cells are unavailable'
      end
      local count = 0
      for key, cell in pairs(token.recoveryCells) do
        count = count + 1
        if type(key) ~= 'number' or key < 1 or key > 2 or key % 1 ~= 0
            or type(cell) ~= 'string' or cell == '' or cell ~= cell:lower() then
          return nil, 'modify_ref recovery cells are invalid'
        end
      end
      if count == 0 then return nil, 'modify_ref recovery cells are unavailable' end
      for i = 1, count do
        if type(token.recoveryCells[i]) ~= 'string' then
          return nil, 'modify_ref recovery cells are not dense'
        end
        addKey(token.recoveryCells[i])
      end
    end
  end
  return cells
end

return M
