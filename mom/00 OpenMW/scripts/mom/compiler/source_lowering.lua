-- One directed source pipeline: explicit source records are preprocessed once,
-- queried once, lowered by their action extensions, and emitted directly as
-- the normalized IR consumed by the manifest compiler.
local M = {}

local authored_path = require('scripts.mom.compiler.authored_path')
local claim_contract = require('scripts.mom.contracts.claim_contract')
local compile_policy = require('scripts.mom.compiler.compile_policy')
local diagnostic_emit = require('scripts.mom.compiler.diagnostic_emit')
local plain_data = require('scripts.mom.contracts.plain_data')
local program_contract = require('scripts.mom.compiler.program_contract')
local source_action_contract = require('scripts.mom.compiler.source_action_contract')
local source_ir = require('scripts.mom.compiler.source_ir')
local source_preprocess = require('scripts.mom.compiler.source_preprocess')
local ref_type = require('scripts.mom.contracts.ref_type')

local function collectSelectQueries(spec, queries)
  queries = queries or { recordIds = {}, meshPathTypes = {} }
  local selectSpec = type(spec) == 'table' and spec.select or nil
  if type(selectSpec) ~= 'table' then
    selectSpec = {}
  end
  for _, recordId in ipairs(selectSpec.query and selectSpec.query.recordId or {}) do
    queries.recordIds[recordId] = true
  end
  for recordId in pairs(compile_policy.normalizeExactIds(selectSpec.recordId) or {}) do
    queries.recordIds[recordId] = true
  end
  return queries
end

local function emptyQueries()
  return {recordIds = {}, meshPathTypes = {}}
end

local function compilerFor(record, catalog)
  local entry = catalog and catalog.actions and catalog.actions.byId
    and catalog.actions.byId[record.family] or nil
  local compiler = entry and entry.module or nil
  if type(compiler) ~= 'table' or type(compiler.compileAction) ~= 'function'
      or type(compiler.prepareAction) ~= 'function' then
    return nil, 'action module ' .. tostring(record.family) .. '.prepareAction or compileAction is missing'
  end
  return compiler, nil
end

local function recordPath(record, suffix)
  return authored_path.fromSource(
    record and record.source or nil,
    record and record.diagnosticId or nil,
    suffix
  )
end

local function needsParentOutputTypes(prepared)
  if not prepared.isChild or prepared.input.verb ~= 'attach' then return false end
  if prepared.input.payloadKind == 'direct'
      or prepared.input.payloadKind == 'inherited_tuples' then return true end
  if prepared.input.payloadKind == 'tuples' then
    for _, entry in ipairs(prepared.input.payload or {}) do
      if entry.parsed and entry.parsed.sourceKeyKind == 'model_path' then return true end
    end
  end
  return false
end

