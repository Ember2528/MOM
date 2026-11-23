local inventory = require('scripts.mom_test_orchestrator.scenario_inventory')
local M = {}

-- Preserve catalog execution order while loading only selected modules.
function M.select(ids)
  if type(ids) ~= 'table' or #ids == 0 then ids = inventory.ordinary end
  local selected, out = {}, {}
  for _, id in ipairs(ids) do
    assert(inventory.fixtures[id], 'unknown scenario id: ' .. tostring(id))
    assert(not selected[id], 'duplicate scenario id: ' .. id)
    selected[id] = true
  end
  for _, group in ipairs({inventory.campaign, inventory.ordinary, inventory.stress}) do
    for _, id in ipairs(group) do
      if selected[id] then
        local scenario = require('scripts.mom_test_orchestrator.scenarios.' .. id)
        assert(scenario.id == id and type(scenario.run) == 'function',
          'invalid scenario module: ' .. id)
        out[#out + 1] = scenario
      end
    end
  end
  return out
end
return M
