-- Compiles normalized source IR into the runtime manifest's action and owner
-- records, extension versions, and event indexes.
local M = {}

local compile_policy = require('scripts.mom.compiler.compile_policy')
local extension_registry = require('scripts.mom.compiler.extension_registry')
local guard_program = require('scripts.mom.compiler.guard_program')
local manifest_assembler = require('scripts.mom.compiler.manifest_assembler')
local plain_data = require('scripts.mom.contracts.plain_data')
local plan_identity = require('scripts.mom.contracts.plan_identity')
local selection_plan = require('scripts.mom.compiler.selection_plan')
local spec_key = require('scripts.mom.compiler.spec_key')

local function copy(value, path)
  if value == nil then return nil end
  local out, errors = plain_data.detach(value, {path = path})
  if out ~= nil then return out end
  return nil, errors
end

local function appendError(prefix, errors)
  local out = {}
  for i = 1, #(errors or {}) do out[i] = tostring(prefix) .. tostring(errors[i]) end
  return out
end

local function hasValues(value)
  return type(value) == 'table' and next(value) ~= nil
end

local function requireRegistry(registry, kind, field)
  local path = 'sourceManifest.options.' .. tostring(field)
  if type(registry) ~= 'table' then
    return nil, {path .. ': expected explicit ' .. tostring(kind) .. ' registry'}
  end
  if registry.kind ~= kind then
    return nil, {path .. '.kind: expected ' .. tostring(kind) .. ', got ' .. tostring(registry.kind)}
  end
  if type(registry.ids) ~= 'table' or type(registry.byId) ~= 'table' then
    return nil, {path .. ': registry must expose ids and byId tables'}
  end
  return registry, nil
end

local function resolveBehavior(entry, node)
  local mod = entry and entry.module or nil
  local behavior
  if mod and type(mod.resolveBehavior) == 'function' then
    local ok, resolved = pcall(mod.resolveBehavior, {program = node.program})
    if not ok then
      return nil, {'action:' .. tostring(node.id) .. ': behavior resolution failed: ' .. tostring(resolved)}
    end
    behavior = resolved
  else
    behavior = mod and mod.behavior or nil
  end
  local detached, errors = copy(behavior or {}, 'action:' .. tostring(node.id) .. '.behavior')
  if not detached then return nil, errors end
  return detached, nil
end

local function resolveScope(node, behavior, effectiveSelect)
  local scope = behavior.scope or 'ref'
  if scope ~= 'dynamic' then return scope end
  if effectiveSelect and effectiveSelect.recordId ~= nil then return 'ref' end
  if hasValues(node.candidateTypes) then return 'ref' end
  return 'cell'
end

local function mergeInheritedSelect(node, parentInfo, allowInheritedTargets, behavior)
  local effective = node.select
  local parentSelect = parentInfo and parentInfo.selectSpec or nil
  if not allowInheritedTargets or behavior.inheritParentCell == false
      or type(parentSelect) ~= 'table' or parentSelect.cell == nil then
    return effective
  end
  effective = effective or {}
  if effective.cell == nil then effective.cell = parentSelect.cell end
  return effective
end

local function validateChildContract(node, behavior, parentInfo)
  if parentInfo and behavior.canBeChildAction ~= true then
    return {'action:' .. tostring(node.id) .. ': family ' .. tostring(node.family) .. ' cannot be a child action'}
  end
  if parentInfo and not compile_policy.acceptsParentTargetKind(behavior, parentInfo.childTargetKind) then
    return {'action:' .. tostring(node.id) .. ': family ' .. tostring(node.family)
      .. ' cannot inherit parent target kind ' .. tostring(parentInfo.childTargetKind)}
  end
  if #(node.children or {}) > 0 and behavior.canHaveChildActions ~= true then
    return {'action:' .. tostring(node.id) .. ': family ' .. tostring(node.family) .. ' cannot own child actions'}
  end
  if #(node.children or {}) > 0 and type(behavior.childTargetKind) ~= 'string' then
    return {'action:' .. tostring(node.id) .. ': child-producing family must declare childTargetKind'}
  end
  return nil
end

local function normalizePriority(node)
  local value = node.priority
  if value == nil then return 0, nil end
  if type(value) ~= 'number' or value % 1 ~= 0 then
    return nil, {'action:' .. tostring(node.id) .. '.priority: expected integer'}
  end
  return value, nil
end

local function normalizeChance(node)
  local value = node.chance
  if value == nil then return 1, nil end
  if type(value) ~= 'number' or value < 0 or value > 1 then
    return nil, {'action:' .. tostring(node.id) .. '.chance: expected number in [0, 1]'}
  end
  return value, nil
