local M = {}
M.publicFields = { 'place', 'attach', 'disableOriginal', 'transferContents' }
local keyed_targets = require('scripts.mom.compiler.keyed_targets')
local direct_targets = require('scripts.mom.compiler.direct_targets')
local cell_selection = require('scripts.mom.compiler.cell_selection')
local compile_policy = require('scripts.mom.compiler.compile_policy')
local model_path_contract = require('scripts.mom.contracts.model_path')
local model_path_lookup = require('scripts.mom.openmw.model_path')
local authored_path = require('scripts.mom.compiler.authored_path')
local tuple_contract = require('scripts.mom.compiler.tuple_contract')
local source_ir = require('scripts.mom.compiler.source_ir')
local selector_skip_report = require('scripts.mom.compiler.selector_skip_report')
local target_lowering = require('scripts.mom.compiler.target_lowering')
local type_capabilities = require('scripts.mom.actions.place_ref.type_capabilities')
local ref_type = require('scripts.mom.contracts.ref_type')
local choice_compile = require('scripts.mom.actions.place_ref.choice_compile')
local canonical = require('scripts.mom.contracts.canonical')
local compiledSpec = source_ir.compiledSpec
local resolveActionId = authored_path.resolveActionId
local mergePublicSelect = source_ir.mergePublicSelect
local tables = require('scripts.mom.common.tables')
local copyArray = tables.copyArray
local copyObject = tables.copyObject
local sortedKeys = tables.sortedKeys
local ALLOWED_MESH_SOURCE_TYPES = type_capabilities.selectorTypes()
local place_load = require('scripts.mom.actions.place_ref.load')
local LOAD_MODEL_TYPES = place_load.LOAD_MODEL_TYPES
local SPLIT_GLOBAL_TYPES = place_load.GLOBAL_RUNTIME_TYPES
local function splitAllowedTypes(selectSpec)
  local rawType = type(selectSpec) == 'table' and selectSpec.type or nil
  if rawType == nil then return SPLIT_GLOBAL_TYPES end
  local list = type(rawType) == 'string' and {rawType} or (type(rawType) == 'table' and rawType or nil)
  if not list then return SPLIT_GLOBAL_TYPES end
  local out = {}
  for _, name in ipairs(list) do
    if type(name) == 'string' and not LOAD_MODEL_TYPES[name] then
      out[name] = true
    end
  end
  return out
end
local PROGRAM_KEYS = {
  mode = true,
  objects = true,
  disableOriginal = true,
  choiceGroup = true,
  profiles = true,
  destinationCellKey = true,
  inheritedAnchor = true,
  inheritedSource = true,
}

local function singleCandidateType(typeName)
  return {
    [typeName] = true,
  }
end
local function copyPosition(position)
  if not position then return nil end
  return {
    x = position.x,
    y = position.y,
    z = position.z,
  }
end
local function copyRotation(rotation)
  if not rotation then return nil end
  return {
    yaw = rotation.yaw,
    pitch = rotation.pitch,
    roll = rotation.roll,
  }
end
local function copyPlacementEntry(entry)
  return {
    targetKind = entry.targetKind,
    targetValue = entry.targetValue,
    targetType = entry.targetType,
    position = copyPosition(entry.position),
    rotation = copyRotation(entry.rotation),
    sourceRecordId = entry.sourceRecordId,
    sourceKeyKind = entry.sourceKeyKind,
    sourcePosition = copyPosition(entry.sourcePosition),
    sourceExpandedFromModelPath = entry.sourceExpandedFromModelPath == true or nil,
    inferredType = entry.inferredType,
    filters = copyArray(entry.filters),
    slot = entry.slot,
  }
end
local function copyPlacementEntries(entries)
  local out = {}
  for i = 1, #(entries or {}) do
    out[i] = copyPlacementEntry(entries[i])
  end
  return out
end
local function buildProgram(mode, entries, opts)
  opts = opts or {}
  return {
    mode = mode,
    objects = entries,
    disableOriginal = mode == 'relative' and opts.disableOriginal == true or nil,
  }
end

local function familyProgram(spec, fields)
  local keys, claimError = type_capabilities.claimsForProgram(spec.program)
  if keys == nil then error(claimError, 0) end
  fields = fields or {}
  fields.claims = {keys = keys}
  fields.reversible = true
  return source_ir.familyProgram(spec, fields)
end

