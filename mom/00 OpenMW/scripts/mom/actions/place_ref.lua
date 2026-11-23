-- Reversible output-placement action family for the MOM runtime.
local compiler = require('scripts.mom.actions.place_ref.compile')
local load_ops = require('scripts.mom.actions.place_ref.load')
local lazy_hooks = require('scripts.mom.common.lazy_action_hooks')

local M = {
  id = 'place_ref',
  verbs = {'place', 'attach'},
  abiVersion = 0,
  behaviorVersion = 0,
  programVersion = 0,
  revertTokenVersion = 0,
  programByReference = true,
  publicFields = compiler.publicFields,
  analyzeLoad = load_ops.analyzeLoad,
  readFootprint = load_ops.readFootprint,
  compileLoad = load_ops.compileLoad,
  prepareAction = compiler.prepareAction,
  compileAction = compiler.compileAction,
  validateProgram = compiler.validateProgram,
  outputTypeEnvelope = compiler.outputTypeEnvelope,
}

function M.prepareTargetFilters(actions)
  return require('scripts.mom.actions.place_ref.choice_runtime').prepareTargetFilters(actions)
end

local BASE_BEHAVIOR = {
  affectsCellContents = true,
  scope = 'dynamic',
  requiresExplicitCellSelection = true,
  canHaveChildActions = true,
  childTargetKind = 'ref',
}

local function copyBehavior()
  local out = {}
  for key, value in pairs(BASE_BEHAVIOR) do out[key] = value end
  return out
end

function M.resolveBehavior(spec)
  local behavior = copyBehavior()
  local program = type(spec) == 'table' and spec.program or nil
  if type(program) == 'table'
      and (program.destinationCellKey ~= nil or program.inheritedAnchor == true
        or program.inheritedSource == true) then
    behavior.scope = 'ref'
    behavior.canBeChildAction = true
    behavior.acceptedParentTargetKinds = {'ref'}
    behavior.inheritParentCell = false
    behavior.requiresExplicitCellSelection = false
  end
  if type(program) == 'table' and program.mode == 'relative' then
    behavior.requiresExplicitCellSelection = false
  end
  return behavior
end

function M.acceptsGeneratedRoot(program)
  return not (type(program) == 'table' and program.mode == 'relative')
end

return lazy_hooks.bind(M, 'scripts.mom.actions.place_ref.runtime', {
  matchesTarget = true, capture = true, apply = true, revert = true,
  advance = true, prepareTransition = true,
})