end

local function normalizeConflict(node)
  local conflict = node.conflict
  if conflict == nil then return nil, nil end
  if type(conflict) ~= 'table' or type(conflict.group) ~= 'string' or conflict.group == '' then
    return nil, {'action:' .. tostring(node.id) .. '.conflict: expected object with non-empty group'}
  end
  local mode = conflict.mode or 'exclusive'
  if mode ~= 'exclusive' and mode ~= 'durable-exclusive' then
    return nil, {'action:' .. tostring(node.id) .. '.conflict.mode: unsupported value ' .. tostring(mode)}
  end
  if conflict.groupBy ~= nil and conflict.groupBy ~= 'record_id' then
    return nil, {'action:' .. tostring(node.id) .. '.conflict.groupBy: unsupported value '
      .. tostring(conflict.groupBy)}
  end
  for key, value in pairs(conflict.familySignatures or {}) do
    if type(key) ~= 'string' or key == '' or type(value) ~= 'string' or value == '' then
      return nil, {'action:' .. tostring(node.id)
        .. '.conflict.familySignatures: expected non-empty string keys and values'}
    end
  end
  return {
    group = conflict.group,
    mode = mode,
    groupBy = conflict.groupBy,
    familySignatures = conflict.familySignatures,
  }, nil
end

local function validateConflictPolicy(node, conflict, lifecycle, scope, reversible)
  if conflict == nil then return nil end
  if conflict.mode == 'exclusive' then
    if lifecycle == 'static' or (lifecycle == 'state' and scope == 'ref' and reversible) then return nil end
  elseif conflict.mode == 'durable-exclusive' then
    if (lifecycle == 'state' and scope == 'ref' and not reversible)
        or (lifecycle == 'static' and scope == 'ref') then return nil end
  end
  return {'action:' .. tostring(node.id) .. '.conflict: mode ' .. tostring(conflict.mode)
    .. ' is incompatible with lifecycle=' .. tostring(lifecycle)
    .. ', scope=' .. tostring(scope) .. ', reversible=' .. tostring(reversible)}
end

local function consumeFamilyProgram(node)
  if type(node.program) ~= 'table' or type(node.claims) ~= 'table'
      or type(node.reversible) ~= 'boolean' then
    return nil, {'action:' .. tostring(node.id)
      .. ': expected final program, claims, and reversible fields'}
  end
  return {
    program = node.program,
    claims = node.claims,
    reversible = node.reversible,
  }, nil
end

