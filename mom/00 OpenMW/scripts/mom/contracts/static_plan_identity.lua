-- Canonical identity for the static action set evaluated for one runtime cell.
-- Action IDs are semantic definition keys. Query catalog revisions only
-- invalidate discovery; source order and unrelated manifest content stay out.
local M = {}

local canonical = require('scripts.mom.contracts.canonical')
local plain_data = require('scripts.mom.contracts.plain_data')
local strings = require('scripts.mom.common.strings')

local HASH_BYTES_PER_WORK = 64

function M.normalize(actionIds, path)
  path = path or 'staticActionIds'
  actionIds = actionIds or {}
  if type(actionIds) ~= 'table'
      or (next(actionIds) ~= nil and plain_data.shape(actionIds) ~= 'array') then
    return nil, {path .. ': expected dense array'}
  end
  local out, seen = {}, {}
  for i = 1, #actionIds do
    local actionId = actionIds[i]
    if type(actionId) ~= 'string' or actionId == '' then
      return nil, {path .. '[' .. tostring(i) .. ']: expected non-empty string'}
    end
    if seen[actionId] then
      return nil, {path .. '[' .. tostring(i) .. ']: duplicate action id ' .. actionId}
    end
    seen[actionId] = true
    out[#out + 1] = actionId
  end
  table.sort(out)
  return out, nil
end

function M.hash(actionIds, path, discovery)
  local normalized, errors = M.normalize(actionIds, path)
  if not normalized then return nil, errors end
  local value = {actionIds = normalized}
  if discovery ~= nil and #discovery > 0 then value.discovery = discovery end
  return canonical.hash(value, {path = path or 'staticPlan'})
end

function M.assertHash(actionIds, path, discovery)
  local hash, errors = M.hash(actionIds, path, discovery)
  if hash then return hash end
  error(table.concat(errors or {}, ' | '), 0)
end

-- Catalog membership changes discovery, not the meaning of an action against
-- an already-owned target. Include descendants so a newly matching child can
-- be discovered even when its output-producing static parent is retained.
-- The manifest has already crossed its acyclic parent/child validation boundary.
function M.discoveryRevisions(manifest)
  local revisions, visited = {}, {}
  local actions = manifest.actionsById or {}
  for _, id in ipairs(manifest.actionIds or {}) do
    local root = actions[id]
    if root and root.lifecycle == 'static' and not visited[id] then
      local stack = {{action = root, cursor = 1, children = {}}}
      while #stack > 0 do
        local frame = stack[#stack]
        local childId = (frame.action.childIds or {})[frame.cursor]
        local child = childId and actions[childId]
        if child and child.lifecycle == 'static' and not visited[childId] then
          stack[#stack + 1] = {action = child, cursor = 1, children = {}}
        elseif childId ~= nil then
          if revisions[childId] then
            frame.children[#frame.children + 1] = {childId, revisions[childId]}
          end
          frame.cursor = frame.cursor + 1
        else
          local records = frame.action.selection and frame.action.selection.queryRecords
          if records ~= nil or #frame.children > 0 then
            local value = {queryRecords = records}
            if #frame.children > 0 then value.children = frame.children end
            revisions[frame.action.id] = canonical.assertHash(value)
          end
          visited[frame.action.id] = true
          stack[#stack] = nil
        end
      end
    end
  end
  return revisions
end

-- Cooperative equivalent of hash() for an already sorted, unique action-ID
-- array produced by the runtime route merge. It emits the exact canonical byte
-- stream used above, one bounded byte slice at a time.
function M.beginTrustedHash(actionIds, discovery)
  if type(actionIds) ~= 'table' then
    return nil, {'staticActionIds: expected dense array'}
  end
  local hashPrimary, hashSecondary = strings.beginHashLanes()
  local hasDiscovery = discovery ~= nil and #discovery > 0
  local prefix = hasDiscovery and 'o2{s9:actionIds' or 'o1{s9:actionIds'
  return {
    kind = 'static-plan-hash',
    actionIds = actionIds,
    discovery = hasDiscovery and discovery or nil,
    discoveryCursor = 1,
    hashPrimary = hashPrimary,
    hashSecondary = hashSecondary,
    phase = #actionIds == 0 and 'empty-prefix' or 'prefix',
    segment = #actionIds == 0 and (prefix .. 'o0{')
      or (prefix .. 'a' .. tostring(#actionIds) .. '['),
    byteCursor = 1,
    actionCursor = 1,
    complete = false,
    hash = nil,
  }, nil
end

local function finishActions(state, close)
  if state.discovery ~= nil then
    state.phase = 'discovery-prefix'
    state.segment = close .. 's9:discoverya' .. tostring(#state.discovery) .. '['
  else
    state.phase = 'suffix'
    state.segment = close .. '}'
  end
end

local function nextSegment(state)
  if state.phase == 'empty-prefix' then
    finishActions(state, '}')
  elseif state.phase == 'prefix' then
    if state.actionIds[state.actionCursor] == nil then
      finishActions(state, ']')
    else
      local actionId = state.actionIds[state.actionCursor]
      state.phase = 'id-prefix'
      state.segment = 's' .. tostring(#actionId) .. ':'
    end
  elseif state.phase == 'id-prefix' then
    state.phase = 'id'
    state.segment = state.actionIds[state.actionCursor]
  elseif state.phase == 'id' then
    state.actionCursor = state.actionCursor + 1
    if state.actionIds[state.actionCursor] == nil then
      finishActions(state, ']')
    else
      local actionId = state.actionIds[state.actionCursor]
      state.phase = 'id-prefix'
      state.segment = 's' .. tostring(#actionId) .. ':'
    end
  elseif state.phase == 'discovery-prefix' then
    state.phase, state.segment = 'discovery-row-start', 'a2['
  elseif state.phase == 'discovery-row-start' then
    local id = state.discovery[state.discoveryCursor][1]
    state.phase, state.segment = 'discovery-id-prefix', 's' .. tostring(#id) .. ':'
  elseif state.phase == 'discovery-id-prefix' then
    state.phase, state.segment = 'discovery-id', state.discovery[state.discoveryCursor][1]
  elseif state.phase == 'discovery-id' then
    local revision = state.discovery[state.discoveryCursor][2]
    state.phase, state.segment = 'discovery-revision-prefix', 's' .. tostring(#revision) .. ':'
  elseif state.phase == 'discovery-revision-prefix' then
    state.phase, state.segment = 'discovery-revision', state.discovery[state.discoveryCursor][2]
  elseif state.phase == 'discovery-revision' then
    state.phase, state.segment = 'discovery-row-end', ']'
  elseif state.phase == 'discovery-row-end' then
    state.discoveryCursor = state.discoveryCursor + 1
    if state.discovery[state.discoveryCursor] ~= nil then
      state.phase, state.segment = 'discovery-row-start', 'a2['
    else
      state.phase, state.segment = 'suffix', ']}'
    end
  elseif state.phase == 'suffix' then
    state.phase = 'complete'
    state.segment = nil
    state.complete = true
    state.hash = canonical.formatHashLanes(
      state.hashPrimary,
      state.hashSecondary
    )
  end
  state.byteCursor = 1
end

function M.advanceTrustedHash(state, limit)
  if type(state) ~= 'table' or state.kind ~= 'static-plan-hash'
      or type(limit) ~= 'number' or limit < 0
      or (limit ~= math.huge and limit % 1 ~= 0) then
    return nil, {'static plan hash state or budget is invalid'}
  end
  local used = 0
  while used < limit and not state.complete do
    local bytes = 0
    while bytes < HASH_BYTES_PER_WORK and not state.complete do
      local segment = state.segment
      local remaining = segment and (#segment - state.byteCursor + 1) or 0
      if remaining <= 0 then
        nextSegment(state)
      else
        local take = math.min(HASH_BYTES_PER_WORK - bytes, remaining)
        local last = state.byteCursor + take - 1
        state.hashPrimary, state.hashSecondary = strings.advanceHashBytes(
          state.hashPrimary,
          state.hashSecondary,
          segment,
          state.byteCursor,
          last
        )
        state.byteCursor = last + 1
        bytes = bytes + take
      end
    end
    used = used + 1
  end
  return {
    complete = state.complete,
    work = used,
    hash = state.hash,
  }, nil
end

return M
