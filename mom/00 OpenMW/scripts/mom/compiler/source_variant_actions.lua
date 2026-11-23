-- Converts native variant actions into explicit source records and expands
-- guard blocks without attaching compiler-private fields to authored tables.
local M = {}

local authored_contract = require('scripts.mom.compiler.authored_contract')
local source_action_contract = require('scripts.mom.compiler.source_action_contract')
local source_ir = require('scripts.mom.compiler.source_ir')
local tables = require('scripts.mom.common.tables')
local phase_partition = require('scripts.mom.compiler.phase_partition')

local copyObject = tables.copyObject
local hasNamedKeys = tables.hasNamedKeys
local isArray = tables.isArray
local isObject = tables.isObject
local validateAllowedKeys = tables.validateAllowedKeys
local GUARD_BLOCK_FIELDS = authored_contract.guardBlockFields

local function variantPath(variantId, suffix)
  local path = 'variants.' .. tostring(variantId)
  if suffix == nil or suffix == '' then return path end
  return path .. '.' .. tostring(suffix)
end

local function appendStructuralPath(path, ...)
  local out = {}
  for i = 1, #(path or {}) do out[i] = path[i] end
  local values = {...}
  for i = 1, #values do out[#out + 1] = values[i] end
  return out
end

local function sourceRecord(action, context, guardOwner)
  local verb = source_action_contract.detectVerb(action)
  local family = authored_contract.actionKindForVerb(verb)
  local children = {}
  for i = 1, #(action.actions or {}) do
    children[i] = sourceRecord(action.actions[i], {
      sourcePath = context.sourcePath,
      adapterId = context.adapterId,
      variantId = context.variantId,
      structuralPath = appendStructuralPath(context.structuralPath, 'actions', i),
      diagnosticId = tostring(context.diagnosticId) .. '.actions[' .. tostring(i) .. ']',
    })
  end
  local spec = copyObject(action)
  spec.actions = nil
  return source_ir.sourceAction(spec, {
    family = family,
    diagnosticId = context.diagnosticId,
    source = {
      adapterId = context.adapterId or 'native',
      file = context.sourcePath or '<unknown>',
      variant = context.variantId or 'default',
      path = context.structuralPath or {},
    },
    guardOwner = guardOwner,
    children = children,
  })
end

local function stableGuardOwnerId(variantId, guardIdx)
  return string.format('variant:%s.guards[%d]', tostring(variantId), guardIdx)
end

local function normalizeGuardSpec(rawGuard, path, guardRegistry)
  if type(rawGuard) ~= 'table' then
    return nil, tostring(path) .. ': expected compact guard tuple'
  end
  if hasNamedKeys(rawGuard) then
    return nil,
      tostring(path)
        .. ': guard objects are not supported; use compact guard tuples'
  end
  if not isArray(rawGuard) or #rawGuard == 0 then
    return nil, tostring(path) .. ': expected compact guard tuple'
  end
  local guardType = rawGuard[1]
  if type(guardType) ~= 'string' or guardType == '' then
    return nil, tostring(path) .. '[1]: expected guard type string'
  end
  if type(guardRegistry) == 'function' then guardRegistry = guardRegistry() end
  local entry = guardRegistry
      and guardRegistry.byId
      and guardRegistry.byId[guardType]
    or nil
  local mod = entry and entry.module or nil
  if type(mod) ~= 'table' then
    return nil,
      tostring(path)
        .. '[1]: unable to load guard module '
        .. tostring(guardType)
        .. ' (guard module not found)'
  end
  if type(mod.lowerTuple) ~= 'function' then
    return nil,
      tostring(path)
        .. '[1]: guard '
        .. tostring(guardType)
        .. ' does not support compact tuple syntax'
  end
  return mod.lowerTuple(rawGuard, path)
end

