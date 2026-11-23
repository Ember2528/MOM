-- String, table, and geometry operations shared by harness scenarios.
local C = require('scripts.mom_test_orchestrator.constants')
local util = require('openmw.util')

local M = {}

function M.normalizeString(value)
  if value == nil then return nil end
  local str = tostring(value)
  if str == '' then return nil end
  return str
end

function M.normalizeRecordId(value)
  local str = M.normalizeString(value)
  return str and str:lower() or nil
end

function M.normalizeCellId(value)
  local str = M.normalizeString(value)
  return str and str:lower() or nil
end

-- Table / position helpers

function M.copyArray(values)
  local out = {}
  for i = 1, #(values or {}) do
    out[i] = values[i]
  end
  return out
end

function M.copyPosition(pos)
  return {
    x = tonumber(pos and (pos.x or pos[1])) or 0,
    y = tonumber(pos and (pos.y or pos[2])) or 0,
    z = tonumber(pos and (pos.z or pos[3])) or 0,
  }
end

function M.vector3From(pos)
  return util.vector3(
    tonumber(pos and (pos.x or pos[1])) or 0,
    tonumber(pos and (pos.y or pos[2])) or 0,
    tonumber(pos and (pos.z or pos[3])) or 0
  )
end

function M.offsetPosition(pos, dx, dy, dz)
  return {
    x = (pos and pos.x or 0) + (dx or 0),
    y = (pos and pos.y or 0) + (dy or 0),
    z = (pos and pos.z or 0) + (dz or 0),
  }
end

function M.exteriorCellCenter(gridX, gridY)
  return {
    x = gridX * C.EXTERIOR_CELL_SIZE + C.EXTERIOR_CELL_SIZE / 2,
    y = gridY * C.EXTERIOR_CELL_SIZE + C.EXTERIOR_CELL_SIZE / 2,
    z = 0,
  }
end

function M.distanceSquared(left, right)
  local dx = (left and left.x or 0) - (right and right.x or 0)
  local dy = (left and left.y or 0) - (right and right.y or 0)
  local dz = (left and left.z or 0) - (right and right.z or 0)
  return dx * dx + dy * dy + dz * dz
end

function M.positionNear(left, right, tolerance)
  tolerance = tolerance or 32
  return M.distanceSquared(left, right) <= (tolerance * tolerance)
end

function M.scaleNear(value, expected, tolerance)
  return math.abs((tonumber(value) or 1.0) - tonumber(expected or 1.0)) <= (tolerance or 0.01)
end

-- Player / cell helpers

return M
