local M = {}
M.publicFields = { 'inventory' }
local authored_contract = require('scripts.mom.compiler.authored_contract')
local inventory_item_type = require('scripts.mom.domain.inventory.item_type')
local copyObject = require('scripts.mom.common.tables').copyObject
local lowerString = require('scripts.mom.common.strings').lowerString
local tables = require('scripts.mom.common.tables')
local copyArray = tables.copyArray
local describeShape = tables.describeShape
local authored_path = require('scripts.mom.compiler.authored_path')
local tuple_contract = require('scripts.mom.compiler.tuple_contract')
local diagnostic_emit = require('scripts.mom.compiler.diagnostic_emit')
local selector_skip_report = require('scripts.mom.compiler.selector_skip_report')
local source_ir = require('scripts.mom.compiler.source_ir')
local target_lowering = require('scripts.mom.compiler.target_lowering')
local spec_key = require('scripts.mom.compiler.spec_key')
local compiledSpec = source_ir.compiledSpec
local mergePublicSelect = source_ir.mergePublicSelect
local resolveActionId = authored_path.resolveActionId
local ALLOWED_OWNER_TYPES = {
  NPC = true,
  Creature = true,
  Container = true,
}
local INVENTORY_ITEM_TYPES = {
  Apparatus = true,
  Armor = true,
  Book = true,
  Clothing = true,
  Ingredient = true,
  Light = true,
  Lockpick = true,
  Miscellaneous = true,
  Potion = true,
  Probe = true,
  Repair = true,
  Weapon = true,
}
local ITEM_OP_KEYS = {
  sourceRecordId = true,
  sourceType = true,
  op = true,
  targetRecordId = true,
  targetType = true,
  equip = true,
  count = true,
  limit = true,
}
local ITEM_OPS = {
  add = true,
  ensure = true,
  remove = true,
  replace = true,
  equip = true,
  unequip = true,
}
local PROGRAM_KEYS = {
  itemOps = true,
  ownerGroups = true,
}
local isStandaloneOwnerItemsShape = authored_contract.isInventoryOwnerItemsPayload
local hasOwnerItemsKeys = authored_contract.hasInventoryOwnerItemsKeys
local function sortEntries(entries)
  table.sort(entries, function(a, b)
    if a.sourceRecordId == b.sourceRecordId then
      return tostring(a.op) < tostring(b.op)
    end
    return tostring(a.sourceRecordId) < tostring(b.sourceRecordId)
  end)
end

local function normalizePositiveInteger(value, path)
  local num = tonumber(value)
  if num == nil then
    return nil, path .. ': expected number'
  end
  local floored = math.floor(num)
  if floored <= 0 then
    return nil, path .. ': expected positive number'
  end
  return floored, nil
end

local function normalizeOpTuple(key, rawEntry, path)
  if type(key) ~= 'string' or key == '' then
    return nil, path .. ': expected inventory record id key'
  end
  if describeShape(rawEntry) ~= 'array' then
    return nil, path .. ': expected tuple array'
  end
  local op = rawEntry[1]
  if type(op) ~= 'string' or op == '' then
    return nil, path .. '[1]: expected operation string'
  end
  local opLower = tostring(op):lower()
  local entry = {
    sourceRecordId = lowerString(key),
    op = opLower,
  }
  if opLower == 'replace' then
    local target = rawEntry[2]
    if type(target) ~= 'string' or target == '' then
      return nil, path .. '[2]: replace requires target record id'
    end
    entry.targetRecordId = lowerString(target)
    if rawEntry[3] ~= nil then
      if rawEntry[3] ~= 'equip' then
        return nil, path .. '[3]: replace only supports literal equip'
      end
      entry.equip = true
    end
    if rawEntry[4] ~= nil then
      return nil, path .. ': replace tuple is too long'
    end
    return entry, nil
  end

  if opLower == 'remove' then
    if rawEntry[2] ~= nil then
      local limit, limitErr = normalizePositiveInteger(rawEntry[2], path .. '[2]')
      if not limit then return nil, limitErr end
      entry.limit = limit
    end
    if rawEntry[3] ~= nil then
      return nil, path .. ': remove tuple is too long'
    end
    return entry, nil
  end

  if opLower == 'add' or opLower == 'ensure' then
    local count, countErr
    if opLower == 'ensure' then
      local value = rawEntry[2]
      if type(value) ~= 'number' or value <= 0 or value % 1 ~= 0 then
        return nil, path .. '[2]: ensure requires a positive integer minimum'
      end
      count = value
    else
      count, countErr = normalizePositiveInteger(rawEntry[2], path .. '[2]')
    end
    if not count then return nil, countErr or (path .. '[2]: add requires count') end
    entry.count = count
    if rawEntry[3] ~= nil then
      if rawEntry[3] ~= 'equip' then
        return nil, path .. '[3]: ' .. opLower .. ' only supports literal equip'
      end
      entry.equip = true
    end
    if rawEntry[4] ~= nil then
      return nil, path .. ': ' .. opLower .. ' tuple is too long'
    end
    return entry, nil
  end

  if opLower == 'equip' or opLower == 'unequip' then
    if rawEntry[2] ~= nil then
      return nil, path .. ': ' .. opLower .. ' tuple is too long'
    end
    return entry, nil
  end
  return nil, path .. '[1]: unsupported inventory op ' .. tostring(op)
