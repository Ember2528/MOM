-- Canonical semantic identities shared by the compiler, manifest contract,
-- and ledger. Source provenance and traversal order are deliberately absent.
local M = {}

local canonical = require('scripts.mom.contracts.canonical')

local function hashId(prefix, value, path)
  local hash = canonical.assertHash(value, {path = path})
  return prefix .. ':' .. canonical.assertHashBody(hash)
end

function M.guardDefinition(guard, subscriptions)
  return {
    guard = guard,
    subscriptions = subscriptions or {},
  }
end

function M.guardKey(guard, subscriptions)
  return hashId('guard-def', M.guardDefinition(guard, subscriptions), 'guardDefinition')
end

function M.actionDefinition(action)
  local selection = action.selection
  if selection and selection.query ~= nil then
    local stable = {}
    for key, value in pairs(selection) do if key ~= 'queryRecords' then stable[key] = value end end
    selection = stable
  end
  return {
    family = action.family,
    familyAbiVersion = action.familyAbiVersion,
    behaviorVersion = action.behaviorVersion,
    programVersion = action.programVersion,
    revertTokenVersion = action.revertTokenVersion,
    lifecycle = action.lifecycle,
    scope = action.scope,
    guardKey = action.guardKey,
    program = action.program,
    selection = selection,
    claims = action.claims,
    priority = action.priority,
    specificity = action.specificity,
    chance = action.chance,
    reversible = action.reversible,
    parentId = action.parentId,
    previsit = action.previsit,
  }
end

function M.actionId(action)
  local family = tostring(action and action.family or 'action')
  return hashId('action:' .. family, M.actionDefinition(action), 'actionDefinition')
end

function M.ownerDefinition(owner)
  return M.guardDefinition(owner.guard, owner.subscriptions)
end

function M.ownerId(owner)
  return hashId('owner', M.ownerDefinition(owner), 'ownerDefinition')
end

return M
