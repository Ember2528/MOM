-- Compiles selections from lowered action specs, combining exact-ID inference,
-- cell routes, predicate metadata, and query hints.
local M = {}
local authored_path = require('scripts.mom.compiler.authored_path')
local cell_selection = require('scripts.mom.compiler.cell_selection')
local selection_validation = require('scripts.mom.compiler.selection_validation')
local diagnostic_emit = require('scripts.mom.compiler.diagnostic_emit')
local predicate_contract = require('scripts.mom.contracts.predicate')
local ref_type_contract = require('scripts.mom.contracts.ref_type')
local compile_policy = require('scripts.mom.compiler.compile_policy')
local plain_data = require('scripts.mom.contracts.plain_data')
local cell_match_index = require('scripts.mom.contracts.cell_match_index')
local target_predicate_index = require('scripts.mom.contracts.target_predicate_index')
local tables = require('scripts.mom.common.tables')
local ref_selector = require('scripts.mom.contracts.ref_selector')
local copyArray = tables.copyArray
local sortedKeys = tables.sortedKeys

local function copySet(values)
  if not values then return nil end
  local out = {}
  for key, value in pairs(values) do
    if value then
      out[key] = true
    end
  end
  return next(out) and out or nil
end

local function normalizeInternalCandidateTypes(rawTypes, actionId, actionPath)
  if rawTypes == nil then return nil, nil end
  actionPath = actionPath or authored_path.fromActionId(actionId)
  local normalized = {}
  if type(rawTypes) == 'string' then
    if not ref_type_contract.contains(rawTypes) then
      return nil, { tostring(actionPath) .. '.select.candidateTypes: unsupported type ' .. tostring(rawTypes) }
    end
    normalized[rawTypes] = true
  elseif type(rawTypes) == 'table' then
    for key, value in pairs(rawTypes) do
      local typeName = nil
      if value == true then
        typeName = key
      elseif type(key) == 'number' and type(value) == 'string' then
        typeName = value
      end
      if typeName ~= nil then
        if not ref_type_contract.contains(typeName) then
          return nil, { tostring(actionPath) .. '.select.candidateTypes: unsupported type ' .. tostring(typeName) }
        end
        normalized[typeName] = true
      end
    end
  else
    return nil, { tostring(actionPath) .. '.select.candidateTypes: expected type set' }
  end
  if next(normalized) == nil then
    return nil, nil
  end
  return normalized, nil
end

local function intersectTypeSets(current, incoming)
  if incoming == nil then return copySet(current) end
  if current == nil then return copySet(incoming) end
  local out = {}
  for typeName in pairs(current) do
    if incoming[typeName] == true then
      out[typeName] = true
    end
  end
  return next(out) and out or {}
end

local function reportUnresolved(node, compileCtx, actionPath, recordId, message)
  local actionId = node.id
  local detail = 'select.recordId ' .. tostring(recordId)
    .. ' cannot resolve to a selected record (' .. tostring(message) .. ')'
  diagnostic_emit.reportSelectorUnresolved(
    compileCtx.diagnosticCollector,
    {
      sourcePath = node.source and node.source.file or nil,
      actionId = actionId,
      path = tostring(actionPath) .. '.select.recordId',
      code = 'select_record_id_unresolved',
      message = detail,
      logMessage = 'Skipping ' .. tostring(actionPath)
        .. '.select.recordId: ' .. detail,
    }
  )
end

local function inferExactIdTypes(selectSpec, node, recordCtx, compileCtx, actionPath)
  local exactIds = compile_policy.normalizeExactIds(selectSpec and selectSpec.recordId)
  if exactIds == nil then return nil, nil, nil, nil, false end
  local candidateTypes = {}
  local exactIdsByType = {}
  local resolvedExactIds = {}
  local skipped = false
  for recordId in pairs(exactIds) do
    local resolvedType, err = recordCtx.resolveLiveRefType(recordId)
    if resolvedType == nil or resolvedType == false then
      skipped = true
      reportUnresolved(node, compileCtx, actionPath, recordId, (resolvedType == false and 'ambiguous record type')
        or (err == 'not_live_ref_record' and 'record id is not selectable as a live ref')
        or err
        or 'invalid record id')
    else
      candidateTypes[resolvedType] = true
      exactIdsByType[resolvedType] = exactIdsByType[resolvedType] or {}
      exactIdsByType[resolvedType][recordId] = true
      resolvedExactIds[recordId] = true
    end
  end
  if next(resolvedExactIds) == nil then
    return nil, nil, nil, nil, skipped
  end
  return candidateTypes, exactIdsByType, nil, resolvedExactIds, skipped
