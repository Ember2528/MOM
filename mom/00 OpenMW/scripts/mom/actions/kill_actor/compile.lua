local M = {}
M.publicFields = { 'kill' }
local authored_path = require('scripts.mom.compiler.authored_path')
local tuple_contract = require('scripts.mom.compiler.tuple_contract')
local selector_skip_report = require('scripts.mom.compiler.selector_skip_report')
local source_ir = require('scripts.mom.compiler.source_ir')
local target_lowering = require('scripts.mom.compiler.target_lowering')
local compiledSpec = source_ir.compiledSpec
local resolveActionId = authored_path.resolveActionId
local ALLOWED_SOURCE_TYPES = {
  NPC = true,
  Creature = true,
}
local PROGRAM_KEYS = {
  matchPlan = true,
}
local target_match_plan = require('scripts.mom.contracts.target_match_plan')

local function familyProgram(spec, resolvedEntries, fields)
  local matchPlan = nil
  if #(resolvedEntries or {}) > 0 then
    local plan, planError = target_match_plan.build(resolvedEntries)
    if plan == nil then error(planError, 0) end
    matchPlan = plan
  end
  spec.program = {matchPlan = matchPlan}
  fields = fields or {}
  fields.claims = {keys = {'actor.life'}}
  fields.reversible = false
  return source_ir.familyProgram(spec, fields)
end

function M.validateProgram(program, errors, actionId, H)
  H.rejectUnknownKeys(program, PROGRAM_KEYS, errors, actionId)
  if program.matchPlan ~= nil then
    local valid, planError = target_match_plan.validate(program.matchPlan, 'matchPlan')
    if not valid then H.appendError(errors, actionId, planError) end
  end
end

function M.prepareAction(input, queries, ctx)
  local actionId = resolveActionId(input, ctx, 'kill_actor')
  local actionPath = authored_path.authoredActionPath(ctx, actionId)
  if input.select and input.select.type ~= nil then return nil, {actionPath .. '.select.type: is not allowed'} end
  if input.payloadKind == 'direct' then
    for key in pairs(input.payload) do return nil, {actionPath .. '.kill.' .. tostring(key) .. ': is not allowed'} end
    return input
  end
  for i = 1, #input.payload do
    local tuple = input.payload[i]
    local path = authored_path.authoredTuplePath(ctx, actionId, 'kill', tuple)
    local values = tuple.values
    tuple.values = nil
    local valid, errors = tuple_contract.validateArity(values, path, 2)
    if not valid then
      tuple.errors = errors
    elseif type(values[1]) ~= 'string' or values[1] == '' then
      tuple.errors = {path .. '[1]: expected target string'}
    elseif values[2] ~= nil and type(values[2]) ~= 'table' then
      tuple.errors = {path .. '[2]: expected options object'}
    else
      for key in pairs(values[2] or {}) do
        tuple.errors = {path .. '[2].' .. tostring(key) .. ': is not allowed'}
        break
      end
      if not tuple.errors then
        tuple.parsed, tuple.errors = target_lowering.parseSelector(path .. '[1]', values[1], {allowMeshPaths = true})
        target_lowering.collectParsedSelectorQuery(tuple.parsed, queries, {meshTypes = ALLOWED_SOURCE_TYPES})
      end
    end
  end
  return input
end
function M.compileAction(spec, ctx)
  local actionId = resolveActionId(spec, ctx, 'kill_actor')
  local actionPath = authored_path.authoredActionPath(ctx, actionId)
  local diagnostics = {
    diagnosticCollector = ctx and ctx.diagnosticCollector or nil,
    sourcePath = ctx and ctx.sourcePath or nil,
  }
  local skipReport = selector_skip_report.new({
    family = 'kill_actor',
    actionId = actionId,
    verb = 'kill',
    diagnostics = diagnostics,
    code = 'selector_key_unresolved',
  })
  local tuples = spec.payload
  local publicSelect = spec.select or {}
  if spec.payloadKind == 'direct' then
    local lowered = compiledSpec(spec)
    lowered.select = publicSelect
    return {familyProgram(lowered)}, nil
  end
  if #tuples == 0 then
    return nil, { actionPath .. '.kill: expected at least one tuple' }
  end
  local recordCtx = target_lowering.requireRecordContext(ctx)
  -- Iterating tuples preserves duplicate targets with different predicates.
  -- An objectMap would overwrite entries that share a target.
  local grouped = {}
  for i = 1, #tuples do
    local tuple = tuples[i]
    if tuple.errors then return nil, tuple.errors end
    local path = authored_path.authoredTuplePath(ctx, actionId, 'kill', tuple)
    local parsed = tuple.parsed
    local inferredTypes = target_lowering.resolveSelectorTypesOrSkip(parsed, {
      recordCtx = recordCtx,
      path = path .. '[1]',
      allowedTypes = ALLOWED_SOURCE_TYPES,
      typeLabel = 'actor record types',
      selectorLabel = 'target selector',
      skipReport = skipReport,
    })
    if inferredTypes then
      local okEntries, entryErrors = target_lowering.appendTypedEntries(grouped, parsed, inferredTypes, function()
        return {}, nil
      end, {
        predicates = tuple.predicates,
        path = path,
      })
      if not okEntries then return nil, entryErrors end
    end
  end
  selector_skip_report.flush(skipReport)
  local targetStatus, lowered, targetErrors, entries, metadata = target_lowering.finalizeResolvedEntries(
    grouped,
    spec,
    publicSelect,
    {
      payloadKey = 'kill',
      recordCtx = recordCtx,
      path = actionPath .. '.kill',
      pathPrefix = actionPath .. '.kill',
      skipReport = skipReport,
      code = 'kill_no_targets_resolved',
      message = 'kill action was skipped because no target selector resolved',
      reason = 'no target selector resolved',
    }
  )
  if targetStatus == 'skip' then return {}, nil end
  if targetStatus == 'error' then return nil, targetErrors end
  return {familyProgram(lowered, entries, metadata)}, nil
end
return M
