-- Shared accepted/rejected result shape for compilation and startup candidates.
-- The payload remains owned by the producing boundary; constructors do not
-- clone manifests or extension catalogs.
local M = {}

function M.accepted(fields)
  fields = fields or {}
  return {
    status = 'accepted',
    manifest = fields.manifest,
    diagnostics = fields.diagnostics,
    extensionCatalog = fields.extensionCatalog,
  }
end

function M.rejected(fields)
  fields = fields or {}
  return {
    status = 'rejected',
    diagnostics = fields.diagnostics,
    fatal = fields.fatal,
  }
end

function M.isAccepted(value)
  return type(value) == 'table' and value.status == 'accepted'
end

function M.isRejected(value)
  return type(value) == 'table' and value.status == 'rejected'
end

return M