local function ensureOwner(state, ownerSpec)
  local diagnosticId = ownerSpec and ownerSpec.id or nil
  if type(diagnosticId) ~= 'string' or diagnosticId == '' then
    return nil, {'guard owner id must be a non-empty string'}
  end
  local sourceSpecKey = spec_key.fromSpec(ownerSpec.when)
  local existingSourceOwner = state.ownerStatesBySourceSpec[sourceSpecKey]
  if existingSourceOwner ~= nil then return existingSourceOwner, nil end
  local guard, subscriptions, errors = guard_program.compile(
    ownerSpec.when,
    diagnosticId,
    state.guardRegistry
  )
  if not guard then return nil, errors end
  for i = 1, #(guard.fragments or {}) do state.usedGuards[guard.fragments[i].family] = true end
  local guardKey = plan_identity.guardKey(guard, subscriptions)
  local existing = state.ownerStates[guardKey]
  if existing then
    state.ownerStatesBySourceSpec[sourceSpecKey] = existing
    return existing, nil
  end
  local created = {
    guardKey = guardKey,
    actionIds = {},
    record = {
      guard = guard,
      actionIds = {},
      subscriptions = subscriptions,
    },
  }
  created.record.id = plan_identity.ownerId(created.record)
  state.ownerStates[guardKey] = created
  state.ownerStatesBySourceSpec[sourceSpecKey] = created
  state.owners[#state.owners + 1] = created.record
  return created, nil
end

local function appendUnique(out, seen, value)
  if value == nil or seen[value] then return end
  seen[value] = true
  out[#out + 1] = value
end

local function collectRouteKeys(route, out, seen)
  if route == nil then appendUnique(out, seen, 'shared') return end
  if route.kind == 'union' then
    for i = 1, #(route.routes or {}) do collectRouteKeys(route.routes[i], out, seen) end
    return
  end
  if route.kind == 'exact' then
    for i = 1, #(route.interiorKeys or {}) do
      appendUnique(out, seen, 'interior:' .. tostring(route.interiorKeys[i]))
    end
    for i = 1, #(route.exteriors or {}) do
      local group = route.exteriors[i]
      for j = 1, #(group.packedCellKeys or {}) do
        appendUnique(out, seen, string.format('exterior:%s:%s',
          tostring(group.worldspaceKey), tostring(group.packedCellKeys[j])))
      end
    end
    return
  end
  if route.kind == 'region' then
    for i = 1, #(route.worldspaces or {}) do
      local group = route.worldspaces[i]
      for j = 1, #(group.regionKeys or {}) do
        appendUnique(out, seen, string.format('region:%s:%s',
          tostring(group.worldspaceKey), tostring(group.regionKeys[j])))
      end
    end
    return
  end
  if route.kind == 'worldspace' then
    for i = 1, #(route.worldspaceKeys or {}) do
      appendUnique(out, seen, 'worldspace:' .. tostring(route.worldspaceKeys[i]))
    end
    return
  end
  if route.kind == 'footprint' then
    for i = 1, #(route.exteriors or {}) do
      appendUnique(out, seen, string.format('footprint:%s:%s',
        tostring(route.exteriors[i].worldspaceKey), tostring(route.key)))
    end
    return
  end
  appendUnique(out, seen, 'shared')
end

local function selectionRouteKeys(selection)
  local out = {}
  local seen = {}
  collectRouteKeys(selection and selection.cell and selection.cell.route or nil, out, seen)
  -- Some actions query a second concrete cell in addition to their source
  -- selector (for example, modify_ref relocation recovery). Destination
  -- observation must wake the same owner or interrupted work can remain
  -- dormant after the source cell unloads.
  for i = 1, #(selection and selection.queryCells or {}) do
    local cell = selection.queryCells[i]
    if type(cell) == 'table' then
      if cell.isExterior == true and cell.worldspaceKey ~= nil
          and cell.packedCellKey ~= nil then
        appendUnique(out, seen, string.format(
          'exterior:%s:%s',
          tostring(cell.worldspaceKey),
          tostring(cell.packedCellKey)
        ))
      else
        local key = cell.interiorKey or cell.key or cell.id
        if key ~= nil then
          appendUnique(out, seen, 'interior:' .. tostring(key):lower())
        end
      end
    end
  end
  if #out == 0 then out[1] = 'shared' end
  table.sort(out)
  return out
end

local function appendIndex(index, key, id)
  local bucket = index[key]
  if not bucket then
    bucket = {}
    index[key] = bucket
  end
  bucket[id] = true
end

local function appendActionIndexes(state, action, previsitEntries)
  local routeKeys = selectionRouteKeys(action.selection)
  if action.lifecycle == 'static' then
    for i = 1, #routeKeys do appendIndex(state.indexSets.staticByCell, routeKeys[i], action.id) end
  else
    for i = 1, #routeKeys do
      appendIndex(state.indexSets.ownersByCell, routeKeys[i], action.ownerId)
    end
    if action.scope == 'ref' then
      for i = 1, #(action.selection.exactIds or {}) do
        appendIndex(state.indexSets.exactObjectActive, action.selection.exactIds[i], action.id)
      end
      for _, row in ipairs(action.selection.queryRecords or {}) do
        appendIndex(state.indexSets.exactObjectActive, row.recordId, action.id)
      end
    end
  end
  for i = 1, #(previsitEntries or {}) do
    local entry = previsitEntries[i]
    local key = string.format('exterior:%s:%s', tostring(entry.worldspaceKey), tostring(entry.packedCellKey))
    appendIndex(state.indexSets.previsitCells, key, action.id)
  end
end

local function appendOwnerAction(ownerState, action)
  if ownerState.actionIds[action.id] then return end
  ownerState.actionIds[action.id] = true
  ownerState.record.actionIds[#ownerState.record.actionIds + 1] = action.id
end

local compileNode

---@return 'ok'|'skip'|'error' status
---@return table|nil action
---@return string[]|nil errors
compileNode = function(node, state, parentInfo)
  local entry = state.actionRegistry.byId[node.family]
  if not entry then return 'error', nil, {'action:' .. tostring(node.id) .. ': unknown action family ' .. tostring(node.family)} end
  state.usedActions[node.family] = true
  local adapterId = node.source and node.source.adapterId or nil
  if adapterId and adapterId ~= 'native' and adapterId ~= 'unknown' then state.usedCompat[adapterId] = true end

  local behavior, behaviorErrors = resolveBehavior(entry, node)
  if not behavior then return 'error', nil, behaviorErrors end
  local childErrors = validateChildContract(node, behavior, parentInfo)
  if childErrors then return 'error', nil, childErrors end
  local allowInheritedTargets = parentInfo ~= nil
    and compile_policy.acceptsParentTargetKind(behavior, parentInfo.childTargetKind)
  local effectiveSelect = mergeInheritedSelect(
    node,
    parentInfo,
    allowInheritedTargets,
    behavior
  )
  local scope = resolveScope(node, behavior, effectiveSelect)

  local ownerState = parentInfo and parentInfo.ownerState or nil
  if node.guardOwner ~= nil then
    if ownerState ~= nil then
      return 'error', nil, {'action:' .. tostring(node.id) .. ': child action cannot declare another guard owner'}
    end
    local ownerErrors
    ownerState, ownerErrors = ensureOwner(state, node.guardOwner)
    if not ownerState then return 'error', nil, ownerErrors end
  end
  local lifecycle = ownerState and 'state' or 'static'

  local selectionStatus, selection, selectionErrors, selectionFacts = selection_plan.compile(
    node,
    effectiveSelect,
    state.compileCtx,
    {
      scope = scope,
      requireExplicitCellSelection = not allowInheritedTargets
        and behavior.requiresExplicitCellSelection == true,
      allowInheritedTargets = allowInheritedTargets,
    }
  )
  node.resolvedSelection = nil
  if selectionStatus ~= 'ok' then return selectionStatus, nil, selectionErrors end

  local compiledProgram, familyErrors = consumeFamilyProgram(node)
  if not compiledProgram then return 'error', nil, familyErrors end
  for _, key in ipairs(compiledProgram.claims.keys or {}) do
    if key == 'ref.position' then
      if type(entry.module.recoveryLocations) ~= 'function'
          or type(entry.module.capture) ~= 'function' then
        return 'error', nil, {'action:' .. tostring(node.id)
          .. ': ref.position requires capture and recoveryLocations hooks'}
      end
      break
    end
  end
  local priority, priorityErrors = normalizePriority(node)
  if priority == nil then return 'error', nil, priorityErrors end
  local chance, chanceErrors = normalizeChance(node)
  if chance == nil then return 'error', nil, chanceErrors end
  if chance ~= 1 and scope ~= 'ref' then
    return 'error', nil, {'action:' .. tostring(node.id) .. '.chance: only ref-scoped actions support chance'}
  end
  local conflict, conflictErrors = normalizeConflict(node)
  if conflictErrors then return 'error', nil, conflictErrors end
  if conflict ~= nil then compiledProgram.claims.conflict = conflict end
  local conflictPolicyErrors = validateConflictPolicy(
    node,
    conflict,
    lifecycle,
    scope,
    compiledProgram.reversible
  )
  if conflictPolicyErrors then return 'error', nil, conflictPolicyErrors end

  local previsit, previsitEntries = compile_policy.extractPrevisitEntries(
    {previsit = node.previsit},
    selectionFacts,
    node.id,
    lifecycle
  )
  local action = {
    family = node.family,
    familyAbiVersion = entry.abiVersion,
    behaviorVersion = entry.behaviorVersion,
    programVersion = entry.programVersion,
    revertTokenVersion = entry.revertTokenVersion,
    lifecycle = lifecycle,
    scope = scope,
    guardKey = ownerState and ownerState.guardKey or nil,
    ownerId = ownerState and ownerState.record.id or nil,
    program = compiledProgram.program,
    selection = selection,
    claims = compiledProgram.claims,
    priority = priority,
    specificity = selectionFacts.specificity,
    order = 0,
    chance = chance,
    reversible = compiledProgram.reversible,
    parentId = parentInfo and parentInfo.id or nil,
    childIds = {},
    sourceRef = node.sourceRef,
    previsit = previsit == true,
  }
  action.id = plan_identity.actionId(action)
  state.actions[#state.actions + 1] = action
  if ownerState then appendOwnerAction(ownerState, action) end
  appendActionIndexes(state, action, previsitEntries)

  local childParent = {
    id = action.id,
    selectSpec = effectiveSelect,
    childTargetKind = behavior.childTargetKind,
    ownerState = ownerState,
  }
  for i = 1, #(node.children or {}) do
    local childStatus, child, errors = compileNode(node.children[i], state, childParent)
    if childStatus == 'error' then return 'error', nil, errors end
    if childStatus ~= 'skip' then
      action.childIds[#action.childIds + 1] = child.id
    end
  end
  return 'ok', action, nil
end

local function sortedIndex(indexSets)
  local out = {}
  for key, set in pairs(indexSets or {}) do
    local ids = {}
    for key in pairs(set) do
      ids[#ids + 1] = key
    end
    table.sort(ids)
    out[key] = ids
  end
  return out
end

local function describeUsed(registry, used, kind, allowUnavailable)
  local described = extension_registry.describe(registry, used)
  local out = {}
  for id in pairs(used or {}) do
    if not (registry and registry.byId and registry.byId[id]) then
      if not allowUnavailable then
        return nil, {tostring(kind) .. ' extension ' .. tostring(id) .. ' is not registered'}
      end
    else
      out[id] = described[id]
    end
  end
  return out, nil
end

local function buildExtensions(state)
  local actions, actionErrors = describeUsed(state.actionRegistry, state.usedActions, 'action')
  if not actions then return nil, actionErrors end
  local guards, guardErrors = describeUsed(state.guardRegistry, state.usedGuards, 'guard')
  if not guards then return nil, guardErrors end
  local compat = {}
  if next(state.usedCompat) ~= nil then
    local compatRegistry, registryErrors = requireRegistry(
      state.compatRegistry,
      'compat',
      'compatRegistry'
    )
    if not compatRegistry then return nil, registryErrors end
    local compatErrors
    compat, compatErrors = describeUsed(
      compatRegistry,
      state.usedCompat,
      'compat',
      true
    )
    if not compat then return nil, compatErrors end
  end
  return {compat = compat, actions = actions, guards = guards}, nil
end

local function activeOwners(state)
  local out = {}
  for i = 1, #state.owners do
    if #(state.owners[i].actionIds or {}) > 0 then out[#out + 1] = state.owners[i] end
  end
  return out
end

local function compileSeed(normalizedIr, compileCtx, catalog)
  if type(normalizedIr) ~= 'table' or type(normalizedIr.actions) ~= 'table' then
    return nil, {'normalized source IR must contain actions'}
  end
  if type(compileCtx) ~= 'table' then
    return nil, {'sourceManifest.compileCtx: expected table'}
  end
  if type(catalog) ~= 'table' then
    return nil, {'extension catalog: expected mom-extension-catalog'}
  end
  local actionRegistry, actionRegistryErrors = requireRegistry(
    catalog.actions, 'action', 'catalog.actions')
  if not actionRegistry then return nil, actionRegistryErrors end
  local guardRegistry, guardRegistryErrors = requireRegistry(
    catalog.guards, 'guard', 'catalog.guards'
  )
  if not guardRegistry then return nil, guardRegistryErrors end
  local state = {
    compileCtx = compileCtx,
    actionRegistry = actionRegistry,
    guardRegistry = guardRegistry,
    compatRegistry = catalog.compat,
    actions = {},
    owners = {},
    ownerStates = {},
    ownerStatesBySourceSpec = {},
    usedActions = {},
    usedGuards = {},
    usedCompat = {},
    indexSets = {
      staticByCell = {},
      ownersByCell = {},
      exactObjectActive = {},
      previsitCells = {},
    },
  }
  for i = 1, #(normalizedIr.actions or {}) do
    local status, _, errors = compileNode(normalizedIr.actions[i], state, nil)
    if status == 'error' then
      return nil, appendError('sourceManifest: ', errors)
    end
  end
  for i = 1, #state.owners do table.sort(state.owners[i].actionIds) end
  local seenActions = {}
  for i = 1, #state.actions do
    local actionId = state.actions[i].id
    if seenActions[actionId] then
      return nil, {
        'sourceManifest: duplicate semantic action id ' .. tostring(actionId),
      }
    end
    seenActions[actionId] = true
  end
  local extensions, extensionErrors = buildExtensions(state)
  if not extensions then return nil, extensionErrors end
  return {
    actions = state.actions,
    owners = activeOwners(state),
    extensions = extensions,
    indexes = {
      staticByCell = sortedIndex(state.indexSets.staticByCell),
      ownersByCell = sortedIndex(state.indexSets.ownersByCell),
      exactObjectActive = sortedIndex(state.indexSets.exactObjectActive),
      previsitCells = sortedIndex(state.indexSets.previsitCells),
    },
  }, nil
end

-- Consumes normalized IR emitted by source_lowering and reuses its validation
-- proof. The caller must not retain or mutate any table in normalizedIr.
function M.compileOwned(normalizedIr, compileCtx, catalog)
  local seed, errors = compileSeed(normalizedIr, compileCtx, catalog)
  if not seed then return nil, errors end
  return manifest_assembler.assembleCompiled(seed)
end

return M
