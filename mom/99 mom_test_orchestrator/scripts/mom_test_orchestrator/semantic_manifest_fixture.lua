-- Canonical manifest assembly for harness fixtures that author readable
-- symbolic IDs. Symbols exist only while building the fixture: every action,
-- owner, parent/child edge, and derived index is remapped to production
-- semantic IDs before the real assembler and manifest validator run.
local M = {}

local manifest_assembler = require('scripts.mom.compiler.manifest_assembler')
local plain_data = require('scripts.mom.contracts.plain_data')
local plan_identity = require('scripts.mom.contracts.plan_identity')

local aliasesByManifest = setmetatable({}, {__mode = 'k'})

local function failure(message)
  return nil, {tostring(message)}
end

local function remapArray(values, aliases)
  for i = 1, #(values or {}) do
    values[i] = aliases[values[i]] or values[i]
  end
end

local function remapBuckets(buckets, aliases)
  for _, values in pairs(buckets or {}) do remapArray(values, aliases) end
end

local function canonicalize(seed)
  local detached, detachErrors = plain_data.detach(seed or {}, {
    path = 'fixtureManifestSeed',
  })
  if detached == nil then return nil, detachErrors end
  detached.actions = detached.actions or {}
  detached.owners = detached.owners or {}
  detached.indexes = detached.indexes or {}

  local ownersByAlias = {}
  for i = 1, #detached.owners do
    local owner = detached.owners[i]
    local alias = owner and owner.id or nil
    if type(alias) ~= 'string' or alias == '' then
      return failure('owners[' .. tostring(i) .. '].id: expected symbolic ID')
    end
    if ownersByAlias[alias] ~= nil then
      return failure('owners[' .. tostring(i) .. '].id: duplicate symbolic ID')
    end
    ownersByAlias[alias] = owner
  end

  local actionsByAlias = {}
  for i = 1, #detached.actions do
    local action = detached.actions[i]
    local alias = action and action.id or nil
    if type(alias) ~= 'string' or alias == '' then
      return failure('actions[' .. tostring(i) .. '].id: expected symbolic ID')
    end
    if actionsByAlias[alias] ~= nil then
      return failure('actions[' .. tostring(i) .. '].id: duplicate symbolic ID')
    end
    actionsByAlias[alias] = action
    if action.lifecycle == 'state' and action.guardKey == nil then
      local owner = ownersByAlias[action.ownerId]
      if owner ~= nil then
        action.guardKey = plan_identity.guardKey(
          owner.guard,
          owner.subscriptions
        )
      end
    end
  end

  local actionAliases, resolving = {}, {}
  local function resolveAction(alias)
    if actionAliases[alias] ~= nil then return actionAliases[alias] end
    local action = actionsByAlias[alias]
    if action == nil then return alias end
    if resolving[alias] then
      error('fixture action parent graph contains a cycle at ' .. alias, 0)
    end
    resolving[alias] = true
    if action.parentId ~= nil then
      action.parentId = resolveAction(action.parentId)
    end
    local semanticId = plan_identity.actionId(action)
    action.id = semanticId
    actionAliases[alias] = semanticId
    resolving[alias] = nil
    return semanticId
  end
  local resolved, resolveError = pcall(function()
    for alias in pairs(actionsByAlias) do resolveAction(alias) end
  end)
  if not resolved then return failure(resolveError) end

  for i = 1, #detached.actions do
    remapArray(detached.actions[i].childIds, actionAliases)
  end

  local ownerAliases = {}
  for alias, owner in pairs(ownersByAlias) do
    remapArray(owner.actionIds, actionAliases)
    table.sort(owner.actionIds or {})
    table.sort(owner.subscriptions or {})
    local semanticId = plan_identity.ownerId(owner)
    owner.id = semanticId
    ownerAliases[alias] = semanticId
  end
  for i = 1, #detached.actions do
    local action = detached.actions[i]
    if action.ownerId ~= nil then
      action.ownerId = ownerAliases[action.ownerId] or action.ownerId
    end
  end

  remapBuckets(detached.indexes.staticByCell, actionAliases)
  for _, actionIds in pairs(detached.indexes.staticByCell or {}) do
    table.sort(actionIds)
  end
  remapBuckets(detached.indexes.exactObjectActive, actionAliases)
  remapBuckets(detached.indexes.previsitCells, actionAliases)
  remapBuckets(detached.indexes.ownersByCell, ownerAliases)

  return detached, {
    actions = actionAliases,
    owners = ownerAliases,
  }
end

function M.assemble(seed)
  local canonicalSeed, aliasesOrErrors = canonicalize(seed)
  if canonicalSeed == nil then return nil, aliasesOrErrors end
  local manifest, errors = manifest_assembler.assembleCompiled(canonicalSeed)
  if manifest ~= nil then aliasesByManifest[manifest] = aliasesOrErrors end
  return manifest, errors
end

function M.actionId(manifest, alias)
  local aliases = aliasesByManifest[manifest]
  return aliases and aliases.actions[alias] or nil
end

function M.ownerId(manifest, alias)
  local aliases = aliasesByManifest[manifest]
  return aliases and aliases.owners[alias] or nil
end

function M.action(manifest, alias)
  local id = M.actionId(manifest, alias) or alias
  return manifest and manifest.actionsById[id] or nil
end

function M.owner(manifest, alias)
  local id = M.ownerId(manifest, alias) or alias
  return manifest and manifest.ownersById[id] or nil
end

local function remapMap(manifest, values, kind)
  values = values or {}
  local aliases = aliasesByManifest[manifest]
  local mapping = aliases and aliases[kind] or {}
  local changed = false
  for id in pairs(values) do
    if mapping[id] ~= nil and mapping[id] ~= id then
      changed = true
      break
    end
  end
  if not changed then return values end

  local out = {}
  for id, value in pairs(values) do
    local semanticId = mapping[id] or id
    assert(out[semanticId] == nil,
      'duplicate harness fixture alias for ' .. tostring(semanticId))
    out[semanticId] = value
  end
  return out
end

function M.actionMap(manifest, values)
  return remapMap(manifest, values, 'actions')
end

function M.ownerMap(manifest, values)
  return remapMap(manifest, values, 'owners')
end

function M.aliases(manifest)
  return aliasesByManifest[manifest]
end

return M
