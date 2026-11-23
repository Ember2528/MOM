local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local EXTERIOR_STATIC_SOURCE_IDS = {
  furn_crate_lid_01 = true,
}
local EXTERIOR_STATIC_REPLACEMENT_IDS = {
  furn_crate_open_01 = true,
}
local EXTERIOR_STATIC_REPLACEMENT_TOLERANCE = 8
local function countReplacementsNearSources(cell)
  local sourcePositions = {}
  H.eachCellObject(cell, function(obj)
    if H.objectMatchesRecordSet(obj, EXTERIOR_STATIC_SOURCE_IDS) then
      sourcePositions[#sourcePositions + 1] = H.copyPosition(obj.position)
    end
  end)

  local count = 0
  H.eachCellObject(cell, function(obj)
    if H.objectMatchesRecordSet(obj, EXTERIOR_STATIC_REPLACEMENT_IDS)
        and obj.enabled ~= false then
      for i = 1, #sourcePositions do
        if H.positionNear(obj.position, sourcePositions[i], EXTERIOR_STATIC_REPLACEMENT_TOLERANCE) then
          count = count + 1
          return
        end
      end
    end
  end)
  return count
end

local function describeReplacementObjects(cell)
  local parts = {}
  H.eachCellObject(cell, function(obj)
    if H.objectMatchesRecordSet(obj, EXTERIOR_STATIC_SOURCE_IDS)
      or H.objectMatchesRecordSet(obj, EXTERIOR_STATIC_REPLACEMENT_IDS)
    then
      parts[#parts + 1] = string.format('%s:%s:%s',
        tostring(obj.id), tostring(obj.recordId), tostring(obj.enabled ~= false))
    end
  end)
  return table.concat(parts, ',')
end

local function failureDetails(cell, baseline)
  return string.format(
    'baseline enabled=%d sources=%d nearReplacements=%d totalReplacements=%d; final enabled=%d sources=%d nearReplacements=%d totalReplacements=%d; %s; objects=%s',
    baseline.enabled, baseline.sources, baseline.nearReplacements, baseline.totalReplacements,
    H.countEnabledRecords(cell, EXTERIOR_STATIC_SOURCE_IDS),
    H.countRecords(cell, EXTERIOR_STATIC_SOURCE_IDS), countReplacementsNearSources(cell),
    H.countRecords(cell, EXTERIOR_STATIC_REPLACEMENT_IDS), H.runtimeStatusText(),
    describeReplacementObjects(cell)
  )
end

return {
  id = 'balmora_exterior_lamps',
  description = 'Exterior daytime static replacement applies and reverts while the target cell is loaded.',
  run = function()
    local gridX = C.BALMORA_EXTERIOR.gridX
    local gridY = C.BALMORA_EXTERIOR.gridY

    -- Enter exterior after forcing night so daytime replacements cannot leak
    -- into the baseline when startup begins during the guarded hour window.
    H.changeWeather(C.WEST_GASH_REGION, C.WEATHER_CLEAR)
    H.advanceToHour(2.0)
    H.teleportExterior(gridX, gridY,
      H.exteriorCellCenter(gridX, gridY), 'Balmora exterior static replacement setup')
    local exteriorCell = H.requireCurrentExterior(gridX, gridY)

    local exteriorAnchor = H.findFirstObject(exteriorCell, function(obj)
      return H.objectMatchesRecordSet(obj, EXTERIOR_STATIC_SOURCE_IDS)
    end)
    H.expect(exteriorAnchor ~= nil, 'No Balmora exterior static replacement anchor found')

    local exteriorPosition = H.offsetPosition(H.copyPosition(exteriorAnchor.position), 96, 96, 128)
    H.teleportExterior(gridX, gridY, exteriorPosition, 'Balmora exterior static anchor setup')

    -- Establish a night baseline.
    H.waitUntil(function()
      return H.countEnabledRecords(exteriorCell, EXTERIOR_STATIC_SOURCE_IDS) > 0
        and countReplacementsNearSources(exteriorCell) == 0
    end, C.LONG_TIMEOUT_FRAMES, 'night exterior static replacement baseline')

    local baseline = {
      enabled = H.countEnabledRecords(exteriorCell, EXTERIOR_STATIC_SOURCE_IDS),
      nearReplacements = countReplacementsNearSources(exteriorCell),
      sources = H.countRecords(exteriorCell, EXTERIOR_STATIC_SOURCE_IDS),
      totalReplacements = H.countRecords(exteriorCell, EXTERIOR_STATIC_REPLACEMENT_IDS),
    }
    H.expect(baseline.enabled > 0, 'Night exterior static replacement baseline is empty')

    -- Keep the target cell loaded while crossing both guard boundaries. The
    -- pure scheduler suite covers offscreen routing without navmesh preloads.
    H.advanceToHour(12.0)
    exteriorCell = H.requireCurrentExterior(gridX, gridY)

    local applied, applyError = pcall(function()
      H.waitUntil(function()
        return H.countEnabledRecords(exteriorCell, EXTERIOR_STATIC_SOURCE_IDS) < baseline.enabled
          and countReplacementsNearSources(exteriorCell) > baseline.nearReplacements
      end, C.LONG_TIMEOUT_FRAMES, 'daytime exterior static replacement on entry')
    end)
    if not applied then
      error(tostring(applyError) .. '; ' .. failureDetails(exteriorCell, baseline))
    end

    -- Leave the guard window while the exterior remains observed.
    H.advanceToHour(2.0)
    exteriorCell = H.requireCurrentExterior(gridX, gridY)

    local ok, err = pcall(function()
      H.waitUntil(function()
        return H.countEnabledRecords(exteriorCell, EXTERIOR_STATIC_SOURCE_IDS) == baseline.enabled
          and countReplacementsNearSources(exteriorCell) == baseline.nearReplacements
      end, C.EXTERIOR_REVERT_TIMEOUT_FRAMES, 'loaded exterior static replacement revert',
        C.EXTERIOR_REVERT_TIMEOUT_SECONDS)
    end)
    if not ok then
      error(tostring(err) .. '; ' .. failureDetails(exteriorCell, baseline))
    end
  end,
}