function M.validateProgram(program, errors, actionId, H)
  H.rejectUnknownKeys(program, PROGRAM_KEYS, errors, actionId)
  if program.mode ~= 'absolute' and program.mode ~= 'relative' then
    H.appendError(errors, actionId, 'mode: expected absolute or relative')
  end
  if program.destinationCellKey ~= nil
      and (program.mode ~= 'absolute' or type(program.destinationCellKey) ~= 'string'
        or program.destinationCellKey == '') then
    H.appendError(errors, actionId, 'destinationCellKey: expected an absolute destination key')
  end
  if program.inheritedAnchor ~= nil
      and (program.inheritedAnchor ~= true or program.mode ~= 'relative') then
    H.appendError(errors, actionId, 'inheritedAnchor: expected true on a relative child placement')
  end
  if program.inheritedSource ~= nil
      and (program.inheritedSource ~= true or program.mode ~= 'relative'
        or program.inheritedAnchor ~= nil) then
    H.appendError(errors, actionId, 'inheritedSource: expected true on a keyed relative child placement')
  end
  H.requireNonEmptyArray(program.objects, 'objects', errors, actionId)
  if program.disableOriginal ~= nil and type(program.disableOriginal) ~= 'boolean' then
    H.appendError(errors, actionId, 'disableOriginal: expected boolean')
  end
  if program.disableOriginal == true and program.mode ~= 'relative' then
    H.appendError(errors, actionId, 'disableOriginal: only allowed for relative placement')
  end
  if program.choiceGroup ~= nil then
    choice_compile.validateProgram(program, errors, actionId, H)
  else
    if program.profiles ~= nil then
      H.appendError(errors, actionId, 'profiles require a choiceGroup')
    end
    if type(program.objects) == 'table' then
      for _, entry in ipairs(program.objects) do
        if type(entry) == 'table' and entry.choices ~= nil then
          H.appendError(errors, actionId, 'choice objects require a choiceGroup')
          break
        end
      end
    end
  end
end

local function normalizeVector3Spec(value, path)
  if type(value) ~= 'table' then
    return nil, path .. ': expected [x, y, z] array'
  end
  for key in pairs(value) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > 3 then
      return nil, path .. '.' .. tostring(key) .. ': is not allowed; expected [x, y, z] array'
    end
  end
  for i = 1, 3 do
    if type(value[i]) ~= 'number' then
      return nil, path .. '[' .. tostring(i) .. ']: expected number'
    end
  end
  return { x = value[1], y = value[2], z = value[3] }, nil
end
local function normalizeRotationSpec(value, path)
  if type(value) ~= 'table' then
    return nil, path .. ': expected rotation object'
  end
  for key, raw in pairs(value) do
    if key ~= 'yaw' and key ~= 'pitch' and key ~= 'roll' then
      return nil, path .. '.' .. tostring(key) .. ': is not allowed'
    end
    if type(raw) ~= 'number' then
      return nil, path .. '.' .. tostring(key) .. ': expected number'
    end
  end
  return {
    yaw = value.yaw or 0,
    pitch = value.pitch or 0,
    roll = value.roll or 0,
  }, nil
end
local function normalizePlaceTarget(value, mode, path)
  if type(value) ~= 'string' or value == '' then
    return nil, path .. ': expected placed record id or mesh path string'
  end
  if keyed_targets.isLikelyMeshPath(value) then
    if mode == 'absolute' then
      return nil, path .. ': absolute placement requires a placed record id, not a mesh path'
    end
    local normalizedModel = model_path_contract.normalize(value)
    if not normalizedModel then
      return nil, path .. ': invalid mesh path'
    end
    return {
      targetKind = 'model_path',
      targetValue = normalizedModel,
    }, nil
  end
  return {
    targetKind = 'record_id',
    targetValue = tostring(value),
  }, nil
end
local function normalizePlaceEntry(entry, path)
  if type(entry) ~= 'table' then
    return nil, path .. ': expected tuple array'
  end
  local okLength, lengthErrors = tuple_contract.validateArity(entry, path, 3)
  if not okLength then return nil, lengthErrors[1] end
  local targetInfo, targetErr = normalizePlaceTarget(entry[1], 'absolute', path .. '[1]')
  if not targetInfo then
    return nil, targetErr
  end
  local position = entry[2]
  local normalizedPosition, positionErr = normalizeVector3Spec(position, path .. '[2]')
  if not normalizedPosition then
    return nil, positionErr
  end
  local rotation, rotationErr = normalizeRotationSpec(entry[3], path .. '[3]')
  if rotation == nil then
    return nil, rotationErr
  end
  return {
    targetKind = targetInfo.targetKind,
    targetValue = targetInfo.targetValue,
    position = normalizedPosition,
    rotation = rotation,
  }, nil
end
local function assignAbsoluteSlots(entries, instanceKey)
  for i = 1, #entries do
    -- A private imported instance owns a physical placement even when another
    -- instance has identical record and transform facts. Ordinary authored
    -- placement programs retain their existing ordered slot identities.
    entries[i].slot = instanceKey ~= nil
      and ('a:instance:' .. canonical.assertHash(instanceKey)) or ('a:' .. tostring(i))
  end
end
local function resolvePlacedRecordType(recordCtx, recordId)
  local exists, err = recordCtx.recordExists(recordId)
  if not exists then
    if err == 'invalid_record_id' then return nil, 'invalid record id' end
    return nil, tostring(err or 'invalid record id')
  end
  if type(recordCtx.resolveLiveRefType) ~= 'function' then
    return nil, 'placed record type resolution is unavailable'
  end
  local typeName, typeError = recordCtx.resolveLiveRefType(recordId)
  if type(typeName) == 'string' and typeName ~= '' then return typeName, nil end
  if typeName == false then return nil, 'placed record type is ambiguous' end
  return nil, tostring(typeError or 'record is not a placeable ref type')