end

local function normalizePredicates(predicates)
  if not predicates or #predicates == 0 then return nil end
  return predicates
end

local function extractExcludedIds(predicates)
  if not predicates then return nil end
  local excluded = nil
  for i = 1, #predicates do
    local predicate = predicates[i]
    if predicate_contract.isRecordIdExclude(predicate) then
      local incoming = predicate.excludedIds
      if incoming ~= nil then
        excluded = excluded or {}
        for recordId in pairs(incoming) do excluded[recordId] = true end
      end
    end
  end
  return excluded and next(excluded) and excluded or nil
end

local function nonEmptySortedKeys(values)
  if not values then return nil end
  local firstKey = next(values)
  if firstKey == nil then return nil end
  local out = { firstKey }
  for key in next, values, firstKey do
    out[#out + 1] = key
  end
  table.sort(out)
  return out
end

local function appendExactIdQueries(out, typeName, ids)
  local recordIds = sortedKeys(ids)
  for i = 1, #recordIds do
    out[#out + 1] = {
      typeName = typeName,
      recordId = recordIds[i],
    }
  end
end

local function buildExactIdQueryList(exactIds, exactIdsByType, candidateTypeList)
  if not (exactIds and candidateTypeList) then return nil end
  local out = {}
  for i = 1, #candidateTypeList do
    local typeName = candidateTypeList[i]
    local ids = exactIdsByType and exactIdsByType[typeName] or exactIds
    if ids then
      appendExactIdQueries(out, typeName, ids)
    end
  end
  return #out > 0 and out or nil
end

local function buildCellProgram(selection)
  if selection == nil then return nil end
  local route = selection.route
  return {
    predicate = selection.predicate,
    route = route,
    routeIndex = cell_match_index.buildRoute(route),
    predicateIndex = cell_match_index.buildQuery(
      selection.predicate and selection.predicate.query or nil
    ),
    universe = selection.universe,
  }
end

local function finish(cellSelection, exactIds, exactQueries, predicates, candidateTypes, node, actionPath)
  local cell, cellErrors = plain_data.detach(buildCellProgram(cellSelection), {
    path = actionPath .. '.selection.cell',
  })
  if cellErrors then return 'error', nil, cellErrors end
  local excludedIds = sortedKeys(extractExcludedIds(predicates) or {})
  local selection = {
    exactIds = exactIds or {},
    exactIdQueries = exactQueries or {},
    cell = cell,
    predicates = predicates or {},
    predicateIndex = target_predicate_index.build(predicates),
    excludedIds = excludedIds,
    candidateTypes = candidateTypes or {},
    directTargets = node.directTargets or {},
    queryCells = node.queryCells or {},
  }
  local specificity = (cellSelection and cellSelection.exactCellCount or 0) > 0 and 100 or 0
  if exactIds ~= nil and #exactIds > 0 then specificity = specificity + 1000 + #exactIds end
  specificity = specificity + #(predicates or {}) * 10
  if #(candidateTypes or {}) > 0 then specificity = specificity + math.max(0, 10 - #candidateTypes) end
  return 'ok', selection, nil, {
    specificity = specificity,
    previsitEntries = cell_selection.previsitEntries(cellSelection),
  }
end

local function contains(values, expected)
  for _, value in ipairs(values) do if value == expected then return true end end
  return false
end

local FAMILY_TYPES = {
  kill_actor = {NPC = true, Creature = true},
  modify_inventory = {NPC = true, Creature = true, Container = true},
}

local function compileQuery(node, selectSpec, compileCtx, policy, actionPath)
  if policy.scope ~= 'ref' then
    return 'error', nil, {actionPath .. '.select: reference queries require a ref-targeting action'}
  end
  local query = selectSpec.query
  if selectSpec.recordId ~= nil then
    local extra, err = ref_selector.normalize({recordId = selectSpec.recordId}, actionPath .. '.select')
    if extra == nil then return 'error', nil, {err} end
    query = ref_selector.intersect(query, extra)
  end
  if query.none then return 'error', nil, {actionPath .. '.select: selector restrictions do not intersect'} end
  if query.contentFile and type(compileCtx.contentFileActive) == 'function' then
    local possible = false
    for _, filename in ipairs(query.contentFile) do
      -- A provider without a definite absence result cannot prove the query
      -- empty. Keep authored alternatives unchanged in the semantic query.
      if compileCtx.contentFileActive(filename) ~= false then possible = true; break end
    end
    if not possible then
      diagnostic_emit.reportSelectorUnresolved(compileCtx.diagnosticCollector, {
        sourcePath = node.source and node.source.file, actionId = node.id,
        path = actionPath .. '.select.contentFile', code = 'content_file_unavailable',
        message = 'none of the reference provenance content files are active',
      })
      return 'skip', nil, nil
    end
  end
  if query.ref and type(compileCtx.contentFileActive) == 'function'
      and compileCtx.contentFileActive(query.ref.file) == false then
    diagnostic_emit.reportSelectorUnresolved(compileCtx.diagnosticCollector, {
      sourcePath = node.source and node.source.file, actionId = node.id,
      path = actionPath .. '.select.ref', code = 'content_file_unavailable',
      message = 'exact reference content file is not active: ' .. query.ref.file,
    })
    return 'skip', nil, nil
  end
  local allowed = FAMILY_TYPES[node.family]
  if allowed == nil then allowed = {}; for _, name in ipairs(ref_type_contract.names()) do allowed[name] = true end end
  local types = query.type and copyArray(query.type) or sortedKeys(allowed)
  for _, typeName in ipairs(types) do
    if not allowed[typeName] then
      return 'error', nil, {actionPath .. '.select.type: ' .. typeName .. ' is unsupported for ' .. node.family}
    end
  end
  local internal = normalizeInternalCandidateTypes(node.candidateTypes, node.id, actionPath)
  if internal ~= nil then
    local filtered = {}
    for _, typeName in ipairs(types) do if internal[typeName] then filtered[#filtered + 1] = typeName end end
    types = filtered
    if #types == 0 then return 'error', nil, {actionPath .. '.select: candidate type intersection is empty'} end
  end
  local cell, errors = cell_selection.compile(selectSpec.cell, node.id, {
    cellIndex = compileCtx.cellIndex, requireCellIndex = compileCtx.requireCellIndex,
    workspace = compileCtx.workspace, metrics = compileCtx.metrics,
    path = actionPath .. '.select.cell',
    requireExplicit = policy.requireExplicitCellSelection and query.ref == nil,
    allowEmpty = node.allowEmptyCellSelection == true,
  })
  if errors then return 'error', nil, errors end
  if cell and cell.empty then return 'skip', nil, nil end
  local status, selection, selectionErrors, facts = finish(cell, nil, nil,
    node.predicates, types, node, actionPath)
  if status ~= 'ok' then return status, selection, selectionErrors end
  selection.query = query
  if selectSpec.cellConstraints then
    selection.additionalCells = {}
    for i, spec in ipairs(selectSpec.cellConstraints) do
      local extra, extraErrors = cell_selection.compile(spec, node.id, {
        cellIndex = compileCtx.cellIndex, requireCellIndex = compileCtx.requireCellIndex,
        workspace = compileCtx.workspace, metrics = compileCtx.metrics,
        path = actionPath .. '.select.cellConstraints[' .. i .. ']',
      })
      if extraErrors then return 'error', nil, extraErrors end
      selection.additionalCells[#selection.additionalCells + 1] = buildCellProgram(extra)
    end
  end
  -- These resolved catalog rows are execution hints, excluded from action ID.
  -- Their presence also means an empty catalog query matches nothing.
  if query.recordId or query.matches or query.mwscript then
    local recordCtx = compileCtx.recordCtx
    if recordCtx == nil and compileCtx.requireRecordContext then recordCtx = compileCtx.requireRecordContext() end
    if query.matches or query.mwscript then
      if recordCtx == nil or type(recordCtx.resolveRecordQuery) ~= 'function' then
        return 'error', nil, {actionPath .. '.select: record catalog query capability is unavailable'}
      end
      selection.queryRecords = {}
      for _, row in ipairs(recordCtx.resolveRecordQuery(query)) do
        if contains(types, row.typeName) then
          selection.queryRecords[#selection.queryRecords + 1] = row
        end
      end
    else
      selection.queryRecords = {}
      for _, id in ipairs(query.recordId) do
        local typeName, reason = recordCtx.resolveLiveRefType(id)
        if typeName and contains(types, typeName) then
          selection.queryRecords[#selection.queryRecords + 1] = {typeName = typeName, recordId = id}
        elseif not typeName then
          reportUnresolved(node, compileCtx, actionPath, id, reason or 'record unavailable')
        end
      end
    end
  end
  if selection.queryRecords ~= nil and #selection.queryRecords == 0 then
    diagnostic_emit.reportSelectorUnresolved(compileCtx.diagnosticCollector, {
      sourcePath = node.source and node.source.file, actionId = node.id,
      path = actionPath .. '.select', code = 'record_query_no_matches',
      message = 'record selector resolved to no installed records; its query remains closed',
    })
  end
  facts.specificity = (cell and cell.exactCellCount or 0) > 0 and 100 or 0
  if query.ref then facts.specificity = facts.specificity + 2000 + #query.ref.numbers end
  for _, field in ipairs({'type', 'recordId', 'matches', 'mwscript', 'contentFile'}) do
    if query[field] then facts.specificity = facts.specificity + 10 end
  end
  return 'ok', selection, nil, facts
end

---@return 'ok'|'skip'|'error' status
---@return table|nil selection
---@return string[]|nil errors
---@return table|nil facts Compile-only specificity and previsit facts.
function M.compile(node, effectiveSelect, compileCtx, policy)
  policy = policy or {}
  local selectSpec, actionId = effectiveSelect, node.id
  local actionPath = authored_path.fromSource(node.source, actionId)
  if selectSpec and selectSpec.query ~= nil then
    local valid, errors = selection_validation.validateSelectSpec(selectSpec, actionPath, {internal = true})
    if not valid then return 'error', nil, errors end
    return compileQuery(node, selectSpec, compileCtx, policy, actionPath)
  end
  local rawCandidateTypes = node.candidateTypes
  local internalCandidateTypes, internalTypeErrors = normalizeInternalCandidateTypes(
    rawCandidateTypes,
    actionId,
    actionPath
  )
  if internalTypeErrors then
    return 'error', nil, internalTypeErrors
  end
  local internalPredicates = node.predicates
  local basePredicates = normalizePredicates(
    internalPredicates and copyArray(internalPredicates) or nil
  )
  if selectSpec == nil then
    if policy.scope == 'ref' and internalCandidateTypes == nil and policy.allowInheritedTargets ~= true then
      return 'error', nil, {
        actionPath .. ': ref-scoped actions require a type-determining source (exact recordId or action-owned keyed target)'
      }
    end
    if policy.requireExplicitCellSelection and policy.allowInheritedTargets ~= true then
      return 'error', nil, {
        actionPath .. '.select.cell: required; use "*" for all cells'
      }
    end
    local candidateTypeList = nonEmptySortedKeys(internalCandidateTypes)
    return finish(nil, nil, nil, basePredicates, candidateTypeList, node, actionPath)
  end
  local okSchema, errors = selection_validation.validateSelectSpec(selectSpec, actionPath)
  if not okSchema then
    return 'error', nil, errors
  end
  local directEntries = type(node.directTargets) == 'table'
    and node.directTargets.entries or nil
  local queryCells = type(node.queryCells) == 'table' and node.queryCells or nil
  -- Exact targets and relocation recovery need their finite cell seeds even
  -- when an open source selector also continues through observed-cell paging.
  local needsCellUniverse = (type(directEntries) == 'table' and #directEntries > 0)
    or (queryCells ~= nil and #queryCells > 0)
  local cellSelection, cellErrors = cell_selection.compile(selectSpec.cell, actionId, {
    cellIndex = compileCtx.cellIndex,
    requireCellIndex = compileCtx.requireCellIndex,
    workspace = compileCtx.workspace,
    metrics = compileCtx.metrics,
    path = actionPath .. '.select.cell',
    requireExplicit = policy.requireExplicitCellSelection,
    universe = needsCellUniverse and 'required' or nil,
    allowEmpty = node.allowEmptyCellSelection == true,
  })
  if cellErrors then
    return 'error', nil, cellErrors
  end
  if cellSelection and cellSelection.empty == true then return 'skip', nil, nil end
  local predicates = basePredicates
  local candidateTypes = copySet(internalCandidateTypes)
  local hasTypeDeterminingSource = candidateTypes ~= nil
  local resolved = node.resolvedSelection
  local exactCandidateTypes, exactIdsByType, inferErrors, exactIds, skippedExactIds
  local finalExactIds, exactIdQueryList
  if resolved ~= nil and selectSpec.recordId == nil then
    for i = 1, #(resolved.skipped or {}) do
      local item = resolved.skipped[i]
      reportUnresolved(node, compileCtx, actionPath, item.recordId, item.reason)
    end
    if #resolved.exactIds == 0 then return 'skip', nil, nil end
    exactCandidateTypes = resolved.candidateTypes
    finalExactIds, exactIdQueryList = resolved.exactIds, resolved.exactIdQueries
  else
    local rawExactIds = compile_policy.normalizeExactIds(selectSpec.recordId)
    local recordCtx = compileCtx.recordCtx
    if rawExactIds ~= nil and recordCtx == nil then
      local resolve = compileCtx.requireRecordContext
      assert(type(resolve) == 'function', 'selection_plan.compile requires requireRecordContext()')
      recordCtx = resolve()
    end
    exactCandidateTypes, exactIdsByType, inferErrors, exactIds, skippedExactIds =
      inferExactIdTypes(selectSpec, node, recordCtx, compileCtx, actionPath)
    if inferErrors then return 'error', nil, inferErrors end
    if rawExactIds ~= nil and exactIds == nil and skippedExactIds then return 'skip', nil, nil end
    finalExactIds = exactIds and sortedKeys(exactIds) or nil
  end
  if exactCandidateTypes ~= nil then
    candidateTypes = intersectTypeSets(candidateTypes, exactCandidateTypes)
    hasTypeDeterminingSource = true
    if next(candidateTypes) == nil then
      return 'error', nil, {
        actionPath .. '.select: candidate type intersection is empty'
      }
    end
  end
  if policy.scope == 'ref' and not hasTypeDeterminingSource and policy.allowInheritedTargets ~= true then
    return 'error', nil, {
      actionPath .. ': ref-scoped actions require a type-determining source (exact recordId or action-owned keyed target)'
    }
  end
  local candidateTypeList = nonEmptySortedKeys(candidateTypes)
  if resolved ~= nil and selectSpec.recordId == nil then
    -- Built-in families supply the same type set at both handoffs. Only an
    -- extension's additional narrowing needs another pass over query rows.
    for typeName in pairs(resolved.candidateTypes) do
      if not candidateTypes[typeName] then
        local narrowed = {}
        for i = 1, #exactIdQueryList do
          local query = exactIdQueryList[i]
          if candidateTypes[query.typeName] then narrowed[#narrowed + 1] = query end
        end
        exactIdQueryList = #narrowed > 0 and narrowed or nil
        break
      end
    end
  end
  exactIdQueryList = exactIdQueryList or buildExactIdQueryList(exactIds, exactIdsByType, candidateTypeList)
  return finish(cellSelection, finalExactIds, exactIdQueryList, predicates, candidateTypeList, node, actionPath)
end
return M
