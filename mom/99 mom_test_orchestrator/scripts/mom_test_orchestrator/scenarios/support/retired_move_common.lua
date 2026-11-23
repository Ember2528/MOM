local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local M = {
  RECORD = 'light_de_paper_lantern_off',
  POSITION = {x = 1800, y = 800, z = -311},
  TOGGLE = 'campaign_retired_move',
}

function M.count(cell)
  return H.countObjects(cell, function(obj)
    return H.objectRecordId(obj) == M.RECORD
      and H.positionNear(obj.position, M.POSITION, 16)
  end)
end

function M.destination()
  H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
    'retired child destination')
  return H.requireCurrentInterior(C.GUILD_OF_MAGES)
end

return M
