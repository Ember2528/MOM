-- Deterministic logical identities and injective length-prefixed keys.
local M = {}

local strings = require('scripts.mom.common.strings')
local canonical = require('scripts.mom.contracts.canonical')

local nonEmpty = strings.isNonEmpty

-- Length-prefixed injective tuple encoding so no delimiter collision can occur.
function M.encodeKey(tag, ...)
  assert(nonEmpty(tag), 'identity tag must be a non-empty string')
  local parts = {tag}
  local count = select('#', ...)
  for i = 1, count do
    local value = select(i, ...)
    if value == nil then
      parts[#parts + 1] = '|-'
    else
      local text = tostring(value)
      parts[#parts + 1] = '|' .. tostring(#text) .. ':' .. text
    end
  end
  return table.concat(parts)
end

function M.cellId(cellKey)
  assert(nonEmpty(cellKey), 'cellKey is required')
  return 'cell:' .. tostring(cellKey):lower()
end

function M.refId(contentFile, refNum)
  assert(nonEmpty(contentFile), 'contentFile is required')
  assert(type(refNum) == 'number' and refNum >= 0 and refNum % 1 == 0,
    'refNum must be a non-negative integer')
  return string.format('content:%06x:%s', refNum, tostring(contentFile):lower())
end

function M.outputId(parentTargetId, family, producerId, slot)
  assert(nonEmpty(parentTargetId), 'output parentTargetId is required')
  assert(nonEmpty(family), 'output family is required')
  assert(nonEmpty(producerId), 'output producerId is required')
  assert(nonEmpty(slot), 'output slot is required')
  local hash = canonical.assertHash({
    kind = 'output',
    parentTargetId = parentTargetId,
    family = family,
    producerId = producerId,
    slot = slot,
  })
  return 'output:' .. hash:sub(7)
end

function M.semanticId(actionId, targetId, parentOpId)
  assert(nonEmpty(actionId), 'actionId is required')
  assert(nonEmpty(targetId), 'targetId is required')
  return M.encodeKey('sem', actionId, targetId, parentOpId)
end

function M.isCellId(id)
  return type(id) == 'string' and id:sub(1, 5) == 'cell:'
end

function M.isRefId(id)
  return type(id) == 'string' and id:sub(1, 8) == 'content:'
end

function M.isOutputId(id)
  return type(id) == 'string' and id:sub(1, 7) == 'output:'
end

function M.cellKeyFromId(id)
  if not M.isCellId(id) then return nil end
  return id:sub(6)
end

return M
