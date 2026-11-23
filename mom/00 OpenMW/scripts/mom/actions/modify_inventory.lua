-- Reversible inventory action family for the MOM runtime.
local compiler = require('scripts.mom.actions.modify_inventory.compile')
local lazy_hooks = require('scripts.mom.common.lazy_action_hooks')

local M = {
  id = 'modify_inventory',
  verbs = {'inventory'},
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

return lazy_hooks.bind(M, 'scripts.mom.actions.modify_inventory.runtime', {
  matchesTarget = true, capture = true, apply = true, revert = true,
  advance = true, complete = true, prepareTransition = true,
})