local function collectPrepared(record, catalog, queries, opts)
  opts = opts or {}
  if record.uniqueSourceKey ~= nil then
    local seen = opts.sourceKeys
    local previous = seen[record.uniqueSourceKey]
    if previous ~= nil then
      return nil, {recordPath(record) .. ': duplicate source key ' .. record.uniqueSourceKey
        .. ' (already declared at ' .. previous .. ')'}
    end
    seen[record.uniqueSourceKey] = recordPath(record)
  end
  local compiler, compilerErr = compilerFor(record, catalog)
  if not compiler then
    return nil, {recordPath(record) .. ': ' .. tostring(compilerErr)}
  end
  local valid, fieldErrors = source_action_contract.validatePublicFields(
    record.spec, compiler, recordPath(record))
  local prepared, preprocessErrors = source_preprocess.preprocess(record, {
    isChild = opts.isChild == true,
  })
  if not prepared then return nil, preprocessErrors end

  local preparedChildren = {}
  for i = 1, #(record.children or {}) do
    local child, childErrors = collectPrepared(
      record.children[i], catalog, queries, {isChild = true, sourceKeys = opts.sourceKeys})
    if not child then return nil, childErrors end
    for j = 1, #child do preparedChildren[#preparedChildren + 1] = child[j] end
  end

  for i = 1, #prepared do
    local item = prepared[i]
    item.isChild = opts.isChild == true
    item.children = preparedChildren
    for j = 1, #preparedChildren do
      local child = preparedChildren[j]
      if child.needsOutputEnvelope or needsParentOutputTypes(child) then
        item.needsOutputEnvelope = true
        break
      end
    end
    collectSelectQueries(item.input, queries)
    local ok, payload, errors = true, nil, fieldErrors
    if valid then
      ok, payload, errors = pcall(compiler.prepareAction, item.input, queries, {
        actionId = item.diagnosticId, actionKind = item.family,
        authoredPath = recordPath(item), selectPredicates = item.selectPredicates,
        isChild = item.isChild, loadDecision = item.loadDecision,
      })
    end
    if not ok then
      return nil, {recordPath(item) .. ': syntax preparation failed: ' .. tostring(payload)}
    end
    if payload ~= nil and (type(payload) ~= 'table' or getmetatable(payload) ~= nil) then
      payload, errors = nil, {recordPath(item) .. ': prepareAction must return an owned input table'}
    end
    if payload == nil then
      -- A family syntax failure retains its original lowering diagnostic phase.
      -- Do not keep the rejected source payload until context construction.
      if valid then item.compileErrors = errors or {'action preparation failed'}
      else item.fieldErrors = errors end
      item.input = {chance = item.input.chance}
    else
      item.input = payload
    end
  end
  record.spec = nil
  return prepared, nil
end

-- Takes ownership of source payloads and releases each one after preparation.
function M.prepareActions(actions, catalog, opts)
  opts = opts or {}
  opts.sourceKeys = opts.sourceKeys or {}
  local prepared, queries = {}, emptyQueries()
  for i = 1, #(actions or {}) do
    local record = actions[i]
    if type(record) ~= 'table' or record.kind ~= 'mom-source-action' then
      return nil, nil, {'actions[' .. tostring(i) .. ']: expected mom-source-action'}
    end
    local rows, errors = collectPrepared(record, catalog, queries, opts)
    if not rows then return nil, nil, errors end
    for j = 1, #rows do prepared[#prepared + 1] = rows[j] end
  end
  -- Prepared records are a transient compiler-owned graph. Cell splits may
  -- share immutable source metadata and child records until lowerActions()
  -- emits the detached, validated normalized-IR boundary.
  return prepared, queries, nil
end

local function appendCompileDiagnostic(ctx, code, message)
  diagnostic_emit.append(ctx and ctx.diagnosticCollector or nil, {
    category = 'compiler-contract',
    severity = 'error',
    phase = 'compile',
    sourcePath = ctx and ctx.sourcePath or nil,
    family = ctx and ctx.actionKind or nil,
    actionId = ctx and ctx.actionId or nil,
    path = ctx and ctx.authoredPath or authored_path.fromActionId(
      ctx and ctx.actionId or 'action'),
    code = code,
    message = tostring(message),
  })
end

local lowerPrepared

local function validateFamilyProgramArray(rows, actionPath)
  local path = authored_path.append(actionPath, 'familyPrograms')
  if type(rows) ~= 'table' then
    return nil, {path .. ': compileAction() must return an array'}
  end
  if getmetatable(rows) ~= nil then
    return nil, {path .. ': metatables are not allowed'}
  end
  local count, maximum = 0, 0
  for key in pairs(rows) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 then
      return nil, {path .. '.' .. tostring(key) .. ': expected a dense array index'}
    end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if maximum ~= count then return nil, {path .. ': expected a dense array'} end
  return true, nil
end

local function sourceReference(prepared)
  local function bounded(value, limit)
    local text = tostring(value):gsub('%c', ' ')
    if #text <= limit then return text end
    return text:sub(1, limit - 3) .. '...'
  end
  -- Keep both the filename and authored location readable within one bounded
  -- diagnostic label. This field never participates in semantic identity.
  local file = prepared.source and prepared.source.file or '<unknown>'
  return bounded(file, 255) .. '#' .. bounded(recordPath(prepared), 256)