local function normalizeGuardWhen(whenSpec, variantId, guardIdx, guardRegistry)
  local path = variantPath(variantId, string.format('guards[%d].when', guardIdx))
  if not isArray(whenSpec) then return nil, path .. ': expected array' end
  local out = {}
  if guardRegistry == false then
    if #whenSpec == 0 then return nil, path .. ': expected at least one guard' end
    for i, tuple in ipairs(whenSpec) do
      if not isArray(tuple) or type(tuple[1]) ~= 'string' then
        return nil, path .. '[' .. i .. ']: expected compact guard tuple'
      end
      out[i] = tuple
    end
    return out
  end
  for i, guardSpec in ipairs(whenSpec) do
    local normalized, normalizeErr = normalizeGuardSpec(
      guardSpec,
      string.format('%s[%d]', path, i),
      guardRegistry
    )
    if not normalized then return nil, normalizeErr end
    out[#out + 1] = normalized
  end
  if #out == 0 then return nil, path .. ': expected at least one guard' end
  return out, nil
end

local function expandGuardActions(
    variantId,
    guardIdx,
    guardBlock,
    sourcePath,
    adapterId,
    guardOwnerId,
    guardRegistry)
  local path = variantPath(variantId, string.format('guards[%d]', guardIdx))
  if not isObject(guardBlock) then return nil, path .. ': expected object' end
  local guardFieldErr = validateAllowedKeys(guardBlock, GUARD_BLOCK_FIELDS, path)
  if guardFieldErr then return nil, guardFieldErr end
  if guardBlock.select ~= nil then return nil, path .. '.select: is not allowed' end
  if guardBlock.on_enter ~= nil or guardBlock.on_exit ~= nil then
    return nil, path .. ': contains fields that are not allowed'
  end
  if guardBlock.scope ~= nil then
    return nil, path .. '.scope: is not allowed; guard-owned cells come from child actions'
  end
  local whenSpecs, whenErr = normalizeGuardWhen(
    guardBlock.when,
    variantId,
    guardIdx,
    guardRegistry
  )
  if not whenSpecs then return nil, whenErr end
  if not isArray(guardBlock.actions) then
    return nil, path .. '.actions: expected array'
  end
  local expanded = {}
  guardOwnerId = guardOwnerId
    or stableGuardOwnerId(variantId, guardIdx)
  for i, action in ipairs(guardBlock.actions) do
    local actionErr = source_action_contract.validate(
      action,
      string.format('%s.actions[%d]', path, i)
    )
    if actionErr then return nil, actionErr end
    local expandedAction = sourceRecord(action, {
      sourcePath = sourcePath,
      adapterId = adapterId,
      variantId = variantId,
      structuralPath = {'guards', guardIdx, 'actions', i},
      diagnosticId = string.format('variant:%s.guards[%d].actions[%d]', variantId, guardIdx, i),
    }, {
      id = guardOwnerId,
      when = whenSpecs,
      raw = guardRegistry == false or nil,
    })
    expanded[#expanded + 1] = expandedAction
  end
  return expanded, nil
end

-- Native syntax becomes ordinary source actions before semantic normalization
-- or execution placement. Guard implementations are loaded only for GLOBAL.
function M.collectAll(variantId, variant, opts)
  opts = opts or {}
  local out = {}
  if variant.actions ~= nil and not isArray(variant.actions) then
    return nil, variantPath(variantId, 'actions') .. ': expected array'
  end
  for index, action in ipairs(variant.actions or {}) do
    local path = variantPath(variantId, 'actions[' .. index .. ']')
    local err = source_action_contract.validate(action, path)
    if err then return nil, err end
    out[#out + 1] = sourceRecord(action, {
      sourcePath = opts.sourcePath, adapterId = opts.adapterId, variantId = variantId,
      structuralPath = {'actions', index},
      diagnosticId = 'variant:' .. variantId .. '.actions[' .. index .. ']',
    })
  end
  if variant.guards ~= nil and not isArray(variant.guards) then
    return nil, variantPath(variantId, 'guards') .. ': expected array'
  end
  for index, block in ipairs(variant.guards or {}) do
    local actions, err = expandGuardActions(variantId, index, block,
      opts.sourcePath, opts.adapterId, nil, false)
    if not actions then return nil, err end
    for _, action in ipairs(actions) do out[#out + 1] = action end
  end
  return out
end

local function planActions(actions, opts)
  local attempts = {{status = 'resolved', path = opts.sourcePath or '<native>', actions = actions}}
  local normalized, errors = require('scripts.mom.compiler.action_frontend').normalize(attempts)
  if not normalized then return nil, table.concat(errors, ' | ') end
  local plan, planningErrors = phase_partition.plan(normalized)
  if not plan then return nil, table.concat(planningErrors, ' | ') end
  return normalized, plan
end

-- Kept as the narrow standalone frontend API: placement still follows the
-- same shared normalization/planner used by multi-source compilation.
function M.collect(variantId, variant, opts)
  opts = opts or {}
  local actions, err = M.collectAll(variantId, variant, opts)
  if not actions then return nil, err end
  if opts.deferPlacement then return actions, nil, {} end
  local normalized, plan = planActions(actions, opts)
  if not normalized then return nil, plan end
  local phase, phaseError = phase_partition.phase(opts.phase)
  if not phase then return nil, phaseError end
  local selected = phase_partition.select(normalized, plan, phase)
  if phase == 'GLOBAL' then
    local ok, guardErrors = M.lowerGuards(selected, opts.guardRegistry)
    if not ok then return nil, table.concat(guardErrors, ' | ') end
  end
  local result = {}
  for _, attempt in ipairs(selected) do
    for _, action in ipairs(attempt.actions or {}) do result[#result + 1] = action end
  end
  return result, nil, plan.loadInputs
end

function M.partition(variantId, variant, opts)
  opts = opts or {}
  local actions, err = M.collectAll(variantId, variant, opts)
  if not actions then return nil, err end
  local normalized, plan = planActions(actions, opts)
  if not normalized then return nil, plan end
  local owners = {}
  for index, action in ipairs(actions) do owners[index] = plan.owners[action] end
  return {owners = owners, loadInputs = plan.loadInputs}
end

function M.lowerGuards(attempts, registry)
  local cache, errors = {}, {}
  for _, attempt in ipairs(attempts) do
    for _, action in ipairs(attempt.actions or {}) do
      local owner = action.guardOwner
      if owner and owner.raw then
        local key = tostring(attempt.path) .. ':' .. owner.id
        local lowered = cache[key]
        if not lowered then
          local path = action.source and action.source.path or {}
          local when, err = normalizeGuardWhen(owner.when,
            action.source and action.source.variant or 'default', path[2] or 1, registry)
          if not when then errors[#errors + 1] = tostring(err)
          else lowered = {id = owner.id, when = when}; cache[key] = lowered end
        end
        if lowered then action.guardOwner = lowered end
      end
    end
  end
  return #errors == 0 and true or nil, errors
end

return M
