local M = {}
M.publicFields = { 'modify' }
local cell_selection = require('scripts.mom.compiler.cell_selection')
local keyed_targets = require('scripts.mom.compiler.keyed_targets')
local modify_patch = require('scripts.mom.actions.modify_ref.patch')
local authored_path = require('scripts.mom.compiler.authored_path')
local tuple_contract = require('scripts.mom.compiler.tuple_contract')
local diagnostic_emit = require('scripts.mom.compiler.diagnostic_emit')
local copyObject = require('scripts.mom.common.tables').copyObject
local selector_skip_report = require('scripts.mom.compiler.selector_skip_report')
local source_ir = require('scripts.mom.compiler.source_ir')
local target_lowering = require('scripts.mom.compiler.target_lowering')
local compiledSpec = source_ir.compiledSpec
local resolveActionId = authored_path.resolveActionId
local mergePublicSelect = source_ir.mergePublicSelect
local OWNER_RECORD_TYPES = { NPC = true }
local OWNER_FACTION_TYPES = { Faction = true }
local PROGRAM_KEYS = {
  basePatch = true,
  matchPlan = true,
  invalidatesCellCaches = true,
}
local target_match_plan = require('scripts.mom.contracts.target_match_plan')
local PROGRAM_PATCH_KEYS = {
  enabled = true,
  owner = true,
  position = true,
  rotation = true,
  scale = true,
  relocate = true,
}

local function collectPatchClaims(patch, claims)
  for key in pairs(patch or {}) do
    if key == 'relocate' then
      claims['ref.position'] = true
      if patch.relocate and patch.relocate.rotation ~= nil then
        claims['ref.rotation'] = true
      end
    else
      claims['ref.' .. tostring(key)] = true
    end
  end
end

