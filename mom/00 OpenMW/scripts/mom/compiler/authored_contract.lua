local constants = require('scripts.mom.constants')
local M = {}
M.configVersion = constants.authoredConfigVersion
M.topLevelFields = {
  version = true,
  name = true,
  description = true,
  variants = true,
}
M.variantFields = {
  description = true,
  requires = true,
  requiresAny = true,
  requiresNot = true,
  actions = true,
  guards = true,
}
M.verbToType = {
  place = 'place_ref',
  attach = 'place_ref',
  modify = 'modify_ref',
  kill = 'kill_actor',
  inventory = 'modify_inventory',
  record = 'record_content',
  leveled = 'leveled_content',
}
M.verbKeys = { 'place', 'attach', 'modify', 'kill', 'inventory', 'record', 'leveled' }
-- Shared authored fields admitted before family syntax preparation.
M.familyInputActionFields = {
  filters = true,
  chance = true,
  id = true,
  previsit = true,
  select = true,
  actions = true,
  key = true, admission = true, targetTypes = true, onMissingTarget = true,
  requires = true, requiresAny = true, requiresNot = true,
}
M.guardBlockFields = {
  when = true,
  actions = true,
  -- Accepted here so source validation can return tailored author-facing errors.
  select = true,
  on_enter = true,
  on_exit = true,
  scope = true,
}
M.actionFieldErrors = {
  type = 'is not allowed; type is inferred from the verb key',
  match = 'is not allowed at action scope; use select.cell.match',
}
function M.actionKindForVerb(verb)
  return M.verbToType[verb]
end
function M.isInventoryOwnerItemsPayload(payload)
  return type(payload) == 'table'
    and payload[1] == nil
    and type(payload.owners) == 'table'
    and type(payload.items) == 'table'
end
function M.hasInventoryOwnerItemsKeys(payload)
  return type(payload) == 'table'
    and payload[1] == nil
    and (payload.owner ~= nil or payload.owners ~= nil or payload.items ~= nil)
end
return M
