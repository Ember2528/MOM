-- First-class LOAD-only action module for leveled-list edits (`leveled`).
local schema = require('scripts.mom.compiler.content.schema')
local plain = require('scripts.mom.contracts.plain_data')

local ALLOWED_ACTION_FIELDS = {leveled = true, id = true, onMissingTarget = true}
local DISALLOWED_LOAD_FIELDS = {'select', 'filters', 'chance', 'previsit'}

local M = {
  id = 'leveled_content',
  verbs = {'leveled'},
  abiVersion = 0,
  behaviorVersion = 0,
  programVersion = 0,
  execution = 'load',
  publicFields = {'leveled'},
}

function M.analyzeLoad(node, opts)
  opts = opts or {}
  local spec = type(node) == 'table' and node.spec or nil
  if type(spec) ~= 'table' or spec.leveled == nil then return nil end
  if opts.guarded or opts.isChild or node.guardOwner ~= nil then
    return nil, 'record/list definitions cannot be guarded or be children'
  end
  if opts.hasChildren or #(node.children or {}) > 0
      or (spec.actions ~= nil and not (type(spec.actions) == 'table' and #spec.actions == 0)) then
    return nil, 'record/list definitions cannot be guarded, be children, or own reference outputs'
  end
  if opts.conflict ~= nil or node.conflict ~= nil then
    return nil, 'record/list definitions cannot own conflict groups'
  end
  for _, key in ipairs(DISALLOWED_LOAD_FIELDS) do
    if spec[key] ~= nil then
      return nil, 'record/list definitions cannot use ' .. key
    end
  end
  return {mode = 'load_only'}
end

function M.compileLoad(node, loadCtx)
  local spec = node.spec
  local source = loadCtx.source
  local payload = spec and spec.leveled
  local valid, failure = schema.object(spec, ALLOWED_ACTION_FIELDS, source)
  if valid and spec.id ~= nil and type(spec.id) ~= 'string' then
    valid, failure = nil, source .. '.id: expected string'
  end
  if valid and spec.onMissingTarget ~= nil
      and spec.onMissingTarget ~= 'skip' and spec.onMissingTarget ~= 'error' then
    valid, failure = nil, source .. '.onMissingTarget: expected skip or error'
  end
  if valid then
    valid, failure = schema.object(payload, schema.payloadFields.leveled, source .. '.leveled')
    if valid then
      local definition, id = schema.types[payload.type], schema.id(payload.id)
      if definition == nil or id == nil or id:match('^mom__content_')
          or definition.entries == nil then
        valid, failure = nil, source .. ': unsupported type, invalid ID, or record/list domain mismatch'
      end
    end
  end
  if not valid or node.guardOwner ~= nil or #(node.children or {}) > 0 or node.conflict ~= nil then
    return nil, failure or (source .. ': definitions cannot own runtime guards, children or conflict groups')
  end
  if spec.onMissingTarget == 'skip' and type(payload) == 'table' and payload.create ~= true then
    local records, storeError = schema.store(loadCtx.content, payload.type)
    local unavailable
    if not records then
      unavailable = storeError
    else
      local value, targetError = schema.lookup(records, schema.id(payload.id))
      if targetError or value == nil then
        unavailable = targetError or 'target record is unavailable'
      end
    end
    if unavailable then
      loadCtx.skipTarget(source, unavailable)
      return {}
    end
  end
  return {{
    kind = 'leveled',
    payload = plain.cloneValidated(payload),
    source = source,
    priority = node.priority,
    order = loadCtx.nextOrder(),
    compositionOrder = node.compositionOrder,
  }}
end

return M
