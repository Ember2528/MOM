-- Single shared binary min-heap deadline queue keyed by string ID.
-- Deterministic tie-breaking: earlier dueFrame first, then lexicographical id.
local M = {}

local function before(left, right)
  if left.dueFrame ~= right.dueFrame then
    return left.dueFrame < right.dueFrame
  end
  return left.id < right.id
end

local function swap(heap, positions, i, j)
  local a, b = heap[i], heap[j]
  heap[i], heap[j] = b, a
  positions[a.id] = j
  positions[b.id] = i
end

local function siftUp(heap, positions, index)
  while index > 1 do
    local parent = math.floor(index / 2)
    if before(heap[index], heap[parent]) then
      swap(heap, positions, index, parent)
      index = parent
    else
      break
    end
  end
end

local function siftDown(heap, positions, index)
  local size = #heap
  while true do
    local left = index * 2
    local right = left + 1
    local smallest = index
    if left <= size and before(heap[left], heap[smallest]) then
      smallest = left
    end
    if right <= size and before(heap[right], heap[smallest]) then
      smallest = right
    end
    if smallest == index then break end
    swap(heap, positions, index, smallest)
    index = smallest
  end
end

function M.new()
  return {
    heap = {},
    positions = {},
  }
end

function M.count(queue)
  return #queue.heap
end

function M.contains(queue, id)
  return queue.positions[id] ~= nil
end

function M.get(queue, id)
  local index = queue.positions[id]
  return index ~= nil and queue.heap[index] or nil
end

function M.peek(queue)
  return queue.heap[1]
end

function M.hasDue(queue, nowFrame)
  local top = queue.heap[1]
  return top ~= nil and top.dueFrame <= nowFrame
end

function M.upsert(queue, id, dueFrame, payload)
  assert(type(id) == 'string' and id ~= '', 'deadline queue id must be a non-empty string')
  assert(type(dueFrame) == 'number' and dueFrame == dueFrame and dueFrame ~= math.huge,
    'deadline queue dueFrame must be finite')
  local heap = queue.heap
  local positions = queue.positions
  local index = positions[id]
  if index ~= nil then
    local entry = heap[index]
    local previous = entry.dueFrame
    entry.dueFrame = dueFrame
    entry.payload = payload
    if dueFrame < previous then
      siftUp(heap, positions, index)
    elseif dueFrame > previous then
      siftDown(heap, positions, index)
    end
    return entry
  end
  local entry = {
    id = id,
    dueFrame = dueFrame,
    payload = payload,
  }
  local pos = #heap + 1
  heap[pos] = entry
  positions[id] = pos
  siftUp(heap, positions, pos)
  return entry
end

function M.remove(queue, id)
  local heap = queue.heap
  local positions = queue.positions
  local index = positions[id]
  if index == nil then return nil end
  local removed = heap[index]
  local last = #heap
  positions[id] = nil
  if index == last then
    heap[last] = nil
    return removed
  end
  local moved = heap[last]
  heap[last] = nil
  heap[index] = moved
  positions[moved.id] = index
  if index > 1 and before(moved, heap[math.floor(index / 2)]) then
    siftUp(heap, positions, index)
  else
    siftDown(heap, positions, index)
  end
  return removed
end

function M.popNextDue(queue, nowFrame)
  local top = queue.heap[1]
  if top == nil or top.dueFrame > nowFrame then return nil end
  return M.remove(queue, top.id)
end

function M.clear(queue)
  queue.heap = {}
  queue.positions = {}
end

return M