end

local function normalizePayloadObject(payload, path)
  if type(payload) ~= 'table' or payload[1] ~= nil then
    return nil, tostring(path) .. ': expected object keyed by item record id'
  end
  local entries = {}
  local byRecord = {}
  for key, opTuple in pairs(payload) do
    local entry, entryErr = normalizeOpTuple(key, opTuple, tostring(path) .. '.' .. tostring(key))
    if not entry then
      return nil, entryErr
    end
    if byRecord[entry.sourceRecordId] ~= nil then
      return nil, tostring(path) .. ': duplicate inventory record after case normalization: '
        .. tostring(entry.sourceRecordId)
    end
    byRecord[entry.sourceRecordId] = entry
    entries[#entries + 1] = entry
  end
  for i = 1, #entries do
    local entry = entries[i]
    local target = entry.targetRecordId and byRecord[entry.targetRecordId]
    if target and target.op == 'ensure' then
      return nil, tostring(path) .. ': ensure cannot also be a replacement target: '
        .. tostring(entry.targetRecordId)
    end
  end
  sortEntries(entries)
  if #entries == 0 then
    return nil, tostring(path) .. ': expected at least one inventory entry'
  end
  return entries, nil
end

local function appendGrouped(grouped, typeName, entry)
  local bucket = grouped[typeName]
  if not bucket then
    bucket = {}
    grouped[typeName] = bucket
  end
  bucket[#bucket + 1] = entry
end
local function unresolvedItemReason(recordCtx, recordId)
  local exists, err, typeName = recordCtx.recordExists(recordId, INVENTORY_ITEM_TYPES)
  if exists then return nil, typeName end
  if err == 'wrong_record_type' then
    return 'record id is not an inventory item', nil
  end
  if err == 'invalid_record_id' then
    return 'invalid inventory item record id', nil
  end
  return tostring(err or 'invalid inventory item record id'), nil
end
local function filterInventoryEntries(entries, recordCtx, path, diagnostics)
  local out = {}
  for i = 1, #(entries or {}) do
    local entry = entries[i]
    local sourceErr, sourceType = unresolvedItemReason(recordCtx, entry.sourceRecordId)
    local targetErr, targetType = nil, nil
    if entry.targetRecordId ~= nil then
      targetErr, targetType = unresolvedItemReason(recordCtx, entry.targetRecordId)
    end
    if sourceErr or targetErr then
      local missingSource = sourceErr ~= nil
      local recordId = missingSource and entry.sourceRecordId or entry.targetRecordId
      local label = missingSource and 'inventory item ' or 'inventory replacement target '
      local code = missingSource and 'inventory_item_unresolved' or 'inventory_replacement_unresolved'
      local reason = sourceErr or targetErr
      local entryPath = tostring(path) .. '.' .. tostring(entry.sourceRecordId)
      local message = label .. tostring(recordId)
        .. ' cannot resolve to an inventory item (' .. tostring(reason) .. ')'
      diagnostic_emit.reportSelectorUnresolved(
        diagnostics and diagnostics.diagnosticCollector or nil,
        {
          sourcePath = diagnostics and diagnostics.sourcePath or nil,
          family = 'modify_inventory',
          actionId = diagnostics and diagnostics.actionId or nil,
          path = entryPath,
          code = code,
          message = message,
          logMessage = 'Skipping ' .. entryPath .. ': ' .. message,
        }
      )
    else
      if type(sourceType) ~= 'string' or sourceType == '' then
        return nil, tostring(path) .. '.' .. tostring(entry.sourceRecordId)
          .. ': resolved inventory item type is unavailable'
      end
      if entry.targetRecordId ~= nil and (type(targetType) ~= 'string' or targetType == '') then
        return nil, tostring(path) .. '.' .. tostring(entry.sourceRecordId)
          .. ': resolved replacement item type is unavailable'
      end
      local equipmentType = nil
      if entry.op == 'equip' or entry.op == 'unequip'
          or ((entry.op == 'add' or entry.op == 'ensure') and entry.equip == true) then
        equipmentType = sourceType
      elseif entry.op == 'replace' and entry.equip == true then
        equipmentType = targetType
      end
      if equipmentType ~= nil
          and not inventory_item_type.isEquippable(equipmentType) then
        return nil, tostring(path) .. '.' .. tostring(entry.sourceRecordId)
          .. ': equipment operation requires Armor, Clothing, Light, or Weapon; got '
          .. tostring(equipmentType)
      end
      local resolved = copyObject(entry)
      resolved.sourceType, resolved.targetType = sourceType, targetType
      out[#out + 1] = resolved
    end
  end
  return out
end
local function warnEmptyInventory(actionId, actionPath, reason, diagnostics)
  local message = 'inventory action was skipped because '
    .. tostring(reason or 'no inventory item records resolved')
  diagnostic_emit.reportSelectorUnresolved(
    diagnostics and diagnostics.diagnosticCollector or nil,
    {
    sourcePath = diagnostics and diagnostics.sourcePath or nil,
    family = 'modify_inventory',
    actionId = actionId,
    path = tostring(actionPath) .. '.inventory',
    code = 'inventory_no_resolved_targets',
    message = message,
    logMessage = tostring(actionPath) .. '.inventory: ' .. message,
  })
end
local function buildProgram(baseEntries, ownerEntries)
  local hasBaseEntries = type(baseEntries) == 'table' and #baseEntries > 0
  local hasOwnerEntries = type(ownerEntries) == 'table' and #ownerEntries > 0
  local program = {
    itemOps = hasBaseEntries and copyArray(baseEntries) or nil,
    ownerGroups = hasOwnerEntries and ownerEntries or nil,
  }
  return program
end

local function familyProgram(spec, fields)
  fields = fields or {}
  fields.claims = {keys = {'ref.inventory'}}
  fields.reversible = true
  return source_ir.familyProgram(spec, fields)
end

local function validateProgramItemOps(ops, path, errors, actionId, H)
  ops = H.requireArray(ops, path, errors, actionId)
  for i = 1, #(ops or {}) do
    local opPath = path .. '[' .. tostring(i) .. ']'
    local op = H.requireObject(ops[i], opPath, errors, actionId)
    if op then
      H.rejectUnknownObjectKeys(op, ITEM_OP_KEYS, opPath, errors, actionId)
      local operation = H.requireString(op.op, opPath .. '.op', errors, actionId)
      if operation ~= nil and ITEM_OPS[operation] ~= true then
        H.appendError(errors, actionId, opPath .. '.op: unsupported inventory operation')
      end
      H.requireString(op.sourceRecordId, opPath .. '.sourceRecordId', errors, actionId)
      local sourceType = H.requireString(op.sourceType, opPath .. '.sourceType', errors, actionId)
      if sourceType ~= nil and INVENTORY_ITEM_TYPES[sourceType] ~= true then
        H.appendError(errors, actionId, opPath .. '.sourceType: unsupported inventory item type')
      end
      if op.equip ~= nil and type(op.equip) ~= 'boolean' then
        H.appendError(errors, actionId, opPath .. '.equip: expected boolean')
      end
      for _, field in ipairs({'count', 'limit'}) do
        local value = op[field]
        if value ~= nil and (type(value) ~= 'number' or value < 1 or value % 1 ~= 0) then
          H.appendError(errors, actionId, opPath .. '.' .. field .. ': expected positive integer')
        end
      end
      if (operation == 'add' or operation == 'ensure') and op.count == nil then
        H.appendError(errors, actionId, opPath .. '.count: ' .. operation .. ' requires a positive integer')
      elseif operation ~= 'add' and operation ~= 'ensure' and op.count ~= nil then
        H.appendError(errors, actionId, opPath .. '.count: only add and ensure accept count')
      end
      if operation ~= 'remove' and op.limit ~= nil then
        H.appendError(errors, actionId, opPath .. '.limit: only remove accepts limit')
      end
      if operation ~= 'add' and operation ~= 'ensure' and operation ~= 'replace' and op.equip ~= nil then
        H.appendError(errors, actionId, opPath .. '.equip: only add, ensure and replace accept equip')
      end
      if operation == 'replace' then
        H.requireString(op.targetRecordId, opPath .. '.targetRecordId', errors, actionId)
        local targetType = H.requireString(op.targetType, opPath .. '.targetType', errors, actionId)
        if targetType ~= nil and INVENTORY_ITEM_TYPES[targetType] ~= true then
          H.appendError(errors, actionId, opPath .. '.targetType: unsupported inventory item type')
        end
      elseif op.targetRecordId ~= nil or op.targetType ~= nil then
        H.appendError(errors, actionId, opPath .. ': target fields require replace')
      end
      local equipmentType = nil
      if operation == 'equip' or operation == 'unequip'
          or ((operation == 'add' or operation == 'ensure') and op.equip == true) then
        equipmentType = sourceType
      elseif operation == 'replace' and op.equip == true then
        equipmentType = op.targetType
      end
      if equipmentType ~= nil
          and not inventory_item_type.isEquippable(equipmentType) then
        H.appendError(errors, actionId,
          opPath .. ': equipment operation requires Armor, Clothing, Light, or Weapon')
      end
    end
  end
end

function M.validateProgram(program, errors, actionId, H)
  H.rejectUnknownKeys(program, PROGRAM_KEYS, errors, actionId)
  if program.itemOps == nil and program.ownerGroups == nil then
    H.appendError(errors, actionId, 'expected itemOps or ownerGroups')
  end
  validateProgramItemOps(program.itemOps, 'itemOps', errors, actionId, H)
  local groups = H.requireArray(program.ownerGroups, 'ownerGroups', errors, actionId)
  for i = 1, #(groups or {}) do
    local path = 'ownerGroups[' .. tostring(i) .. ']'
    local group = H.requireObject(groups[i], path, errors, actionId)
    if group then
      H.requireString(group.sourceRecordId, path .. '.sourceRecordId', errors, actionId)
      validateProgramItemOps(group.objects, path .. '.objects', errors, actionId, H)
      if group.filters ~= nil then
        H.requireArray(group.filters, path .. '.filters', errors, actionId)
      end
    end
  end
end

local function buildOwnerEntry(parsed, entries, recordCtx, path, diagnostics, skipReport)
  local inferredTypes = target_lowering.resolveSelectorTypesOrSkip(parsed, {
    recordCtx = recordCtx,
    path = path,
    allowedTypes = ALLOWED_OWNER_TYPES,
    typeLabel = 'inventory owner types',
    selectorLabel = 'owner selector',
    skipReport = skipReport,
  })
  if not inferredTypes then
    return nil, nil, true
  end
  local inferredType = next(inferredTypes)
  return {
    sourceRecordId = parsed.sourceValue,
    sourceKeyKind = parsed.sourceKeyKind,
    sourcePosition = parsed.sourcePosition,
    inferredType = inferredType,
    objects = copyArray(entries),
  }, nil, false
end
local function prepareItems(payload, path, queries)
  local entries, err = normalizePayloadObject(payload, path)
  if not entries then return nil, err end
  for i = 1, #entries do
    local entry = entries[i]
    queries.recordIds[entry.sourceRecordId] = true
    if entry.targetRecordId then queries.recordIds[entry.targetRecordId] = true end
  end
  return entries
end
local function prepareOwner(raw, path, queries)
  if type(raw) ~= 'string' or raw == '' then return nil, path .. ': expected owner selector string' end
  local parsed, errors = target_lowering.parseSelector(path, raw, {allowMeshPaths = false})
  if not parsed then return nil, errors and errors[1] or (path .. ': invalid owner selector') end
  target_lowering.collectParsedSelectorQuery(parsed, queries)
  return parsed
end
function M.prepareAction(input, queries, ctx)
  local actionId = resolveActionId(input, ctx, 'modify_inventory')
  local actionPath = authored_path.authoredActionPath(ctx, actionId)
  local path = actionPath .. '.inventory'
  if input.select and input.select.type ~= nil then return nil, {actionPath .. '.select.type: is not allowed'} end
  local payload = input.payload
  if input.payloadKind == 'direct' then
    if isStandaloneOwnerItemsShape(payload) then
      for key in pairs(payload) do
        if key ~= 'owners' and key ~= 'items' then return nil, {path .. '.' .. tostring(key) .. ': is not allowed'} end
      end
      if #payload.owners == 0 then return nil, {path .. '.owners: expected at least one owner tuple'} end
      local items, err = prepareItems(payload.items, path .. '.items', queries)
      if not items then return nil, {err} end
      local owners = {}
      for i = 1, #payload.owners do
        local owner = payload.owners[i]
        local ownerPath = path .. '.owners[' .. tostring(i) .. ']'
        local cell, parsed, errors
        if type(owner) ~= 'table' then
          errors = {ownerPath .. ': expected tuple array'}
        else
          local valid
          valid, errors = tuple_contract.validateArity(owner, ownerPath, 2)
          if valid then
            cell = owner[1]
            if type(cell) ~= 'string' and type(cell) ~= 'table' then
              errors = {ownerPath .. '[1]: expected cell string or object'}
            else
              local err
              parsed, err = prepareOwner(owner[2], ownerPath .. '[2]', queries)
              if not parsed then errors = {err} end
            end
          end
        end
        owners[i] = {cell = cell, parsed = parsed, sourceIndex = i, errors = errors}
      end
      input.mode, input.payload = 'owners', {owners = owners, items = items}
      return input
    end
    if hasOwnerItemsKeys(payload) then
      if payload.owner ~= nil then return nil, {path .. '.owner: is not allowed; use owners'} end
      return nil, {path .. ': expected complete { owners, items } object'}
    end
    local entries, err = prepareItems(payload, path, queries)
    if not entries then return nil, {err} end
    input.mode, input.payload = 'direct', entries
    return input
  end
  for i = 1, #payload do
    local tuple = payload[i]
    local tuplePath = authored_path.authoredTuplePath(ctx, actionId, 'inventory', tuple)
    local values = tuple.values
    tuple.values = nil
    local valid, errors = tuple_contract.validateArity(values, tuplePath, 2)
    if not valid then
      tuple.errors = errors
    elseif type(values[1]) ~= 'string' or values[1] == '' then
      tuple.errors = {tuplePath .. '[1]: expected owner selector string'}
    else
      local items, err = prepareItems(values[2], tuplePath .. '[2]', queries)
      if not items then
        tuple.errors = {err}
      else
        local parsed, selectorError = prepareOwner(values[1], tuplePath .. '[1]', queries)
        tuple.items, tuple.parsed, tuple.selectorError = items, parsed, selectorError
      end
    end
  end
  input.mode = 'tuples'
  return input
end
function M.compileAction(spec, ctx)
  local actionId = resolveActionId(spec, ctx, 'modify_inventory')
  local actionPath = authored_path.authoredActionPath(ctx, actionId)
  local recordCtx = nil
  local function requireRecordContext()
    if recordCtx == nil then
      recordCtx = target_lowering.requireRecordContext(ctx)
    end
    return recordCtx
  end
  local diagnostics = {
    diagnosticCollector = ctx and ctx.diagnosticCollector or nil,
    sourcePath = ctx and ctx.sourcePath or nil,
    actionId = actionId,
  }
  local skipReport = selector_skip_report.new({
    family = 'modify_inventory',
    actionId = actionId,
    verb = 'inventory',
    diagnostics = diagnostics,
    code = 'selector_key_unresolved',
  })
  local payload = spec.payload
  local publicSelect = spec.select or {}
  if spec.mode ~= 'tuples' then
    if spec.mode == 'owners' then
      local owners = payload.owners
      local path = actionPath .. '.inventory'
      local entries = payload.items
      local filterError
      entries, filterError = filterInventoryEntries(
        entries,
        requireRecordContext(),
        path .. '.items',
        diagnostics
      )
      if entries == nil then return nil, {filterError} end
      if #entries == 0 then
        warnEmptyInventory(actionId, actionPath, 'no inventory item records resolved', diagnostics)
        return {}, nil
      end
      local groups = {}
      local groupOrder = {}
      for i = 1, #owners do
        local owner = owners[i]
        local ownerPath = path .. '.owners[' .. tostring(i) .. ']'
        if owner.errors then return nil, owner.errors end
        local cell = owner.cell
        local entry, ownerErr, skipped = buildOwnerEntry(
          owner.parsed,
          entries,
          requireRecordContext(),
          ownerPath .. '[2]',
          diagnostics,
          skipReport
        )
        if entry then
          local key = spec_key.fromSpec(cell)
          local group = groups[key]
          if not group then
            group = { cell = cell, grouped = {} }
            groups[key] = group
            groupOrder[#groupOrder + 1] = key
          end
          appendGrouped(group.grouped, entry.inferredType, entry)
        elseif not skipped then
          return nil, { ownerErr }
        end
      end
      selector_skip_report.flush(skipReport)
      local loweredList = {}
      for gi = 1, #groupOrder do
        local group = groups[groupOrder[gi]]
        local ownerEntries = target_lowering.flattenGroupedEntries(group.grouped)
        local baseSelect = mergePublicSelect(publicSelect, {
          cell = group.cell,
        })
        local lowered = compiledSpec(spec)
        lowered.id = gi == 1 and tostring(actionId) or tostring(actionId) .. ':' .. tostring(gi)
        local targetStatus, finalized, targetErrors, resolvedOwners, metadata = target_lowering.finalizeResolvedEntries(nil, spec, baseSelect, {
          entries = ownerEntries,
          lowered = lowered,
          recordCtx = requireRecordContext(),
          pathPrefix = path .. '.owners',
        })
        if targetStatus == 'error' then return nil, targetErrors end
        if targetStatus == 'ok' then
          finalized.program = buildProgram(nil, resolvedOwners)
          loweredList[#loweredList + 1] = familyProgram(finalized, metadata)
        end
      end
      if #loweredList == 0 then
        warnEmptyInventory(actionId, actionPath, 'no owner selector resolved', diagnostics)
      end
      return loweredList, nil
    end
    local entries = payload
    local filterError
    entries, filterError = filterInventoryEntries(
      entries,
      requireRecordContext(),
      actionPath .. '.inventory',
      diagnostics
    )
    if entries == nil then return nil, {filterError} end
    if #entries == 0 then
      warnEmptyInventory(actionId, actionPath, 'no inventory item records resolved', diagnostics)
      return {}, nil
    end
    local lowered = compiledSpec(spec)
    lowered.select = publicSelect
    lowered.program = buildProgram(entries, nil)
    return {familyProgram(lowered)}, nil
  end
  if #payload == 0 then
    return nil, { actionPath .. '.inventory: expected at least one tuple' }
  end
  local grouped = {}
  for i = 1, #payload do
    local tuple = payload[i]
    if tuple.errors then return nil, tuple.errors end
    local path = authored_path.authoredTuplePath(ctx, actionId, 'inventory', tuple)
    local entries = tuple.items
    if #entries > 0 then
      local filterError
      entries, filterError = filterInventoryEntries(
        entries,
        requireRecordContext(),
        path .. '[2]',
        diagnostics
      )
      if entries == nil then return nil, {filterError} end
    end
    if #entries > 0 then
      if tuple.selectorError then return nil, {tuple.selectorError} end
      local entry, ownerErr, skipped = buildOwnerEntry(
        tuple.parsed,
        entries,
        requireRecordContext(),
        path .. '[1]',
        diagnostics,
        skipReport
      )
      if entry then
        local predicates = tuple.predicates
        target_lowering.attachEntryPredicates(predicates, entry)
        appendGrouped(grouped, entry.inferredType, entry)
      elseif not skipped then
        return nil, { tostring(ownerErr) }
      end
    end
  end
  selector_skip_report.flush(skipReport)
  if not next(grouped) then
    target_lowering.emitNoResolvedTargets({
      skipReport = skipReport,
      path = actionPath .. '.inventory',
      code = 'inventory_no_resolved_targets',
      message = 'inventory action was skipped because no owner selector or inventory item records resolved',
      reason = 'no owner selector or inventory item records resolved',
    })
    return {}, nil
  end
  local targetStatus, lowered, targetErrors, ownerEntries, metadata = target_lowering.finalizeResolvedEntries(grouped, spec, publicSelect, {
    payloadKey = 'inventory',
    recordCtx = requireRecordContext(),
    path = actionPath .. '.inventory',
    pathPrefix = actionPath .. '.inventory',
  })
  if targetStatus == 'skip' then return {}, nil end
  if targetStatus == 'error' then return nil, targetErrors end
  lowered.program = buildProgram(nil, ownerEntries)
  return {familyProgram(lowered, metadata)}, nil
end
return M
