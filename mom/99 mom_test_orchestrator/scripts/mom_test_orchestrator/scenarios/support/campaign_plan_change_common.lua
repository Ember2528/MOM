local H = require('scripts.mom_test_orchestrator.helpers')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local M = {
  V1 = {x = 1840.0, y = 960.0, z = -311.0},
  V2 = {x = 1920.0, y = 960.0, z = -311.0},
}

function M.count(cell, position)
  return H.countRecordNearPosition(cell, G.RECORD, position, 16)
end

function M.waitCount(cell, position, expected, description)
  H.waitUntil(function() return M.count(cell, position) == expected end,
    1800, description)
end

return M