end

-- Read-only prepass for a descendant that needs the types of all possible
-- parent outputs. It never invents a type for an unresolved source or target.
local function selectedParentTypes(types, selectSpec, recordCtx)
  local exactIds = compile_policy.normalizeExactIds(selectSpec and selectSpec.recordId)
  if exactIds == nil then return types end
  local selectedTypes, narrowed = {}, {}
  for id in pairs(exactIds) do
    local resolvedType = recordCtx.resolveLiveRefType(id)
    if resolvedType then selectedTypes[resolvedType] = true end
  end
  for typeName in pairs(types) do
    if selectedTypes[typeName] then narrowed[typeName] = true end
  end
  -- Leave an empty/unresolved intersection to the shared compiler, which
  -- owns the established skip/error and unresolved-record diagnostics.
  return next(narrowed) ~= nil and narrowed or types
end

function M.outputTypeEnvelope(input, ctx)
  local recordCtx = target_lowering.requireRecordContext(ctx)
  local out = {}
  local function add(typeName)
    if not ref_type.contains(typeName) then return nil, 'output type is unavailable' end
    out[typeName] = true
    return true, nil
  end
  local function addTarget(target, sourceTypes)
    if target.targetKind == 'record_id' then
      local targetType, reason = resolvePlacedRecordType(recordCtx, target.targetValue)
      if targetType == nil then return nil, reason end
      return add(targetType)
    end
    if target.targetKind ~= 'model_path' or type(sourceTypes) ~= 'table'
        or next(sourceTypes) == nil then
      return nil, 'model replacement source types are unavailable'
    end
    for typeName in pairs(sourceTypes) do
      local ok, reason = add(typeName)
      if not ok then return nil, reason end
    end
    return true, nil
  end
  -- Ordinary placement lowering discards unresolved targets; do not let an
  -- unavailable sibling inflate or invalidate the envelope of outputs that
  -- will actually be emitted. Keep source-type uncertainty fail-closed.
  local function targetWillEmit(target)
    if target.targetKind == 'record_id' then
      return resolvePlacedRecordType(recordCtx, target.targetValue) ~= nil
    end
    if target.targetKind == 'model_path' then
      local lookup = type(ctx.modelExists) == 'function'
        and ctx.modelExists or model_path_lookup.modelExists
      local exists, _, reason = lookup(target.targetValue)
      return not not exists and reason == nil
    end
    return nil
  end
  local function sourceTypesFor(parsed, allowed)
    if type(parsed) ~= 'table' then return nil, 'parent anchor selector is unavailable' end
    if parsed.sourceKeyKind ~= 'record_id' and parsed.sourceKeyKind ~= 'model_path' then
      return nil, 'parent anchor selector kind is invalid'
    end
    -- The normal placement compiler skips unresolved source selectors. Use
    -- its resolver here as well so skipped siblings do not poison the
    -- envelope, without duplicating its source-type inference rules.
    local sourceTypes = keyed_targets.resolveSelectorTypes(parsed, {
      recordCtx = recordCtx, allowedTypes = allowed,
    })
    if sourceTypes == nil then return nil, nil, true end
    return sourceTypes, nil, false
  end
  local function addChoiceRule(rule)
    local sourceTypes, sourceError, skip = sourceTypesFor(rule.parsed, rule.sourceTypes)
    if skip then return true, nil end
    if sourceTypes == nil then return nil, sourceError end
    -- Choice lowering emits a type only when at least one source record
    -- survives its ignore set and authoritative type check. A coarse mesh
    -- type alone can otherwise claim an impossible container output.
    local byType = rule.parsed.sourceKeyKind == 'model_path'
      and recordCtx.resolveMeshTypes(rule.parsed.sourceValue) or nil
    local eligible = {}
    for typeName in pairs(sourceTypes) do
      local ids = byType and byType[typeName] or {rule.parsed.sourceValue}
      for _, sourceId in ipairs(ids or {}) do
        local id = tostring(sourceId):lower()
        if not rule.ignoreRecords[id] and recordCtx.resolveLiveRefType(id) == typeName then
          eligible[typeName] = true
          break
        end
      end
    end
    if next(eligible) == nil then return true, nil end
    for _, target in ipairs(rule.targets or {}) do
      local emits = targetWillEmit(target)
      if emits == nil then return nil, 'parent target kind is invalid' end
      if emits then
        local ok, reason = addTarget(target, eligible)
        if not ok then return nil, reason end
      end
    end
    return true, nil
  end
  local function addParentEntry(entry)
    if entry.errors then return nil, table.concat(entry.errors, ' | ') end
    local emits = targetWillEmit(entry)
    if emits == nil then return nil, 'parent target kind is invalid' end
    if not emits then return true, nil end
    -- Normal attach lowering first omits missing targets, then checks the
    -- corresponding selector. Keep the same reachability here.
    if entry.selectorErrors then return nil, table.concat(entry.selectorErrors, ' | ') end
    local sourceTypes
    if input.verb == 'attach' then
      local sourceError, skip
      if ctx.isChild and entry.parsed
          and entry.parsed.sourceKeyKind == 'model_path' then
        sourceTypes = ctx.parentOutputTypes
        if type(sourceTypes) ~= 'table' then
          return nil, 'parent output types are unavailable for inherited model selector'
        end
        if next(sourceTypes) == nil then return true, nil end
      else
        sourceTypes, sourceError, skip = sourceTypesFor(entry.parsed)
      end
      if skip then return true, nil end
      if sourceTypes == nil then return nil, sourceError end
      -- A keyed child cannot run on a parent output of a different type.
      -- Both sets are conservative, so their intersection remains safe.
      if ctx.isChild and type(ctx.parentOutputTypes) == 'table' then
        local reachable = {}
        for typeName in pairs(sourceTypes) do
          if ctx.parentOutputTypes[typeName] then reachable[typeName] = true end
        end
        if next(reachable) == nil then return true, nil end
        sourceTypes = reachable
      end
    end
    return addTarget(entry, sourceTypes)
  end
  if input.payloadKind == 'choice' then
    for _, rule in ipairs(input.payload.rules or {}) do
      local ok, reason = addChoiceRule(rule)
      if not ok then return nil, reason end
    end
  elseif input.verb == 'attach'
      and (input.payloadKind == 'direct' or input.payloadKind == 'inherited_tuples') then
    local parentTypes = ctx.parentOutputTypes
    if type(parentTypes) == 'table' then
      -- No inherited anchors means this placement cannot produce an output,
      -- even when its replacement has an independently known record type.
      if next(parentTypes) == nil then return {}, nil end
      parentTypes = selectedParentTypes(parentTypes, input.select, recordCtx)
    end
    local targets = input.payloadKind == 'direct' and {input.payload} or input.payload
    for _, target in ipairs(targets) do
      local ok, reason = addTarget(target, parentTypes)
      if not ok then return nil, reason end
    end
  else
    for _, entry in ipairs(input.payload or {}) do
      local ok, reason = addParentEntry(entry)
      if not ok then return nil, reason end
    end
  end
  return out, nil
