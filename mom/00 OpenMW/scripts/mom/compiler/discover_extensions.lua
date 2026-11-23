-- Discovers one caller-owned catalog for a startup compilation. Registry
-- tables belong to that attempt; loaded extension modules use ordinary require.
local M = {}

function M.discover(prepared)
  prepared = prepared or {}
  local compat_registry = require('scripts.mom.compat.registry')
  local module_loader = require('scripts.mom.compiler.module_loader')
  return {
    kind = 'mom-extension-catalog',
    actions = prepared.actions or module_loader.buildActionRegistry(),
    guards = prepared.guards or module_loader.buildGuardRegistry(),
    compat = prepared.compat or compat_registry.buildRegistry(),
  }
end

return M
