local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local V = require('scripts.mom_test_orchestrator.scenarios.support.creature_mesh_common')

return {
  id = 'creature_mesh_replacement',
  description = 'A scripted Creature keeps its base record through mesh replacement and withdrawal.',
  run = function()
    local cell = V.teleport(23)
    V.waitAbsent(cell)
    cell = H.advanceLoadedInteriorToHour(12, C.EIGHT_PLATES)
    local _, first = V.waitReady(cell)
    local recordId = tostring(first.recordId)
    cell = H.advanceLoadedInteriorToHour(23, C.EIGHT_PLATES)
    V.waitAbsent(cell)
    cell = H.advanceLoadedInteriorToHour(12, C.EIGHT_PLATES)
    local _, second = V.waitReady(cell)
    H.expect(tostring(second.recordId) == recordId, 'Reopening the guard duplicated the Creature record')
    cell = H.advanceLoadedInteriorToHour(23, C.EIGHT_PLATES)
    V.waitAbsent(cell)
    V.deactivate()
  end,
}