end
local function makeSkipSummary(actionId, verb, diagnostics)
  return selector_skip_report.new({
    family = 'place_ref',
    actionId = tostring(actionId),
    verb = tostring(verb),
    diagnostics = diagnostics,
    code = 'place_selector_unresolved',
  })
end
local function recordSkippedPlaceTarget(path, target, label, reason, summary)
  selector_skip_report.record(summary, path, target, label, reason)
end
local function lowerAbsolutePlaceSpec(spec, actionId, tuples, recordCtx, diagnostics, compileCtx)
  local actionPath = authored_path.authoredActionPath(compileCtx, actionId)
  local publicSelect = spec.select or {}
  local normalizedObjects = {}
  local skipSummary = makeSkipSummary(actionId, 'place', diagnostics)
  for i = 1, #tuples do
    local normalized = tuples[i]
    if normalized.errors then return nil, normalized.errors end
    local path = authored_path.authoredTuplePath(compileCtx, actionId, 'place', normalized)
    local targetType, targetErr = resolvePlacedRecordType(recordCtx, normalized.targetValue)
    if targetType and spec.options and spec.options.targetTypes then
      local admitted = false
      for _, name in ipairs(spec.options.targetTypes) do if name == targetType then admitted = true end end
      if not admitted then
        return nil, {path .. ': target type ' .. targetType .. ' is outside the declared placement targetTypes'}
      end
    end
    if not targetType then
      recordSkippedPlaceTarget(
        path .. '[1]',
        normalized.targetValue,
        'placed target',
        targetErr,
        skipSummary
      )
    else
      local object = copyPlacementEntry(normalized)
      object.targetType = targetType
      normalizedObjects[#normalizedObjects + 1] = object
    end
  end
  selector_skip_report.flush(skipSummary)
  if #normalizedObjects == 0 then
    selector_skip_report.emitNoTargets(skipSummary, {
      path = actionPath .. '.place',
      code = 'place_no_targets_resolved',
      message = 'place action was skipped because no placed target resolved',
      reason = 'no placed target resolved',
    })
    return {}, nil
  end
  assignAbsoluteSlots(normalizedObjects, spec.options and spec.options.instanceKey)
  if compileCtx and compileCtx.isChild == true then
    local selection, selectionErrors = cell_selection.compile(publicSelect.cell, actionId, {
      cellIndex = compileCtx.cellIndex,
      requireCellIndex = compileCtx.requireCellIndex,
      workspace = compileCtx.workspace,
      metrics = compileCtx.metrics,
      path = actionPath .. '.select.cell',
      requireExplicit = true,
      universe = 'required',
    })
    if not selection then return nil, selectionErrors end
    local universe = selection.universe
    if type(universe) ~= 'table' or universe.kind ~= 'finite'
        or type(universe.entries) ~= 'table' or #universe.entries == 0 then
      return nil, {actionPath .. ': child place destinations must resolve to finite cells'}
    end
    local rows = {}
    for i = 1, #universe.entries do
      local destination = universe.entries[i]
      if type(destination.key) ~= 'string' or destination.key == '' then
        return nil, {actionPath .. ': child place destination has no cell key'}
      end
      local lowered = compiledSpec(spec)
      lowered.select = nil
      lowered.program = buildProgram('absolute', normalizedObjects)
      lowered.program.destinationCellKey = destination.key
      rows[#rows + 1] = familyProgram(lowered)
    end
    return rows, nil
  end
  local lowered = compiledSpec(spec)
  lowered.select = mergePublicSelect(publicSelect, {})
  lowered.program = buildProgram('absolute', normalizedObjects)
  return {familyProgram(lowered)}, nil
end
local function normalizeRelativeTarget(target, position, rotation, targetPath, positionPath, rotationPath)
  local targetInfo, targetErr = normalizePlaceTarget(target, 'relative', targetPath)
  if not targetInfo then
    return nil, targetErr
  end
  if position ~= nil and type(position) ~= 'table' then
    return nil, positionPath .. ': attach offset must be an array'
  end
  if position ~= nil then
    local normalizedPosition, positionErr = normalizeVector3Spec(position, positionPath)
    if not normalizedPosition then
      return nil, positionErr
    end
    position = normalizedPosition
  end
  if rotation ~= nil then
    local rotationErr
    rotation, rotationErr = normalizeRotationSpec(rotation, rotationPath)
    if rotation == nil then
      return nil, rotationErr
    end
  end
  return {
    targetKind = targetInfo.targetKind,
    targetValue = targetInfo.targetValue,
    position = position or { x = 0, y = 0, z = 0 },
    rotation = rotation,
  }, nil
end

local function normalizeAttachEntry(entry, path)
  if type(entry) ~= 'table' then
    return nil, path .. ': expected tuple array'
  end
  local okLength, lengthErrors = tuple_contract.validateArity(entry, path, 4)
  if not okLength then return nil, lengthErrors[1] end
  -- entry[1] = source key (anchor ref), entry[2] = replacement target
  local sourceKey = entry[1]
  if type(sourceKey) ~= 'string' or sourceKey == '' then
    return nil, path .. '[1]: expected source record id or mesh path string'
  end
  local target, err = normalizeRelativeTarget(entry[2], entry[3], entry[4],
    path .. '[2]', path .. '[3]', path .. '[4]')
  if target == nil then return nil, err end
  target.sourceKey = sourceKey
  return target, nil
end
local function assignRelativeSlots(entries)
  local counts = {}
  for i = 1, #entries do
    local entry = entries[i]
    local sourceRecordId = tostring(entry.sourceRecordId)
    local nextIndex = (counts[sourceRecordId] or 0) + 1
    counts[sourceRecordId] = nextIndex
    entry.slot = 'r:' .. sourceRecordId .. ':' .. tostring(nextIndex)
  end
end
local function appendModelSelectionRecords(out, entry, byType, typeOrder, typeName)
  local count = 0
  if typeName then
    local records = byType and byType[typeName] or nil
    for i = 1, #(records or {}) do
      count = count + 1
      local selectionEntry = copyObject(entry)
      selectionEntry.sourceKeyKind = 'record_id'
      selectionEntry.sourceRecordId = records[i]
      selectionEntry.sourceExpandedFromModelPath = true
      out[#out + 1] = selectionEntry
    end
    return count
  end
  for i = 1, #(typeOrder or {}) do
    local records = byType and byType[typeOrder[i]] or nil
    for j = 1, #(records or {}) do
      count = count + 1
      local selectionEntry = copyObject(entry)
      selectionEntry.sourceKeyKind = 'record_id'
      selectionEntry.sourceRecordId = records[j]
      selectionEntry.sourceExpandedFromModelPath = true
      out[#out + 1] = selectionEntry
    end
  end
  return count
end
local function appendSelectionEntry(out, entry, recordCtx, typeName, path)
  if entry.sourceKeyKind ~= 'model_path' then
    out[#out + 1] = copyObject(entry)
    return true, nil
  end
  if not (recordCtx and recordCtx.resolveMeshTypes) then
    return nil, path .. ': mesh path resolution is unavailable'
  end
  local byType, err = recordCtx.resolveMeshTypes(entry.sourceRecordId)
  local count = appendModelSelectionRecords(
    out,
    entry,
    byType,
    recordCtx.modelRecordTypeOrder,
    typeName
  )
  if count == 0 then
    return nil, path .. ': mesh path matches no supported record ids (' .. tostring(err or 'unknown_mesh_path') .. ')'
  end
  return true, nil
end
local function buildSelectionEntries(entries, recordCtx, typeName, actionPath)
  local selectionEntries = {}
  for i = 1, #entries do
    local ok, err = appendSelectionEntry(
      selectionEntries,
      entries[i],
      recordCtx,
      typeName,
      tostring(actionPath) .. '.attach['
        .. tostring(entries[i].authoredTupleIndex or i) .. ']'
    )
    if not ok then return nil, { err } end
  end
  return selectionEntries, nil
end
local function lowerRelativeAttachSpec(spec, actionId, tuples, recordCtx, diagnostics, compileCtx)
  local actionPath = authored_path.authoredActionPath(compileCtx, actionId)
  local publicSelect = spec.select or {}
  -- Preserve duplicate source-key tuples so one anchor can receive multiple
  -- attachments.
  local grouped = {}
  local skipSummary = makeSkipSummary(actionId, 'attach', diagnostics)
  local function lowerTuple(normalized)
    if normalized.errors then return nil, normalized.errors end
    local path = authored_path.authoredTuplePath(compileCtx, actionId, 'attach', normalized)
    local sourceIndex = normalized.sourceIndex
    local targetType
    if normalized.targetKind == 'model_path' then
      local lookup = type(compileCtx) == 'table'
          and type(compileCtx.modelExists) == 'function'
          and compileCtx.modelExists
        or model_path_lookup.modelExists
      local targetExists, targetPath, lookupErr = lookup(normalized.targetValue)
      if lookupErr then
        recordSkippedPlaceTarget(path .. '[2]', targetPath or normalized.targetValue, 'replacement target',
          'model lookup failed in VFS: ' .. tostring(lookupErr), skipSummary)
        return true, nil
      end
      if not targetExists then
        recordSkippedPlaceTarget(path .. '[2]', targetPath or normalized.targetValue, 'replacement target',
          'model missing in VFS', skipSummary)
        return true, nil
      end
    else
      local targetErr
      targetType, targetErr = resolvePlacedRecordType(recordCtx, normalized.targetValue)
      if not targetType then
        recordSkippedPlaceTarget(path .. '[2]', normalized.targetValue, 'replacement target', targetErr, skipSummary)
        return true, nil
      end
    end
    if normalized.selectorErrors then return nil, normalized.selectorErrors end
    local parsed = normalized.parsed
    local inferredTypes
    if compileCtx.isChild and parsed.sourceKeyKind == 'model_path' then
      inferredTypes = compileCtx.parentOutputTypes
      if type(inferredTypes) ~= 'table' then
        return nil, {path .. ': inherited model selector requires known parent output types'}
      end
    elseif compileCtx.loadDecision == 'split' then
      local splitTypes = splitAllowedTypes(spec.select)
      inferredTypes = next(splitTypes) ~= nil and target_lowering.resolveSelectorTypesOrSkip(parsed, {
        recordCtx = recordCtx,
        path = path .. '[1]',
        allowedTypes = splitTypes,
        allowedMeshTypes = splitTypes,
        typeLabel = 'runtime-only attach source types',
        selectorLabel = 'source selector',
      }) or nil
    else
      inferredTypes = target_lowering.resolveSelectorTypesOrSkip(parsed, {
        recordCtx = recordCtx,
        path = path .. '[1]',
        allowedMeshTypes = ALLOWED_MESH_SOURCE_TYPES,
        typeLabel = 'supported attach source types',
        selectorLabel = 'source selector',
        skipReport = skipSummary,
      })
    end
    if not inferredTypes then
      return true, nil
    end
    local okEntries, entryErrors = target_lowering.appendTypedEntries(grouped, parsed, inferredTypes, function()
      return {
        authoredTupleIndex = sourceIndex,
        targetKind = normalized.targetKind,
        targetValue = normalized.targetValue,
        targetType = targetType,
        position = normalized.position,
        rotation = normalized.rotation,
      }, nil
    end, {
      predicates = normalized.predicates,
      path = path,
    })
    if not okEntries then
      return nil, entryErrors
    end
    return true, nil
  end
  for i = 1, #tuples do
    local ok, errors = lowerTuple(tuples[i])
    if not ok then return nil, errors end
  end
  selector_skip_report.flush(skipSummary)
  if not next(grouped) then
    if compileCtx.loadDecision == 'split' then
      return {}, nil
    end
    if compileCtx.isChild and type(compileCtx.parentOutputTypes) == 'table'
        and next(compileCtx.parentOutputTypes) == nil then
      return {}, nil
    end
    selector_skip_report.emitNoTargets(skipSummary, {
      path = actionPath .. '.attach',
      code = 'attach_no_sources_resolved',
      message = 'attach action was skipped because no attach source selector resolved',
      reason = 'no attach source selector resolved',
    })
    return {}, nil
  end
  local disableOriginal = spec.options and spec.options.disableOriginal == true
  local loweredList = {}
  for _, inferredType in ipairs(sortedKeys(grouped)) do
    if inferredType == 'Container' and spec.options and spec.options.transferContents == false then
      return nil, {actionPath .. '.attach: Container replacement requires preserving inventory; transferContents=false is unsupported'}
    end
    local entries = grouped[inferredType]
    assignRelativeSlots(entries)
    local inheritedMesh = false
    if compileCtx.isChild then
      for _, entry in ipairs(entries) do
        if entry.sourceKeyKind == 'model_path' then inheritedMesh = true; break end
      end
    end
    local selectionEntries
    if not inheritedMesh then
      local selectionErrors
      selectionEntries, selectionErrors = buildSelectionEntries(
        entries, recordCtx, inferredType, actionPath)
      if not selectionEntries then return nil, selectionErrors end
    end
    local lowered = compiledSpec(spec)
    lowered.disableOriginal = nil
    lowered.id = (#loweredList == 0 and actionId) or (tostring(actionId) .. ':' .. tostring(inferredType):lower())
    lowered.select = publicSelect
    lowered.program = buildProgram('relative', copyPlacementEntries(entries), {
      disableOriginal = disableOriginal,
    })
    local creatureValid, creatureError = type_capabilities.validateCreatureSources(lowered.program)
    if not creatureValid then
      return nil, {actionPath .. '.attach: ' .. tostring(creatureError)}
    end
    if compileCtx.isChild then lowered.program.inheritedSource = true end
    local directTargetPlan = selectionEntries and direct_targets.build(
      selectionEntries, {recordCtx = recordCtx}) or nil
    loweredList[#loweredList + 1] = familyProgram(lowered, {
      candidateTypes = singleCandidateType(inferredType),
      resolvedSelection = selectionEntries
        and target_lowering.resolvedSelection(selectionEntries, publicSelect, recordCtx) or nil,
      directTargets = directTargetPlan,
    })
  end
  return loweredList, nil
end

local function lowerInheritedAttachSpec(spec, actionId, recordCtx, compileCtx)
  local path = authored_path.authoredActionPath(compileCtx, actionId)
  local targets = spec.payloadKind == 'direct' and {spec.payload} or spec.payload
  local targetTypes = {}
  for i, target in ipairs(targets) do
    local tuplePath = authored_path.authoredTuplePath(compileCtx, actionId, 'attach', target)
    if target.targetKind == 'record_id' then
      local reason
      targetTypes[i], reason = resolvePlacedRecordType(recordCtx, target.targetValue)
      if targetTypes[i] == nil then return nil, {tuplePath .. '[1]: ' .. tostring(reason)} end
    else
      local lookup = type(compileCtx.modelExists) == 'function'
        and compileCtx.modelExists or model_path_lookup.modelExists
      local exists, _, reason = lookup(target.targetValue)
      if not exists or reason then
        return nil, {tuplePath .. '[1]: model is unavailable: ' .. tostring(reason or target.targetValue)}
      end
    end
  end
  local types = compileCtx.parentOutputTypes
  if type(types) ~= 'table' then
    return nil, {path .. ': inherited attach requires known parent output types'}
  end
  -- An exact-record selector narrows the inherited anchors before they reach
  -- these per-type programs. Do not create incompatible typed branches: the
  -- shared selection compiler treats an empty type intersection as an error.
  types = selectedParentTypes(types, spec.select, recordCtx)
  if types.Container and spec.options and spec.options.transferContents == false then
    return nil, {path .. ': Container replacement requires preserving inventory; transferContents=false is unsupported'}
  end
  local rows = {}
  for _, typeName in ipairs(sortedKeys(types)) do
    local entries = {}
    for i, target in ipairs(targets) do
      -- A single unfiltered entry uses the original fast-path program. A
      -- translator may supply a filtered inherited row directly, which still
      -- needs parent-output matching during capture.
      local singleFastPath = #targets == 1 and target.predicates == nil
      entries[i] = {
        sourceRecordId = 'inherited',
        sourceKeyKind = singleFastPath and 'record_id' or 'inherited',
        inferredType = typeName, targetKind = target.targetKind,
        targetValue = target.targetValue, targetType = targetTypes[i],
        position = copyPosition(target.position), rotation = copyRotation(target.rotation),
        filters = target.predicates and copyArray(target.predicates) or nil,
        slot = 'r:inherited:' .. tostring(i),
      }
    end
    local program = buildProgram('relative', entries, {
      disableOriginal = spec.options and spec.options.disableOriginal == true,
    })
    program.inheritedAnchor = true
    local claims, claimError = type_capabilities.claimsForProgram(program)
    if claims == nil then return nil, {path .. ': ' .. tostring(claimError)} end
    local lowered = compiledSpec(spec)
    lowered.program = program
    lowered.select = spec.select
    rows[#rows + 1] = familyProgram(lowered, {
      candidateTypes = singleCandidateType(typeName),
    })
  end
  return rows, nil
end
function M.prepareAction(input, queries, ctx)
  if input.payloadKind == 'choice' then return choice_compile.prepare(input, queries, ctx) end
  local actionId = resolveActionId(input, ctx, 'place_ref')
  local path = authored_path.authoredActionPath(ctx, actionId)
  local options = input.options == nil and {} or input.options
  if type(options) ~= 'table' then return nil, {path .. '.options: expected object'} end
  for key in pairs(options) do
    if key ~= 'disableOriginal' and key ~= 'instanceKey' and key ~= 'targetTypes' and key ~= 'transferContents' then
      return nil, {path .. '.options.' .. tostring(key) .. ': is not allowed'}
    end
  end
  if options.transferContents ~= nil and (input.verb ~= 'attach' or type(options.transferContents) ~= 'boolean') then
    return nil, {path .. '.transferContents: expected an attachment boolean'}
  end
  if options.instanceKey ~= nil and (input.verb ~= 'place' or input.payloadKind ~= 'tuples'
      or type(options.instanceKey) ~= 'string' or options.instanceKey == ''
      or type(input.payload) ~= 'table' or #input.payload ~= 1) then
    return nil, {path .. '.options.instanceKey: requires a non-empty key and one absolute placement tuple'}
  end
  local select = input.select or {}
  if select.type ~= nil then return nil, {path .. '.select.type: is not allowed'} end
  if input.verb == 'attach' and input.payloadKind == 'direct'
      and ctx and ctx.isChild == true then
    local payload = input.payload
    local tuplePath = authored_path.authoredTuplePath(ctx, actionId, 'attach', payload)
    local target, targetError = normalizeRelativeTarget(payload.target, payload.offset, payload.rotation,
      tuplePath .. '[1]', tuplePath .. '[2]', tuplePath .. '[3]')
    if target == nil then return nil, {targetError} end
    target.sourceIndex = payload.sourceIndex
    input.payload = target
    if target.targetKind == 'record_id' then queries.recordIds[target.targetValue:lower()] = true end
    return input
  end
  if input.verb == 'attach' and input.payloadKind == 'inherited_tuples'
      and ctx and ctx.isChild == true then
    for i, tuple in ipairs(input.payload) do
      local tuplePath = authored_path.authoredTuplePath(ctx, actionId, 'attach', tuple)
      local target, targetError = normalizeRelativeTarget(
        tuple.values[1], tuple.values[2], tuple.values[3],
        tuplePath .. '[1]', tuplePath .. '[2]', tuplePath .. '[3]')
      if target == nil then return nil, {targetError} end
      target.sourceIndex, target.predicates = tuple.sourceIndex, tuple.predicates
      input.payload[i] = target
      if target.targetKind == 'record_id' then queries.recordIds[target.targetValue:lower()] = true end
    end
    return input
  end
  if input.verb == 'place' then
    if select.cell == nil then return nil, {path .. '.select.cell: required for absolute placement'} end
    local valid, err = cell_selection.validateExactDestinationSpec(select.cell, path .. '.select.cell')
    if not valid then return nil, {err} end
    if select.recordId or #(ctx and ctx.selectPredicates or {}) > 0 then
      return nil, {path .. '.select: absolute place_ref only supports cell selection'}
    end
  elseif input.verb == 'attach' then
    if select.recordId then return nil, {path .. '.select: attach infers exact anchor record ids from source keys'} end
  else return nil, {path .. ': expected place or attach verb payload'} end
  for i = 1, #input.payload do
    local tuple = input.payload[i]
    local tuplePath = authored_path.authoredTuplePath(ctx, actionId, input.verb, tuple)
    local entry, err
    if input.verb == 'place' and #(tuple.predicates or {}) > 0 then
      err = tuplePath .. ': predicate annotations are not supported for absolute place tuples'
    else
      local normalize = input.verb == 'place' and normalizePlaceEntry or normalizeAttachEntry
      entry, err = normalize(tuple.values, tuplePath)
    end
    if not entry then
      entry = {errors = {err}}
    else
      if input.verb == 'attach' then
        local parsed, errors = target_lowering.parseSelector(tuplePath .. '[1]', entry.sourceKey, {allowMeshPaths = true})
        entry.selectorErrors = errors
        entry.parsed, entry.sourceKey = parsed, nil
        local meshTypes = (ctx and ctx.loadDecision == 'split')
          and splitAllowedTypes(input.select)
          or ALLOWED_MESH_SOURCE_TYPES
        if next(meshTypes) ~= nil then
          target_lowering.collectParsedSelectorQuery(parsed, queries, {meshTypes = meshTypes})
        end
      end
      if entry.targetKind == 'record_id' then queries.recordIds[entry.targetValue:lower()] = true end
    end
    entry.sourceIndex, entry.predicates = tuple.sourceIndex, tuple.predicates
    input.payload[i] = entry
  end
  return input
end
function M.compileAction(spec, ctx)
  if spec.payloadKind == 'choice' then return choice_compile.compile(spec, ctx) end
  local actionId = resolveActionId(spec, ctx, 'place_ref')
  local diagnostics = {
    diagnosticCollector = ctx and ctx.diagnosticCollector or nil,
    sourcePath = ctx and ctx.sourcePath or nil,
  }
  local recordCtx = target_lowering.requireRecordContext(ctx)
  if spec.verb == 'attach' and (spec.payloadKind == 'direct' or spec.payloadKind == 'inherited_tuples')
      and ctx and ctx.isChild == true then
    return lowerInheritedAttachSpec(spec, actionId, recordCtx, ctx)
  end
  if spec.verb == 'place' then
    return lowerAbsolutePlaceSpec(spec, actionId, spec.payload, recordCtx, diagnostics, ctx)
  end
  return lowerRelativeAttachSpec(spec, actionId, spec.payload, recordCtx, diagnostics, ctx)
end
return M
