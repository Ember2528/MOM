-- Copies and canonicalizes hand-authored seeds for the ownership-taking
-- assembler. Production source compilation already establishes these orders.
local M = {}

local manifest_assembler = require('scripts.mom.compiler.manifest_assembler')
local plain_data = require('scripts.mom.contracts.plain_data')

function M.assemble(seed)
  local owned, errors = plain_data.detach(seed or {}, {path = 'fixtureManifestSeed'})
  if not owned then return nil, errors end
  for _, owner in ipairs(owned.owners or {}) do
    table.sort(owner.actionIds or {})
    table.sort(owner.subscriptions or {})
  end
  for _, actionIds in pairs(owned.indexes and owned.indexes.staticByCell or {}) do
    table.sort(actionIds)
  end
  return manifest_assembler.assembleCompiled(owned)
end

return M
