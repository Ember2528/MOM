-- Validates and copies hand-authored normalized IR for focused compiler cases.
-- Installed sources reach compileOwned only through source_lowering's proof.
local M = {}

local claim_contract = require('scripts.mom.contracts.claim_contract')
local extension_catalog = require('scripts.mom.contracts.extension_catalog')
local plain_data = require('scripts.mom.contracts.plain_data')
local program_contract = require('scripts.mom.compiler.program_contract')
local compile_manifest = require('scripts.mom.compiler.compile_manifest')

local function validateActions(actions, catalog)
  for i = 1, #(actions or {}) do
    local node = actions[i]
    local entry = catalog.actions.byId[node.family]
    if entry ~= nil then
      local valid, errors = program_contract.validateWithCompiler(
        node.program, node.id, entry.module)
      if not valid then return nil, errors end
      local claims, claimErrors = claim_contract.normalize(
        node.claims and node.claims.keys,
        node.family,
        'action:' .. tostring(node.id) .. '.claims.keys',
        {nonEmpty = true})
      if not claims then return nil, claimErrors end
      node.claims.keys = claims
    end
    local adapterId = node.source and node.source.adapterId
    if adapterId ~= nil and adapterId ~= 'native' and adapterId ~= 'unknown'
        and catalog.compat.byId[adapterId] == nil then
      return nil, {'compat extension ' .. tostring(adapterId) .. ' is not registered'}
    end
    local childrenValid, childErrors = validateActions(node.children, catalog)
    if not childrenValid then return nil, childErrors end
  end
  return true, nil
end

function M.compile(normalizedIr, compileCtx, opts)
  local catalog = opts and opts.catalog
  local validCatalog, catalogErrors = extension_catalog.validate(catalog)
  if not validCatalog then return nil, catalogErrors end
  local owned, copyErrors = plain_data.detach(normalizedIr, {path = 'fixtureSource'})
  if not owned then return nil, copyErrors end
  local valid, errors = validateActions(owned.actions, catalog)
  if not valid then return nil, errors end
  return compile_manifest.compileOwned(owned, compileCtx, catalog)
end

return M
