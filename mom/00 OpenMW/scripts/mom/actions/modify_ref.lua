-- Reversible ref-state action family for the MOM runtime.
local compiler = require('scripts.mom.actions.modify_ref.compile')
local recovery_locations = require('scripts.mom.actions.modify_ref.recovery_locations')
local lazy_hooks = require('scripts.mom.common.lazy_action_hooks')
local keyed = require('scripts.mom.compiler.keyed_targets')
local tables = require('scripts.mom.common.tables')
local ref_type = require('scripts.mom.contracts.ref_type')

local ALL_TYPES = {}
for _, name in ipairs(ref_type.names()) do ALL_TYPES[name:lower()] = name end
local function parseTypes(value)
  if type(value) == 'string' then value = {value} end
  if not tables.isArray(value) or #value == 0 then return nil end
  local out = {}
  for _, name in ipairs(value) do
    local normalized = type(name) == 'string' and ALL_TYPES[name:lower()]
    if not normalized then return nil end
    out[normalized] = true
  end
  return out
end
local function intersectTypes(left, right)
  if left == nil then return right end
  if right == nil then return left end
  local out = {}
  for name in pairs(left) do if right[name] then out[name] = true end end
  return out
end

local M = {
  id = 'modify_ref',
  verbs = {'modify'},
  abiVersion = 0,
  behaviorVersion = 0,
  programVersion = 0,
  revertTokenVersion = 0,
  programByReference = true,
  publicFields = compiler.publicFields,
  prepareAction = compiler.prepareAction,
  compileAction = compiler.compileAction,
  validateProgram = compiler.validateProgram,
  behavior = {
    scope = 'ref',
    requiresExplicitCellSelection = true,
    canBeChildAction = true,
    acceptedParentTargetKinds = {'ref'},
  },
}

function M.readFootprint(node)
  local spec = type(node) == 'table' and node.spec or nil
  local payload = type(spec) == 'table' and spec.modify or nil
  if type(payload) ~= 'table' then return {reads = {}, choice = false} end
  local outer = spec.select and spec.select.type ~= nil and parseTypes(spec.select.type) or nil
  local reads = {}
  if tables.isArray(payload) then
    for _, row in ipairs(payload) do
      if type(row) == 'table' then
        local src, own = row[2], nil
        if type(src) == 'table' then
          local ids = src.recordId
          if type(ids) == 'table' and tables.isArray(ids) and #ids == 1 then ids = ids[1] end
          own = src.type ~= nil and parseTypes(src.type) or nil
          src = ids
        end
        local parsed = keyed.parseSelectorKey(src)
        if parsed and parsed.sourceKeyKind == 'model_path' then
          reads[#reads + 1] = {source = parsed, types = intersectTypes(outer, own)}
        end
      end
    end
  else
    for key in pairs(payload) do
      if keyed.isLikelyMeshPath(key) then
        local parsed = keyed.parseSelectorKey(key)
        if parsed then reads[#reads + 1] = {source = parsed, types = outer} end
      end
    end
  end
  return {reads = reads, choice = false}
end

M.recoveryLocations = recovery_locations.fromOperation

return lazy_hooks.bind(M, 'scripts.mom.actions.modify_ref.runtime', {
  matchesTarget = true, capture = true, apply = true, reassert = true, revert = true,
  advance = true, prepareTransition = true,
})
