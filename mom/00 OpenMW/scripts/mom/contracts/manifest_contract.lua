-- Strict process-local contract for the final pure runtime manifest.
local M = {}

local canonical = require('scripts.mom.contracts.canonical')
local claim_contract = require('scripts.mom.contracts.claim_contract')
local plain_data = require('scripts.mom.contracts.plain_data')
local plan_identity = require('scripts.mom.contracts.plan_identity')

local TOP_FIELDS = {
  contentHash = true,
  extensions = true,
  actionsById = true,
  actionIds = true,
  ownersById = true,
  ownerIds = true,
  indexes = true,
}

local CLAIM_FIELDS = {
  keys = true,
  conflict = true,
}

local ACTION_FIELDS = {
  id = true,
  family = true,
  familyAbiVersion = true,
  behaviorVersion = true,
  programVersion = true,
  revertTokenVersion = true,
  lifecycle = true,
  scope = true,
  ownerId = true,
  guardKey = true,
  program = true,
  selection = true,
  claims = true,
  priority = true,
  specificity = true,
  order = true,
  chance = true,
  reversible = true,
  parentId = true,
  childIds = true,
  sourceRef = true,
  previsit = true,
}

local OWNER_FIELDS = {
  id = true,
  guard = true,
  actionIds = true,
  subscriptions = true,
}

local INDEX_FIELDS = {
  staticByCell = true,
  ownersByCell = true,
  ownersByEvent = true,
  exactObjectActive = true,
  previsitCells = true,
}

