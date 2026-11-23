-- Shared target lowering for action-family compilers. Resolves record/model
-- selectors into typed entries and emits bounded diagnostics for skipped targets.
local M = {}

local direct_targets = require('scripts.mom.compiler.direct_targets')
local source_ir = require('scripts.mom.compiler.source_ir')
local keyed_targets = require('scripts.mom.compiler.keyed_targets')
local selector_resolution = require('scripts.mom.compiler.selector_resolution')
local selector_skip_report = require('scripts.mom.compiler.selector_skip_report')
local tables = require('scripts.mom.common.tables')
local sortedKeys = tables.sortedKeys
local copyArray = tables.copyArray
-- Keep host lookup lazy: importing this module never acquires OpenMW/index state.
function M.requireRecordContext(ctx)
  if type(ctx) == 'table' and type(ctx.recordCtx) == 'table' then
    return ctx.recordCtx
  end
  local resolve = type(ctx) == 'table' and ctx.requireRecordContext or nil
  assert(type(resolve) == 'function',
    'action compiler requires requireRecordContext()')
  return resolve()
end

function M.flattenGroupedEntries(grouped)
  local types = sortedKeys(grouped)
  local flattened = {}
  for i = 1, #types do
    local entries = grouped[types[i]] or {}
    for j = 1, #entries do
      flattened[#flattened + 1] = entries[j]
    end
  end
  return flattened
end

function M.attachEntryPredicates(predicates, entry)
  if not predicates or #predicates == 0 then return end
  entry.filters = copyArray(predicates)
end

local attachEntryPredicates = M.attachEntryPredicates
local flattenGroupedEntries = M.flattenGroupedEntries

local function addMeshPathQuery(queries, modelKey, typeSet)
  if not modelKey then return end
  queries = queries or { recordIds = {}, meshPathTypes = {} }
  queries.meshPathTypes = queries.meshPathTypes or {}
  local existing = queries.meshPathTypes[modelKey]
  if existing == true then return end
  if type(typeSet) ~= 'table' or next(typeSet) == nil then
    queries.meshPathTypes[modelKey] = true
    return
  end
  local constrained = existing
  if type(constrained) ~= 'table' then
    constrained = {}
    queries.meshPathTypes[modelKey] = constrained
  end
  for typeName in pairs(typeSet) do
    constrained[typeName] = true
  end
end


local function appendGrouped(grouped, typeName, entry)
  local bucket = grouped[typeName]
  if not bucket then
    bucket = {}
    grouped[typeName] = bucket
  end
  bucket[#bucket + 1] = entry
end

local function selectorValue(parsed)
  return parsed and (parsed.rawKey or parsed.sourceValue) or nil
end

local function skipReportFromOptions(opts)
  opts = opts or {}
  return selector_skip_report.new({
    family = opts.family,
    actionId = opts.actionId,
    verb = opts.verb,
    diagnosticCollector = opts.diagnosticCollector,
    sourcePath = opts.sourcePath,
    warnTag = opts.warnTag,
    code = opts.code or 'selector_key_unresolved',
  })
end

local function recordSelectorUnresolved(parsed, reason, opts)
  opts = opts or {}
  local report = opts.skipReport or skipReportFromOptions(opts)
  selector_skip_report.record(
    report,
    opts.path,
    selectorValue(parsed),
    opts.selectorLabel or opts.targetLabel or 'selector',
    reason
  )
  if opts.skipReport == nil then
    selector_skip_report.flush(report)
  end
end

local function copySelectorFacts(entry, parsed, typeName)
  entry.sourceRecordId = entry.sourceRecordId or parsed.sourceValue
  entry.sourceKeyKind = entry.sourceKeyKind or parsed.sourceKeyKind
  entry.sourcePosition = entry.sourcePosition or parsed.sourcePosition
  entry.inferredType = entry.inferredType or typeName
end

local function ensureQueryBuckets(queries)
  queries = queries or {}
  queries.recordIds = queries.recordIds or {}
  queries.meshPathTypes = queries.meshPathTypes or {}
  return queries
end

function M.collectParsedSelectorQuery(parsed, queries, opts)
  if type(parsed) ~= 'table' then return queries end
  queries = ensureQueryBuckets(queries)
  opts = opts or {}
  if parsed.sourceKeyKind == 'model_path' then
    addMeshPathQuery(
      queries,
      parsed.sourceValue,
      opts.meshTypes or opts.allowedMeshTypes or opts.allowedTypes
    )
  elseif parsed.sourceValue ~= nil then
    queries.recordIds[parsed.sourceValue] = true
  end
  return queries
end

function M.parseSelector(path, raw, opts)
  local parsed, parseErr = keyed_targets.parseSelectorKey(raw, opts)
  if not parsed then
    return nil, { tostring(path) .. ': ' .. tostring(parseErr) }
  end
  return parsed, nil
end

function M.resolveSelectorTypesOrSkip(parsed, opts)
  opts = opts or {}
  local typeSet, reason = keyed_targets.resolveSelectorTypes(parsed, opts)
  if typeSet then
    return typeSet, nil, false
  end
  recordSelectorUnresolved(parsed, reason, opts)
  return nil, nil, true
end

function M.appendTypedEntries(grouped, parsed, typeSet, buildEntry, opts)
  opts = opts or {}
  if type(typeSet) ~= 'table' then return true, nil end
  for _, typeName in ipairs(sortedKeys(typeSet)) do
    local entry, entryErr = buildEntry(parsed, typeName)
    if not entry then
      return nil, { entryErr or (tostring(opts.path or 'target') .. ': invalid target entry') }
    end
    copySelectorFacts(entry, parsed, typeName)
    if opts.predicates ~= nil then
      attachEntryPredicates(opts.predicates, entry)
    end
    appendGrouped(grouped, typeName, entry)
  end
  return true, nil
end

function M.emitNoResolvedTargets(opts)
  opts = opts or {}
  selector_skip_report.emitNoTargets(opts.skipReport or skipReportFromOptions(opts), {
    path = opts.path,
    code = opts.code,
    message = opts.message,
    reason = opts.reason,
  })
end

-- Build the final exact-ID arrays while resolved entries still own their type
-- facts. An explicit authored recordId remains authoritative and is resolved by
-- selection compilation; it must not be narrowed to the family's match targets.
function M.resolvedSelection(entries, publicSelect, recordCtx)
  if publicSelect and publicSelect.recordId ~= nil then return nil end
  local ids, byType, skipped, seen = {}, {}, {}, {}
  for i = 1, #entries do
    local entry = entries[i]
    local id = entry.sourceRecordId
    if not seen[id] then
      seen[id] = true
      local typeName, reason = entry.inferredType
      -- Mesh expansion establishes membership, not global ID uniqueness. This
      -- is the first uniqueness check for those IDs, not repeated inference of
      -- the already resolved record-selector path.
      if entry.sourceExpandedFromModelPath or typeName == nil then
        typeName, reason = recordCtx.resolveLiveRefType(id)
      end
      if typeName == nil or typeName == false then
        skipped[#skipped + 1] = {
          recordId = id,
          reason = typeName == false and 'ambiguous record type'
            or reason == 'not_live_ref_record' and 'record id is not selectable as a live ref'
            or reason or 'invalid record id',
        }
      else
        ids[#ids + 1] = id
        local bucket = byType[typeName] or {}
        byType[typeName] = bucket
        bucket[#bucket + 1] = id
      end
    end
  end
  table.sort(ids)
  local queries, types = {}, {}
  for _, typeName in ipairs(sortedKeys(byType)) do
    types[typeName] = true
    local bucket = byType[typeName]
    table.sort(bucket)
    for i = 1, #bucket do
      queries[#queries + 1] = {typeName = typeName, recordId = bucket[i]}
    end
  end
  return {exactIds = ids, exactIdQueries = queries, candidateTypes = types, skipped = skipped}
end

-- Stage boundaries return status, value, errors, then optional stage details.
-- Keep entries and existing metadata in fixed slots without a result wrapper.
---@return 'ok'|'skip'|'error' status
---@return table|nil spec
---@return string[]|nil errors
---@return table[]|nil entries
---@return table|nil metadata Fields: candidateTypes, resolvedSelection, directTargets.
function M.finalizeResolvedEntries(grouped, spec, publicSelect, opts)
  opts = opts or {}
  local recordCtx = assert(opts.recordCtx, 'target_lowering.finalizeResolvedEntries requires recordCtx')
  local entries = opts.entries or flattenGroupedEntries(grouped)
  if #entries == 0 then
    M.emitNoResolvedTargets(opts)
    return 'skip', nil, nil
  end
  local status, resolvedEntries, resolveErrors, candidateTypes = selector_resolution.resolveEntries(entries, {
    recordCtx = recordCtx,
    pathPrefix = opts.pathPrefix or opts.path or 'target',
  })
  if status ~= 'ok' then return status, nil, resolveErrors end
  local lowered = opts.lowered or source_ir.compiledSpec(spec)
  lowered.select = publicSelect
  local resolvedSelection = M.resolvedSelection(resolvedEntries, publicSelect, recordCtx)
  local directTargetPlan = nil
  if opts.attachDirectTargetPlan ~= false then
    directTargetPlan = direct_targets.build(
      resolvedEntries, {recordCtx = recordCtx})
  end
  return 'ok', lowered, nil, resolvedEntries, {
    candidateTypes = candidateTypes,
    resolvedSelection = resolvedSelection,
    directTargets = directTargetPlan,
  }
end

return M