end


local function outputEnvelopeReader(prepared, context, catalog, parentReader)
  -- Children lower before their parent. This lazy, per-lowering reader gives
  -- them a conservative set of possible output types without compiling the
  -- parent early or retaining inference state on the prepared action.
  local cached, cachedError
  return function()
    if cached ~= nil or cachedError ~= nil then return cached, cachedError end
    local compiler, compilerError = compilerFor(prepared, catalog)
    if compiler == nil then cachedError = {compilerError}; return nil, cachedError end
    local hook = compiler.outputTypeEnvelope
    if type(hook) ~= 'function' then
      cachedError = {recordPath(prepared) .. ': parent family ' .. tostring(prepared.family)
        .. ' does not declare a safe output type envelope'}
      return nil, cachedError
    end
    local parentTypes
    if needsParentOutputTypes(prepared) then
      if type(parentReader) ~= 'function' then
        cachedError = {recordPath(prepared) .. ': parent output types are unavailable'}
        return nil, cachedError
      end
      parentTypes, cachedError = parentReader()
      if parentTypes == nil then return nil, cachedError end
    elseif prepared.isChild and type(parentReader) == 'function' then
      -- A child with its own inferable output type still cannot produce an
      -- output when its parent proves it has no anchors. If the parent's
      -- envelope is unavailable, retain the conservative child-only result.
      local possibleParents = parentReader()
      if type(possibleParents) == 'table' and next(possibleParents) == nil then
        cached = {}
        return cached, nil
      end
      parentTypes = possibleParents
    end
    local ok, values, reason = pcall(hook, prepared.input, {
      recordCtx = context.recordCtx,
      requireRecordContext = context.requireRecordContext,
      parentOutputTypes = parentTypes,
      modelExists = context.modelExists,
      isChild = prepared.isChild == true,
    })
    -- An empty set is a proven lack of parent outputs, not an unknown type.
    -- Children still lower for their own diagnostics, but produce no actions.
    if not ok or type(values) ~= 'table' then
      cachedError = {recordPath(prepared) .. ': parent output type envelope is unavailable: '
        .. tostring(reason or values)}
      return nil, cachedError
    end
    for typeName, enabled in pairs(values) do
      if not ref_type.contains(typeName) or enabled ~= true then
        cachedError = {recordPath(prepared) .. ': parent output type envelope is invalid'}
        return nil, cachedError
      end
    end
    cached = values
    return cached, nil
  end
end