local function append(errors, path, message)
  errors[#errors + 1] = tostring(path) .. ': ' .. tostring(message)
end

local function allowedFields(errors, value, allowed, path)
  for key in pairs(value or {}) do
    if not allowed[key] then append(errors, path .. '.' .. tostring(key), 'field is not allowed') end
  end
end

local function requireType(errors, value, expected, path)
  if type(value) ~= expected then
    append(errors, path, 'expected ' .. expected .. ', got ' .. type(value))
    return false
  end
  return true
end

local function requireString(errors, value, path)
  if not requireType(errors, value, 'string', path) then return false end
  if value == '' then append(errors, path, 'must be non-empty') return false end
  return true
end

local function requireInteger(errors, value, path)
  if type(value) ~= 'number' or value % 1 ~= 0 then
    append(errors, path, 'expected integer')
    return false
  end
  return true
end

local function validateStringArray(errors, values, path)
  if not requireType(errors, values, 'table', path) then return end
  local seen = {}
  for i = 1, #values do
    local value = values[i]
    if requireString(errors, value, path .. '[' .. tostring(i) .. ']') then
      if seen[value] then
        append(errors, path .. '[' .. tostring(i) .. ']', 'duplicate value ' .. tostring(value))
      end
      seen[value] = true
    end
  end
end

local function semanticManifest(manifest)
  local out = {
    extensions = {
      actions = manifest.extensions and manifest.extensions.actions or {},
      guards = manifest.extensions and manifest.extensions.guards or {},
    },
    actionsById = {},
    actionIds = manifest.actionIds,
    ownersById = manifest.ownersById,
    ownerIds = manifest.ownerIds,
    indexes = manifest.indexes,
  }
  for id, action in pairs(manifest.actionsById or {}) do
    local semantic = {}
    for key, value in pairs(action) do
      if key ~= 'sourceRef' then semantic[key] = value end
    end
    out.actionsById[id] = semantic
  end
  return out
end

function M.contentHash(manifest)
  return canonical.assertHash(semanticManifest(manifest), {path = 'manifest'})
end

local function validateExtensions(errors, extensions)
  if not requireType(errors, extensions, 'table', 'extensions') then return end
  for kind, entries in pairs(extensions) do
    local path = 'extensions.' .. tostring(kind)
    if requireType(errors, entries, 'table', path) then
      for id, entry in pairs(entries) do
        local entryPath = path .. '.' .. tostring(id)
        requireString(errors, id, entryPath .. '.id')
        if requireType(errors, entry, 'table', entryPath) then
          if not requireInteger(errors, entry.abiVersion, entryPath .. '.abiVersion') then
            -- Diagnostic already appended.
          end
          requireInteger(errors, entry.behaviorVersion, entryPath .. '.behaviorVersion')
          if entry.programVersion ~= nil then
            requireInteger(errors, entry.programVersion, entryPath .. '.programVersion')
          end
          if entry.storageVersion ~= nil then
            requireInteger(errors, entry.storageVersion, entryPath .. '.storageVersion')
          end
          if entry.revertTokenVersion ~= nil then
            requireInteger(errors, entry.revertTokenVersion,
              entryPath .. '.revertTokenVersion')
          end
        end
      end
    end
  end
end

local function validateAction(errors, action, id, manifest)
  local path = 'actionsById.' .. tostring(id)
  if not requireType(errors, action, 'table', path) then return end
  allowedFields(errors, action, ACTION_FIELDS, path)
  if action.id ~= id then append(errors, path .. '.id', 'must match map key') end
  requireString(errors, action.id, path .. '.id')
  requireString(errors, action.family, path .. '.family')
  requireInteger(errors, action.familyAbiVersion, path .. '.familyAbiVersion')
  requireInteger(errors, action.behaviorVersion, path .. '.behaviorVersion')
  requireInteger(errors, action.programVersion, path .. '.programVersion')
  if action.revertTokenVersion ~= nil then
    requireInteger(errors, action.revertTokenVersion,
      path .. '.revertTokenVersion')
  end
  if action.lifecycle ~= 'static' and action.lifecycle ~= 'state' then
    append(errors, path .. '.lifecycle', 'expected static or state')
  end
  if action.scope ~= 'cell' and action.scope ~= 'ref' and action.scope ~= 'dynamic' then
    append(errors, path .. '.scope', 'expected cell, ref, or dynamic')
  end
  if action.lifecycle == 'state' then
    requireString(errors, action.ownerId, path .. '.ownerId')
    requireString(errors, action.guardKey, path .. '.guardKey')
  elseif action.ownerId ~= nil then
    append(errors, path .. '.ownerId', 'static action must not have an owner')
  elseif action.guardKey ~= nil then
    append(errors, path .. '.guardKey', 'static action must not have a guard key')
  end
  requireType(errors, action.program, 'table', path .. '.program')
  requireType(errors, action.selection, 'table', path .. '.selection')
  if requireType(errors, action.claims, 'table', path .. '.claims') then
    allowedFields(errors, action.claims, CLAIM_FIELDS, path .. '.claims')
    local _, claimErrors = claim_contract.normalize(
      action.claims.keys,
      action.family,
      path .. '.claims.keys',
      {nonEmpty = true, sorted = true}
    )
    for i = 1, #(claimErrors or {}) do errors[#errors + 1] = claimErrors[i] end
  end
  requireInteger(errors, action.priority, path .. '.priority')
  requireType(errors, action.specificity, 'number', path .. '.specificity')
  requireInteger(errors, action.order, path .. '.order')
  if type(action.chance) ~= 'number' or action.chance < 0 or action.chance > 1 then
    append(errors, path .. '.chance', 'expected number in [0, 1]')
  end
  requireType(errors, action.reversible, 'boolean', path .. '.reversible')
  if action.parentId ~= nil then requireString(errors, action.parentId, path .. '.parentId') end
  validateStringArray(errors, action.childIds, path .. '.childIds')
  requireString(errors, action.sourceRef, path .. '.sourceRef')
  requireType(errors, action.previsit, 'boolean', path .. '.previsit')
  local extension = manifest.extensions and manifest.extensions.actions
    and manifest.extensions.actions[action.family] or nil
  if not extension then
    append(errors, path .. '.family', 'action extension is not declared')
  else
    if extension.abiVersion ~= action.familyAbiVersion then
      append(errors, path .. '.familyAbiVersion', 'does not match action extension ABI')
    end
    if extension.behaviorVersion ~= action.behaviorVersion then
      append(errors, path .. '.behaviorVersion',
        'does not match action extension behavior')
    end
    if extension.programVersion ~= nil and extension.programVersion ~= action.programVersion then
      append(errors, path .. '.programVersion', 'does not match action extension program version')
    end
    if extension.revertTokenVersion ~= action.revertTokenVersion then
      append(errors, path .. '.revertTokenVersion',
        'does not match action extension revert-token version')
    end
  end
  if type(action.id) == 'string'
      and action.id ~= plan_identity.actionId(action) then
    append(errors, path .. '.id', 'does not match semantic action content')
  end
end

local function validateGuard(errors, guard, path, manifest)
  if not requireType(errors, guard, 'table', path) then return end
  if guard.op == 'always' then return end
  if guard.op ~= 'all' then
    append(errors, path .. '.op', 'expected always or all')
    return
  end
  if not requireType(errors, guard.fragments, 'table', path .. '.fragments') then return end
  if #guard.fragments == 0 then append(errors, path .. '.fragments', 'must not be empty') end
  for i = 1, #guard.fragments do
    local fragment = guard.fragments[i]
    local fragmentPath = path .. '.fragments[' .. tostring(i) .. ']'
    if requireType(errors, fragment, 'table', fragmentPath) then
      requireString(errors, fragment.family, fragmentPath .. '.family')
      requireInteger(errors, fragment.abiVersion, fragmentPath .. '.abiVersion')
      requireInteger(errors, fragment.behaviorVersion, fragmentPath .. '.behaviorVersion')
      requireInteger(errors, fragment.programVersion, fragmentPath .. '.programVersion')
      requireType(errors, fragment.program, 'table', fragmentPath .. '.program')
      local extension = manifest.extensions and manifest.extensions.guards
        and manifest.extensions.guards[fragment.family] or nil
      if not extension then
        append(errors, fragmentPath .. '.family', 'guard extension is not declared')
      else
        if extension.abiVersion ~= fragment.abiVersion then
          append(errors, fragmentPath .. '.abiVersion', 'does not match guard extension ABI')
        end
        if extension.behaviorVersion ~= fragment.behaviorVersion then
          append(errors, fragmentPath .. '.behaviorVersion',
            'does not match guard extension behavior')
        end
        if extension.programVersion ~= nil and extension.programVersion ~= fragment.programVersion then
          append(errors, fragmentPath .. '.programVersion', 'does not match guard extension program version')
        end
      end
    end
  end
end

local function validateOwner(errors, owner, id, manifest)
  local path = 'ownersById.' .. tostring(id)
  if not requireType(errors, owner, 'table', path) then return end
  allowedFields(errors, owner, OWNER_FIELDS, path)
  if owner.id ~= id then append(errors, path .. '.id', 'must match map key') end
  requireString(errors, owner.id, path .. '.id')
  validateGuard(errors, owner.guard, path .. '.guard', manifest)
  validateStringArray(errors, owner.actionIds, path .. '.actionIds')
  validateStringArray(errors, owner.subscriptions, path .. '.subscriptions')
  if type(owner.id) == 'string'
      and owner.id ~= plan_identity.ownerId(owner) then
    append(errors, path .. '.id', 'does not match semantic owner content')
  end
end

local function validateIdIndex(errors, ids, byId, path)
  validateStringArray(errors, ids, path)
  local listed = {}
  for i = 1, #(ids or {}) do
    local id = ids[i]
    listed[id] = true
    if not byId[id] then append(errors, path .. '[' .. tostring(i) .. ']', 'missing map entry') end
  end
  for id in pairs(byId or {}) do
    if not listed[id] then append(errors, path, 'map entry ' .. tostring(id) .. ' is not listed') end
  end
end

local function validateActionLinks(errors, manifest)
  for id, action in pairs(manifest.actionsById or {}) do
    if action.parentId ~= nil then
      local parent = manifest.actionsById[action.parentId]
      if not parent then
        append(errors, 'actionsById.' .. id .. '.parentId', 'missing parent action')
      end
    end
    for i = 1, #(action.childIds or {}) do
      local childId = action.childIds[i]
      local child = manifest.actionsById[childId]
      if not child then
        append(errors, 'actionsById.' .. id .. '.childIds[' .. tostring(i) .. ']', 'missing child action')
      elseif child.parentId ~= id then
        append(errors, 'actionsById.' .. id .. '.childIds[' .. tostring(i) .. ']',
          'child parentId does not point back to parent')
      elseif child.lifecycle ~= action.lifecycle then
        append(errors, 'actionsById.' .. id .. '.childIds[' .. tostring(i) .. ']',
          'parent and child lifecycle must match')
      end
    end
  end

  -- Parent links form a forest once the reciprocal-link checks above pass.
  -- Walk those links iteratively so validation remains safe for very deep
  -- authored action DAGs.
  local visited = {}
  for id in pairs(manifest.actionsById or {}) do
    if not visited[id] then
      local path = {}
      local positions = {}
      local currentId = id
      while currentId ~= nil and not visited[currentId] do
        if positions[currentId] then
          append(
            errors,
            'actionsById.' .. tostring(currentId),
            'parent/child graph contains a cycle'
          )
          break
        end
        positions[currentId] = true
        path[#path + 1] = currentId
        local action = manifest.actionsById[currentId]
        currentId = action and action.parentId or nil
      end
      for i = 1, #path do visited[path[i]] = true end
    end
  end
end

local function validateOwnerLinks(errors, manifest)
  local actionOwner = {}
  for ownerId, owner in pairs(manifest.ownersById or {}) do
    local guardKeyOk, expectedGuardKey = pcall(
      plan_identity.guardKey,
      owner.guard,
      owner.subscriptions
    )
    for i = 1, #(owner.actionIds or {}) do
      local actionId = owner.actionIds[i]
      local action = manifest.actionsById[actionId]
      if not action then
        append(errors, 'ownersById.' .. ownerId .. '.actionIds[' .. tostring(i) .. ']', 'missing action')
      elseif action.ownerId ~= ownerId then
        append(errors, 'ownersById.' .. ownerId .. '.actionIds[' .. tostring(i) .. ']',
          'action ownerId does not match')
      elseif action.lifecycle ~= 'state' then
        append(errors, 'ownersById.' .. ownerId .. '.actionIds[' .. tostring(i) .. ']',
          'owner may only list state actions')
      elseif guardKeyOk and action.guardKey ~= expectedGuardKey then
        append(errors, 'actionsById.' .. actionId .. '.guardKey',
          'does not match its owner guard definition')
      end
      if actionOwner[actionId] and actionOwner[actionId] ~= ownerId then
        append(errors, 'ownersById.' .. ownerId .. '.actionIds[' .. tostring(i) .. ']',
          'action is already owned by ' .. tostring(actionOwner[actionId]))
      end
      actionOwner[actionId] = ownerId
    end
  end
  for actionId, action in pairs(manifest.actionsById or {}) do
    if action.lifecycle == 'state' and actionOwner[actionId] ~= action.ownerId then
      append(errors, 'actionsById.' .. actionId .. '.ownerId', 'owner does not list state action')
    end
  end
end

local function validateIndexes(errors, manifest)
  local indexes = manifest.indexes
  if not requireType(errors, indexes, 'table', 'indexes') then return end
  allowedFields(errors, indexes, INDEX_FIELDS, 'indexes')
  for field in pairs(INDEX_FIELDS) do
    requireType(errors, indexes[field], 'table', 'indexes.' .. field)
  end
  for routeKey, actionIds in pairs(indexes.staticByCell or {}) do
    local path = 'indexes.staticByCell.' .. tostring(routeKey)
    requireString(errors, routeKey, path .. '.routeKey')
    validateStringArray(errors, actionIds, path)
    for i = 1, #actionIds do
      local action = manifest.actionsById[actionIds[i]]
      if not action then
        append(errors, path .. '[' .. tostring(i) .. ']', 'missing action')
      elseif action.lifecycle ~= 'static' then
        append(errors, path .. '[' .. tostring(i) .. ']', 'index may only contain static actions')
      end
    end
  end
  for eventName, ownerIds in pairs(indexes.ownersByEvent or {}) do
    local path = 'indexes.ownersByEvent.' .. tostring(eventName)
    validateStringArray(errors, ownerIds, path)
    for i = 1, #ownerIds do
      local owner = manifest.ownersById[ownerIds[i]]
      if not owner then
        append(errors, path .. '[' .. tostring(i) .. ']', 'missing owner')
      else
        local subscribed = false
        for j = 1, #(owner.subscriptions or {}) do
          if owner.subscriptions[j] == eventName then subscribed = true break end
        end
        if not subscribed then
          append(errors, path .. '[' .. tostring(i) .. ']', 'owner does not subscribe to event')
        end
      end
    end
  end
end

local function validate(manifest, verifyContentHash)
  local errors = {}
  local plain, plainErrors = plain_data.validate(manifest, {path = 'manifest'})
  if not plain then return nil, plainErrors end
  if not requireType(errors, manifest, 'table', 'manifest') then return nil, errors end
  allowedFields(errors, manifest, TOP_FIELDS, 'manifest')
  requireString(errors, manifest.contentHash, 'contentHash')
  validateExtensions(errors, manifest.extensions)
  requireType(errors, manifest.actionsById, 'table', 'actionsById')
  requireType(errors, manifest.ownersById, 'table', 'ownersById')
  validateIdIndex(errors, manifest.actionIds, manifest.actionsById or {}, 'actionIds')
  validateIdIndex(errors, manifest.ownerIds, manifest.ownersById or {}, 'ownerIds')
  for id, action in pairs(manifest.actionsById or {}) do validateAction(errors, action, id, manifest) end
  for id, owner in pairs(manifest.ownersById or {}) do validateOwner(errors, owner, id, manifest) end
  validateActionLinks(errors, manifest)
  validateOwnerLinks(errors, manifest)
  validateIndexes(errors, manifest)
  if verifyContentHash
      and type(manifest.contentHash) == 'string'
      and manifest.contentHash ~= M.contentHash(manifest) then
    append(errors, 'contentHash', 'does not match canonical manifest content')
  end
  if #errors > 0 then return nil, errors end
  return true, nil
end

function M.validate(manifest)
  return validate(manifest, true)
end

-- Compiler assembly has just calculated contentHash from the owned graph.
-- Re-run the structural/link checks without rebuilding and hashing the same
-- semantic projection a second time.
function M.validateCompiled(manifest)
  return validate(manifest, false)
end

return M
