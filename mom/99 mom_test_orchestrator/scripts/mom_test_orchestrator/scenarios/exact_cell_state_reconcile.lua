local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local R = require('scripts.mom_test_orchestrator.scenarios.support.runtime_contract_helpers')

return {
  id = 'exact_cell_state_reconcile',
  description = 'Exact cross-cell state actions reconcile on target-cell load after the guard window changes.',
  run = function()
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
    H.advanceToHour(2.0)

    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'Guild exact-cell state baseline')
    local guildCell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    H.waitUntil(function()
      return R.objectEnabledNear(guildCell,
        C.CROSS_CELL_GUILD_TARGET_RECORD_ID,
        C.CROSS_CELL_GUILD_TARGET_POSITION, C.CROSS_CELL_TARGET_TOLERANCE)
    end, C.LONG_TIMEOUT_FRAMES, 'Guild exact-cell target enabled baseline')

    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates exact-cell state baseline')
    local eightPlatesCell = H.requireCurrentInterior(C.EIGHT_PLATES)
    H.waitUntil(function()
      return R.objectEnabledNear(eightPlatesCell,
        C.CROSS_CELL_EIGHT_PLATES_TARGET_RECORD_ID,
        C.CROSS_CELL_EIGHT_PLATES_TARGET_POSITION, C.CROSS_CELL_TARGET_TOLERANCE)
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates exact-cell target enabled baseline')

    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION,
      'move away from exact target cells')
    H.advanceToHour(7.0)

    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'Guild exact-cell state applied check')
    guildCell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    H.waitUntil(function()
      return R.objectDisabledNear(guildCell,
        C.CROSS_CELL_GUILD_TARGET_RECORD_ID,
        C.CROSS_CELL_GUILD_TARGET_POSITION, C.CROSS_CELL_TARGET_TOLERANCE)
    end, C.LONG_TIMEOUT_FRAMES, 'Guild exact-cell target disabled after load')

    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates exact-cell state applied check')
    eightPlatesCell = H.requireCurrentInterior(C.EIGHT_PLATES)
    H.waitUntil(function()
      return R.objectDisabledNear(eightPlatesCell,
        C.CROSS_CELL_EIGHT_PLATES_TARGET_RECORD_ID,
        C.CROSS_CELL_EIGHT_PLATES_TARGET_POSITION, C.CROSS_CELL_TARGET_TOLERANCE)
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates exact-cell target disabled after load')

    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION,
      'move away before exact-cell state revert')
    H.advanceToHour(12.0)

    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'Guild exact-cell state reverted check')
    guildCell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    H.waitUntil(function()
      return R.objectEnabledNear(guildCell,
        C.CROSS_CELL_GUILD_TARGET_RECORD_ID,
        C.CROSS_CELL_GUILD_TARGET_POSITION, C.CROSS_CELL_TARGET_TOLERANCE)
    end, C.LONG_TIMEOUT_FRAMES, 'Guild exact-cell target restored')

    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates exact-cell state reverted check')
    eightPlatesCell = H.requireCurrentInterior(C.EIGHT_PLATES)
    H.waitUntil(function()
      return R.objectEnabledNear(eightPlatesCell,
        C.CROSS_CELL_EIGHT_PLATES_TARGET_RECORD_ID,
        C.CROSS_CELL_EIGHT_PLATES_TARGET_POSITION, C.CROSS_CELL_TARGET_TOLERANCE)
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates exact-cell target restored')
  end,
}