lowerPrepared = function(prepared, context, catalog, parentReader)
  local compiler, compilerErr = compilerFor(prepared, catalog)
  if not compiler then return nil, {compilerErr} end
  if prepared.fieldErrors then return nil, prepared.fieldErrors end

  local children = {}
  local readOwnEnvelope
  if prepared.needsOutputEnvelope then
    readOwnEnvelope = outputEnvelopeReader(prepared, context, catalog, parentReader)
  end
  -- Child-first lowering preserves diagnostics and lets the family hook see
  -- whether any children actually lowered, rather than merely being authored.
  for i = 1, #(prepared.children or {}) do
    local childNodes, childErrors = lowerPrepared(prepared.children[i], context, catalog, readOwnEnvelope)
    if not childNodes then return nil, childErrors end
    for j = 1, #childNodes do children[#children + 1] = childNodes[j] end
  end

  if prepared.compileErrors then return nil, prepared.compileErrors end

  local parentOutputTypes
  if needsParentOutputTypes(prepared) then
    if type(parentReader) ~= 'function' then
      return nil, {recordPath(prepared) .. ': parent output types are unavailable'}
    end
    local parentErrors
    parentOutputTypes, parentErrors = parentReader()
    if parentOutputTypes == nil then return nil, parentErrors end
  end

  local hookContext = {
    actionId = prepared.diagnosticId,
    actionKind = prepared.family,
    recordCtx = context.recordCtx,
    cellIndex = context.cellIndex,
    requireRecordContext = context.requireRecordContext,
    requireCellIndex = context.requireCellIndex,
    modelExists = context.modelExists,
    workspace = context.workspace,
    metrics = context.metrics,
    diagnosticCollector = context.diagnosticCollector,
    sourcePath = prepared.source and prepared.source.file or nil,
    authoredPath = recordPath(prepared),
    selectPredicates = prepared.selectPredicates,
    hasChildActions = #children > 0,
    isChild = prepared.isChild == true,
    parentOutputTypes = parentOutputTypes,
    loadDecision = prepared.loadDecision,
  }
  local ok, loweredRows, errors = pcall(
    compiler.compileAction,
    prepared.input,
    hookContext
  )
  if not ok then
    appendCompileDiagnostic(hookContext, 'action_compilation_failed', loweredRows)
    return nil, {recordPath(prepared)
      .. ': compileAction hook failed: ' .. tostring(loweredRows)}
  end
  if loweredRows == nil then return nil, errors or {'action compilation failed'} end
  local arrayOk, arrayErrors = validateFamilyProgramArray(
    loweredRows,
    recordPath(prepared)
  )
  if not arrayOk then return nil, arrayErrors end

  local nodes = {}
  for i = 1, #loweredRows do
    local lowered = loweredRows[i]
    local familyOk, familyErrors = source_ir.validateFamilyProgram(
      lowered,
      recordPath(prepared, 'familyPrograms[' .. tostring(i) .. ']')
    )
    if not familyOk then return nil, familyErrors end
    nodes[#nodes + 1] = source_ir.normalizedAction(
      prepared, lowered, children, i, sourceReference(prepared))
  end
  return nodes, nil
end

local function validateFinalActions(actions, catalog)
  for i = 1, #(actions or {}) do
    local node = actions[i]
    local entry = catalog and catalog.actions and catalog.actions.byId
      and catalog.actions.byId[node.family] or nil
    local compiler = entry and entry.module or nil
    local programOk, programErrors = program_contract.validateWithCompiler(
      node.program,
      node.id,
      compiler
    )
    if not programOk then return nil, programErrors end
    for key in pairs(node.claims or {}) do
      if key ~= 'keys' then
        return nil, {'action:' .. tostring(node.id)
          .. '.claims.' .. tostring(key) .. ': field is not allowed'}
      end
    end
    local normalizedClaims, claimErrors = claim_contract.normalize(
      node.claims and node.claims.keys or nil,
      node.family,
      'action:' .. tostring(node.id) .. '.claims.keys',
      {nonEmpty = true}
    )
    if not normalizedClaims then return nil, claimErrors end
    node.claims.keys = normalizedClaims
    for typeName, enabled in pairs(node.candidateTypes or {}) do
      if type(typeName) ~= 'string' or typeName == '' or enabled ~= true then
        return nil, {'action:' .. tostring(node.id)
          .. '.candidateTypes: expected non-empty string keys with true values'}
      end
    end
    local childrenOk, childErrors = validateFinalActions(node.children, catalog)
    if not childrenOk then return nil, childErrors end
  end
  return true, nil
end

function M.lowerActions(prepared, context, catalog)
  local actions = {}
  for i = 1, #(prepared or {}) do
    local nodes, errors = lowerPrepared(prepared[i], context, catalog)
    if not nodes then return nil, errors end
    for j = 1, #nodes do actions[#actions + 1] = nodes[j] end
  end
  local ir = {actions = actions}
  local detached, errors = plain_data.detach(ir, {path = 'normalizedSource'})
  if detached == nil then return nil, errors end
  local valid, validationErrors = validateFinalActions(detached.actions, catalog)
  if not valid then return nil, validationErrors end
  return detached, nil
end

return M
