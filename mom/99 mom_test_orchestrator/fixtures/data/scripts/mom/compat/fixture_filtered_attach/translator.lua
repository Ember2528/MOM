local source_ir = require('scripts.mom.compiler.source_ir')
local M = {
  id = 'fixture_filtered_attach', abiVersion = 1, behaviorVersion = 0,
  configDirs = {'scripts/fixture_filtered_attach/data'},
}

function M.matchesPath(path) return path == 'scripts/fixture_filtered_attach/data/one.yaml' end

function M.translateSource(source)
  local path = source.path
  local function fields(id, priority, children)
    return {family = 'place_ref', diagnosticId = 'fixture:' .. id, priority = priority,
      source = {adapterId = M.id, file = path, variant = 'fixture', path = {id}},
      children = children}
  end
  local high = source_ir.sourceActionOwned({disableOriginal = true,
    attach = {{'furn_de_tapestry_02', {20, 0, 0}, {'exclude', 'furn_sign_arms_01'}}}},
    fields('high', 100))
  local low = source_ir.sourceActionOwned({disableOriginal = true,
    attach = {{'furn_de_tapestry_03', {40, 0, 0}}}}, fields('low', 0))
  local parent = fields('parent', 0, {high, low})
  return {source_ir.sourceActionOwned({place = {
    {'Balmora, Eight Plates', 'furn_de_tapestry_04', {5200, 1850, -311}, {yaw = 0}},
    {'Balmora, Eight Plates', 'furn_sign_arms_01', {5300, 1850, -311}, {yaw = 0}},
  }}, parent)}, true
end
return M
