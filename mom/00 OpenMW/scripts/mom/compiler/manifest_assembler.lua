-- Pure assembly of action/owner records and derived event indexes.
local M = {}

local manifest_contract = require('scripts.mom.contracts.manifest_contract')

local function packActions(actions)
  table.sort(actions, function(left, right)
    return tostring(left and left.id) < tostring(right and right.id)
  end)
  local ids = {}
  local byId = {}
  for i = 1, #actions do
    local action = actions[i]
    table.sort(action.childIds or {})
    action.order = i
    if byId[action.id] then
      return nil, nil, {'actions[' .. tostring(i) .. ']: duplicate action id ' .. tostring(action.id)}
    end
    ids[#ids + 1] = action.id
    byId[action.id] = action
  end
  return ids, byId, nil
end

local function packOwners(owners)
  table.sort(owners, function(left, right)
    return tostring(left and left.id) < tostring(right and right.id)
  end)
  local ids = {}
  local byId = {}
  for i = 1, #owners do
    local owner = owners[i]
    if byId[owner.id] then
      return nil, nil, {'owners[' .. tostring(i) .. ']: duplicate owner id ' .. tostring(owner.id)}
    end
    ids[#ids + 1] = owner.id
    byId[owner.id] = owner
  end
  return ids, byId, nil
end

-- Sorted owners and unique subscriptions give every bucket its final order.
local function deriveOwnersByEvent(ownerIds, ownersById)
  local out = {}
  for i = 1, #ownerIds do
    local ownerId = ownerIds[i]
    local owner = ownersById[ownerId]
    for j = 1, #(owner.subscriptions or {}) do
      local eventName = owner.subscriptions[j]
      local bucket = out[eventName]
      if not bucket then
        bucket = {}
        out[eventName] = bucket
      end
      bucket[#bucket + 1] = ownerId
    end
  end
  return out
end

-- Takes ownership of canonical compiler records and routes. Source compilation
-- owns owner membership order, guard subscriptions and sorted route arrays.
-- Assembly owns global/child order, final indexes and complete validation.
function M.assembleCompiled(seed)
  seed = seed or {}
  local ownerIds, ownersById, ownerErrors = packOwners(seed.owners or {})
  if not ownerIds then return nil, ownerErrors end
  local actionIds, actionsById, actionErrors = packActions(seed.actions or {})
  if not actionIds then return nil, actionErrors end
  local extensions = seed.extensions or {}
  local indexes = seed.indexes or {}

  local manifest = {
    contentHash = '',
    extensions = extensions,
    actionsById = actionsById,
    actionIds = actionIds,
    ownersById = ownersById,
    ownerIds = ownerIds,
    indexes = {
      staticByCell = indexes.staticByCell or {},
      ownersByCell = indexes.ownersByCell or {},
      ownersByEvent = deriveOwnersByEvent(ownerIds, ownersById),
      exactObjectActive = indexes.exactObjectActive or {},
      previsitCells = indexes.previsitCells or {},
    },
  }
  manifest.contentHash = manifest_contract.contentHash(manifest)
  local ok, errors = manifest_contract.validateCompiled(manifest)
  if not ok then return nil, errors end
  return manifest, nil
end

return M
