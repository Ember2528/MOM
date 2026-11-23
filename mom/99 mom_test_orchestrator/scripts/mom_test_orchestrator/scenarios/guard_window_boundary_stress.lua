local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local MARKER_RECORD_ID = C.CHILD_LANTERN_RECORD_ID
local MARKER_TOLERANCE = 24

local MARKER_POSITIONS = {
  { x = 1320.0, y = 1120.0, z = -311.0 },
  { x = 1400.0, y = 1120.0, z = -311.0 },
  { x = 1480.0, y = 1120.0, z = -311.0 },
  { x = 1560.0, y = 1120.0, z = -311.0 },
  { x = 1320.0, y = 1200.0, z = -311.0 },
  { x = 1400.0, y = 1200.0, z = -311.0 },
  { x = 1480.0, y = 1200.0, z = -311.0 },
  { x = 1560.0, y = 1200.0, z = -311.0 },
  { x = 1320.0, y = 1280.0, z = -311.0 },
  { x = 1400.0, y = 1280.0, z = -311.0 },
  { x = 1480.0, y = 1280.0, z = -311.0 },
  { x = 1560.0, y = 1280.0, z = -311.0 },
  { x = 1320.0, y = 1360.0, z = -311.0 },
  { x = 1400.0, y = 1360.0, z = -311.0 },
  { x = 1480.0, y = 1360.0, z = -311.0 },
  { x = 1560.0, y = 1360.0, z = -311.0 },
}

local function waitForMarkerCount(cell, expected, description)
  H.waitUntil(function()
    return H.placementsMatch(cell, MARKER_RECORD_ID, MARKER_POSITIONS,
      expected == 0 and 0 or 1, MARKER_TOLERANCE)
  end, C.LONG_TIMEOUT_FRAMES, description)
end

return {
  id = 'guard_window_boundary_stress',
  description = 'A time window places and removes every authored marker.',
  run = function()
    H.advanceToHour(1.0)
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates guard-window boundary stress setup')
    local cell = H.requireCurrentInterior(C.EIGHT_PLATES)

    waitForMarkerCount(cell, 0, 'boundary stress inactive baseline')

    H.advanceToHour(7.0)
    waitForMarkerCount(cell, #MARKER_POSITIONS, 'boundary stress window opens')

    H.advanceToHour(11.0)
    waitForMarkerCount(cell, 0, 'boundary stress window closes')
  end,
}