-- Build the indexed match plan and collect claims from each keyed patch.
local function familyProgram(spec, basePatch, keyedEntries, fields)
  local claimSet = {}
  collectPatchClaims(basePatch, claimSet)
  local invalidatesCellCaches = basePatch and basePatch.relocate ~= nil or false
  local matchPlan = nil
  if #(keyedEntries or {}) > 0 then
    local plan, planError = target_match_plan.build(keyedEntries, function(entry)
      local patch = modify_patch.copyPatch(entry) or {}
      collectPatchClaims(patch, claimSet)
      if patch.relocate ~= nil then invalidatesCellCaches = true end
      return {patch = patch}
    end)
    if plan == nil then error(planError, 0) end
    matchPlan = plan
  end
  local keys = {}
  for key in pairs(claimSet) do keys[#keys + 1] = key end
  table.sort(keys)
  spec.program = {
    basePatch = modify_patch.copyPatch(basePatch),
    matchPlan = matchPlan,
    invalidatesCellCaches = invalidatesCellCaches or nil,
  }
  fields = fields or {}
  fields.claims = {keys = keys}
  fields.reversible = true
  return source_ir.familyProgram(spec, fields)
end

local function validateProgramPatch(patch, path, errors, actionId, H)
  if patch == nil then return nil end
  patch = H.requireObject(patch, path, errors, actionId)
  if patch then
    H.rejectUnknownObjectKeys(patch, PROGRAM_PATCH_KEYS, path, errors, actionId)
  end
  return patch
end

function M.validateProgram(program, errors, actionId, H)
  H.rejectUnknownKeys(program, PROGRAM_KEYS, errors, actionId)
  if program.basePatch == nil and program.matchPlan == nil then
    H.appendError(errors, actionId, 'expected basePatch or matchPlan')
  end
  validateProgramPatch(program.basePatch, 'basePatch', errors, actionId, H)
  if program.invalidatesCellCaches ~= nil and type(program.invalidatesCellCaches) ~= 'boolean' then
    H.appendError(errors, actionId, 'invalidatesCellCaches: expected boolean')
  end
  if program.matchPlan ~= nil then
    local valid, planError = target_match_plan.validate(program.matchPlan, 'matchPlan')
    if not valid then H.appendError(errors, actionId, planError) end
  end
end

local function appendQueryCellEntry(queryCellEntries, cellSpec)
  if type(queryCellEntries) ~= 'table' or type(cellSpec) ~= 'table' then return end
  queryCellEntries[#queryCellEntries + 1] = {
    key = cellSpec.key,
    id = cellSpec.id,
    isExterior = cellSpec.isExterior == true,
    worldspaceKey = cellSpec.worldspaceKey,
    gridX = cellSpec.gridX,
    gridY = cellSpec.gridY,
    packedCellKey = cellSpec.packedCellKey,
    interiorKey = cellSpec.interiorKey,
  }
end
local function compiledCellSpecFromEntry(entry)
  if not entry then return nil end
  return {
    key = entry.key,
    id = entry.id,
    isExterior = entry.isExterior == true,
    worldspaceKey = entry.worldspaceKey,
    gridX = entry.gridX,
    gridY = entry.gridY,
    packedCellKey = entry.packedCellKey,
    interiorKey = entry.interiorKey,
  }
end
-- Parse target strings that must use the keyed path.
-- Plain record ids remain broadcast targets. Mesh-path selectors and record ids
-- with a keyed position suffix are per-object keyed targets.
local function parseKeyedTarget(target)
  local parsed, parseErr = keyed_targets.parseSelectorKey(target, { allowMeshPaths = true })
  if not parsed then
    return nil, parseErr, type(target) == 'string' and target:find(',%s*%(') ~= nil
  end
  return parsed, nil, parsed.sourceKeyKind == 'model_path' or parsed.sourcePosition ~= nil
end
local function ownershipRecordReason(recordCtx, recordId, typeSet, expectedLabel)
  local exists, err = recordCtx.recordExists(recordId, typeSet)
  if exists then return nil end
  if err == 'wrong_record_type' then
    return tostring(recordId) .. ' is not ' .. tostring(expectedLabel)
  end
  if err == 'invalid_record_id' then
    return tostring(recordId) .. ' does not exist'
  end
  return tostring(err or 'unavailable')
end
local function ownershipPatchSkipReason(patch, recordCtx)
  local owner = patch and patch.owner or nil
  if not owner or owner.clear == true then return nil end
  if owner.recordId ~= nil then
    local reason = ownershipRecordReason(recordCtx, owner.recordId, OWNER_RECORD_TYPES, 'an NPC owner record')
    if reason then return 'owner.recordId ' .. reason end
  end
  if owner.factionId ~= nil then
    local reason = ownershipRecordReason(recordCtx, owner.factionId, OWNER_FACTION_TYPES, 'a faction owner record')
    if reason then return 'owner.factionId ' .. reason end
  end
  return nil
end
local function warnSkippedOwnerPatch(actionId, path, reason, diagnostics)
  local message = 'modify owner patch cannot resolve owner record ('
    .. tostring(reason or 'owner patch is invalid') .. ')'
  diagnostic_emit.reportSelectorUnresolved(
    diagnostics and diagnostics.diagnosticCollector or nil,
    {
    sourcePath = diagnostics and diagnostics.sourcePath or nil,
    family = 'modify_ref',
    actionId = actionId,
    path = path,
    code = 'owner_record_unresolved',
    message = message,
    logMessage = 'Action ' .. tostring(actionId)
      .. '.modify skipped ' .. tostring(path) .. ': ' .. message,
  })
end
function M.prepareAction(input, queries, ctx)
  local actionId = resolveActionId(input, ctx, 'modify_ref')
  local actionPath = authored_path.authoredActionPath(ctx, actionId)
  if input.select and input.select.type ~= nil then
    return nil, {actionPath .. '.select.type: is not allowed'}
  end
  if input.payloadKind == 'direct' then
    local patch, err = modify_patch.normalizePatch(input.payload, actionPath .. '.modify', true)
    if not patch then return nil, {err} end
    input.mode, input.payload = 'direct', patch
    return input
  end
  local mode, rows = nil, input.payload
  for i = 1, #rows do
    local tuple = rows[i]
    local values = tuple.values
    local path = authored_path.authoredTuplePath(ctx, actionId, 'modify', tuple)
    local valid, errors = tuple_contract.validateArity(values, path, 2)
    if not valid then return nil, errors end
    local target, patch = values[1], values[2]
    if type(target) ~= 'string' or target == '' then return nil, {path .. '[1]: expected target string'} end
    if type(patch) ~= 'table' then return nil, {path .. '[2]: expected patch object'} end
    local parsed, parseErr, keyed = parseKeyedTarget(target)
    if keyed and not parsed then return nil, {path .. '[1]: ' .. tostring(parseErr)} end
    local rowMode = keyed and 'keyed' or 'broadcast'
    if mode and mode ~= rowMode then return nil, {actionPath .. '.modify: cannot mix broadcast and keyed targets in one action'} end
    mode = rowMode
    tuple.values = nil
    tuple.patch, tuple.parsed = patch, parsed
    if keyed then target_lowering.collectParsedSelectorQuery(parsed, queries)
    else
      tuple.recordId = target:lower()
      queries.recordIds[tuple.recordId] = true
    end
  end
  if mode == 'broadcast' and #rows > 1 then
    return nil, {actionPath .. '.modify: multiple broadcast tuples in one action; use separate actions or keyed targets'}
  end
  for i = 1, #rows do
    local tuple = rows[i]
    local path = authored_path.authoredTuplePath(ctx, actionId, 'modify', tuple)
    local normalized, err = modify_patch.normalizePatch(tuple.patch, path .. '[2]', mode == 'broadcast')
    tuple.patch, tuple.errors = normalized, err and {err} or nil
  end
  input.mode = mode
  return input
end
function M.compileAction(spec, ctx)
  local actionId = resolveActionId(spec, ctx, 'modify_ref')
  local actionPath = authored_path.authoredActionPath(ctx, actionId)
  local recordCtx = nil
  local function requireRecordContext()
    if recordCtx == nil then
      recordCtx = target_lowering.requireRecordContext(ctx)
    end
    return recordCtx
  end
  local function ownerPatchSkipReason(patch)
    local owner = patch and patch.owner or nil
    if owner == nil or owner.clear == true then return nil end
    return ownershipPatchSkipReason(patch, requireRecordContext())
  end
  local function compileRelocation(basePatch)
    local queryCellEntries = {}
    if basePatch.relocate ~= nil and (basePatch.position ~= nil or basePatch.rotation ~= nil) then
      return nil, nil, {
        actionPath .. '.modify: relocate cannot be combined with top-level position or rotation; put destination transform under modify.relocate'
      }
    end
    if basePatch.relocate ~= nil then
      basePatch = copyObject(basePatch)
      local relocateSelection, relocateErrors = cell_selection.compile(basePatch.relocate.cell, actionId, {
        cellIndex = ctx and ctx.cellIndex or nil,
        requireCellIndex = ctx and ctx.requireCellIndex or nil,
        workspace = ctx and ctx.workspace or nil,
        metrics = ctx and ctx.metrics or nil,
        path = actionPath .. '.modify.relocate.cell',
        requireExplicit = true,
        universe = 'required',
      })
      if relocateErrors then return nil, nil, relocateErrors end
      if not relocateSelection or relocateSelection.count ~= 1 then
        return nil, nil, {
          actionPath .. '.modify.relocate.cell: must resolve to exactly one cell'
        }
      end
      local relocateEntry = cell_selection.singleUniverseEntry(relocateSelection)
      if not relocateEntry then
        return nil, nil, {
          actionPath .. '.modify.relocate.cell: compiler could not resolve destination metadata'
        }
      end
      basePatch.relocate = {
        cell = compiledCellSpecFromEntry(relocateEntry),
        position = basePatch.relocate.position,
        rotation = basePatch.relocate.rotation,
      }
      appendQueryCellEntry(queryCellEntries, basePatch.relocate.cell)
    end
    return basePatch, queryCellEntries, nil
  end
  local diagnostics = {
    diagnosticCollector = ctx and ctx.diagnosticCollector or nil,
    sourcePath = ctx and ctx.sourcePath or nil,
  }
  local skipReport = selector_skip_report.new({
    family = 'modify_ref',
    actionId = actionId,
    verb = 'modify',
    diagnostics = diagnostics,
    code = 'selector_key_unresolved',
  })
  local publicSelect = spec.select or {}
  if spec.mode == 'direct' then
    local basePatch, queryCellEntries, relocationErrors = compileRelocation(spec.payload)
    if relocationErrors then return nil, relocationErrors end
    local ownerReason = ownerPatchSkipReason(basePatch)
    if ownerReason then
      warnSkippedOwnerPatch(actionId, actionPath .. '.modify', ownerReason, diagnostics)
      return {}, nil
    end
    local lowered = compiledSpec(spec)
    lowered.select = publicSelect
    return {familyProgram(lowered, basePatch, nil, {queryCells = queryCellEntries})}, nil
  end
  local tuples = spec.payload
  if spec.mode == 'broadcast' then
    if tuples[1].errors then return nil, tuples[1].errors end
    local recordId = tuples[1].recordId
    local basePatch = tuples[1].patch
    local queryCellEntries, relocationErrors
    basePatch, queryCellEntries, relocationErrors = compileRelocation(basePatch)
    if relocationErrors then return nil, relocationErrors end
    local ownerReason = ownerPatchSkipReason(basePatch)
    if ownerReason then
      warnSkippedOwnerPatch(
        actionId,
        actionPath .. '.modify[' .. tostring(tuples[1].sourceIndex) .. '][2]',
        ownerReason,
        diagnostics
      )
      return {}, nil
    end
    local lowered = compiledSpec(spec)
    lowered.select = mergePublicSelect(publicSelect, {
      recordId = { recordId },
    })
    return {familyProgram(lowered, basePatch, nil, {queryCells = queryCellEntries})}, nil
  end
  -- Keyed path: specific instance targets.
  -- Preserve tuple-local predicates by lowering entries directly rather than
  -- collapsing the authored tuples into a keyed map.
  local grouped = {}
  for i = 1, #tuples do
    local kt = tuples[i]
    if kt.errors then return nil, kt.errors end
    local path = actionPath .. '.modify[' .. tostring(kt.sourceIndex) .. ']'
    local parsed = kt.parsed
    local patch = kt.patch
    local ownerReason = ownerPatchSkipReason(patch)
    if ownerReason then
      warnSkippedOwnerPatch(actionId, path .. '[2]', ownerReason, diagnostics)
    else
      local typeNames = target_lowering.resolveSelectorTypesOrSkip(parsed, {
        recordCtx = requireRecordContext(),
        path = path .. '[1]',
        selectorLabel = 'target selector',
        skipReport = skipReport,
      })
      if typeNames then
        local okEntries, entryErrors = target_lowering.appendTypedEntries(grouped, parsed, typeNames, function()
          local entry = modify_patch.copyPatchInto({}, patch)
          return entry, nil
        end, {
          predicates = kt.predicates,
          path = path,
        })
        if not okEntries then return nil, entryErrors end
      end
    end
  end
  selector_skip_report.flush(skipReport)
  if not next(grouped) then
    target_lowering.emitNoResolvedTargets({
      skipReport = skipReport,
      path = actionPath .. '.modify',
      code = 'no_keyed_targets_resolved',
      message = 'modify action was skipped because no keyed target selector resolved',
      reason = 'no keyed target selector resolved',
    })
    return {}, nil
  end
  local targetStatus, lowered, targetErrors, entries, metadata = target_lowering.finalizeResolvedEntries(grouped, spec, publicSelect, {
    payloadKey = 'modify',
    recordCtx = requireRecordContext(),
    path = actionPath .. '.modify',
    pathPrefix = actionPath .. '.modify',
  })
  if targetStatus == 'skip' then return {}, nil end
  if targetStatus == 'error' then return nil, targetErrors end
  local queryCellEntries = {}
  -- Check for relocate in any per-object patch.
  for i = 1, #entries do
    if entries[i].relocate ~= nil then
      return nil, {
        actionPath .. '.modify: relocate in per-object keyed patches is not supported; use a separate broadcast action'
      }
    end
  end
  metadata.queryCells = queryCellEntries
  return {familyProgram(lowered, nil, entries, metadata)}, nil
end
return M
