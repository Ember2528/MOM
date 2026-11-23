local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local DIRECT_CHILD_LANTERN_RECORD_ID = 'light_de_paper_lantern_off'
local DIRECT_CHILD_LANTERN_POSITION = {
  x = 1090.0,
  y = 920.0,
  z = -311.0,
}
local DIRECT_CHILD_LANTERN_SCALE = 1.2
local DIRECT_CHILD_BARREL_RECORD_ID = 'barrel_01'
local DIRECT_CHILD_BARREL_POSITION = {
  x = 1160.0,
  y = 920.0,
  z = -311.0,
}
local DIRECT_CHILD_BARREL_GOLD_ID = 'gold_001'
local DIRECT_CHILD_BARREL_GOLD_COUNT = 7
local DIRECT_CHILD_RAT_RECORD_ID = 'rat'
local DIRECT_CHILD_RAT_POSITION = {
  x = 1180.0,
  y = 920.0,
  z = -311.0,
}
-- Config: balmora_child_direct_payloads_example.yaml
--
-- Guard (6-20 exclusive) owns three place_ref parents. Their child actions use
-- direct payloads, so the runtime must inherit each parent output target for
-- modify, inventory, and kill_actor.

return {
  id = 'child_direct_payloads',
  description = 'Direct child payloads inherit and release parent outputs across guard cycles.',
  run = function()
    local targetTolerance = 24

    local function countNearAny(cell, recordId, position)
      return H.countObjects(cell, function(obj)
        return H.objectRecordId(obj) == H.normalizeRecordId(recordId)
          and H.positionNear(obj.position, position, targetTolerance)
      end)
    end

    local function countNearEnabled(cell, recordId, position)
      return H.countRecordNearPosition(cell, recordId, position, targetTolerance)
    end

    local function countNearLiving(cell, recordId, position)
      return H.countObjects(cell, function(obj)
        return H.objectRecordId(obj) == H.normalizeRecordId(recordId)
          and H.positionNear(obj.position, position, targetTolerance)
          and not H.objectIsDead(obj)
      end)
    end

    local function countDirectRat(cell, livingOnly)
      return H.countObjects(cell, function(obj)
        if H.objectRecordId(obj) ~= H.normalizeRecordId(DIRECT_CHILD_RAT_RECORD_ID) then
          return false
        end
        if not H.sameStartingIdentity(obj, C.EIGHT_PLATES, DIRECT_CHILD_RAT_POSITION, 8) then
          return false
        end
        return livingOnly ~= true or not H.objectIsDead(obj)
      end)
    end

    local function placementSummary(cell)
      local ratSet = { [DIRECT_CHILD_RAT_RECORD_ID] = true }
      return string.format(
        'lantern near enabled/any=%d/%d, barrel near enabled/any=%d/%d, direct rat start any/living=%d/%d, direct rat near any/living=%d/%d, rats total/living=%d/%d',
        countNearEnabled(cell, DIRECT_CHILD_LANTERN_RECORD_ID, DIRECT_CHILD_LANTERN_POSITION),
        countNearAny(cell, DIRECT_CHILD_LANTERN_RECORD_ID, DIRECT_CHILD_LANTERN_POSITION),
        countNearEnabled(cell, DIRECT_CHILD_BARREL_RECORD_ID, DIRECT_CHILD_BARREL_POSITION),
        countNearAny(cell, DIRECT_CHILD_BARREL_RECORD_ID, DIRECT_CHILD_BARREL_POSITION),
        countDirectRat(cell, false),
        countDirectRat(cell, true),
        countNearAny(cell, DIRECT_CHILD_RAT_RECORD_ID, DIRECT_CHILD_RAT_POSITION),
        countNearLiving(cell, DIRECT_CHILD_RAT_RECORD_ID, DIRECT_CHILD_RAT_POSITION),
        H.countRecords(cell, ratSet),
        H.countLivingRecords(cell, ratSet)
      )
    end

    local function waitForAbsence(cell, label)
      local cleared, clearError = pcall(function()
        H.waitUntil(function()
          return countNearEnabled(cell, DIRECT_CHILD_LANTERN_RECORD_ID, DIRECT_CHILD_LANTERN_POSITION) == 0
            and countNearEnabled(cell, DIRECT_CHILD_BARREL_RECORD_ID, DIRECT_CHILD_BARREL_POSITION) == 0
            and countDirectRat(cell, false) == 0
        end, C.LONG_TIMEOUT_FRAMES, label)
      end)
      if not cleared then
        error(tostring(clearError) .. '; ' .. placementSummary(cell))
      end
    end

    local cell = H.teleportInteriorAtHour(23.0, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates direct child payload night baseline')
    waitForAbsence(cell, 'Eight Plates direct child payloads absent before day guard opens')

    -- Repeating the guard cycle proves that permanent children release their
    -- parent outputs and that a fresh placement generation can run its children.
    local previousRatId
    for generation = 1, 2 do
      local death = H.watchActorDeath(cell, {
        recordId = DIRECT_CHILD_RAT_RECORD_ID,
        position = DIRECT_CHILD_RAT_POSITION,
      })
      cell = H.advanceLoadedInteriorToHour(12.0, C.EIGHT_PLATES)

      H.waitUntil(function()
        return countNearEnabled(cell, DIRECT_CHILD_LANTERN_RECORD_ID, DIRECT_CHILD_LANTERN_POSITION) > 0
          and countNearEnabled(cell, DIRECT_CHILD_BARREL_RECORD_ID, DIRECT_CHILD_BARREL_POSITION) > 0
      end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates direct child non-actor refs: ' .. placementSummary(cell))

      local lantern = H.findRecordNearPosition(cell, DIRECT_CHILD_LANTERN_RECORD_ID,
        DIRECT_CHILD_LANTERN_POSITION, targetTolerance)
      H.expect(lantern ~= nil, 'Direct child lantern not found near expected position')
      local scaled, scaleError = pcall(function()
        H.waitUntil(function()
          return H.scaleNear(lantern.scale, DIRECT_CHILD_LANTERN_SCALE, 0.02)
        end, C.LONG_TIMEOUT_FRAMES, 'Direct child modify scaled lantern')
      end)
      if not scaled then
        error(tostring(scaleError)
          .. '; scale=' .. tostring(lantern.scale)
          .. '; ' .. placementSummary(cell)
          .. '; ' .. H.runtimeStatusText())
      end

      local barrel = H.findRecordNearPosition(cell, DIRECT_CHILD_BARREL_RECORD_ID,
        DIRECT_CHILD_BARREL_POSITION, targetTolerance)
      H.expect(barrel ~= nil, 'Direct child barrel not found near expected position')
      H.waitUntil(function()
        return H.countContainerRecord(barrel, DIRECT_CHILD_BARREL_GOLD_ID) >= DIRECT_CHILD_BARREL_GOLD_COUNT
      end, C.LONG_TIMEOUT_FRAMES, 'Direct child inventory populated barrel')

      H.waitUntil(function()
        return H.actorDeathObserved(death) ~= nil
      end, C.LONG_TIMEOUT_FRAMES,
        'Direct child rat is observed dead: '
          .. placementSummary(cell))
      local ratId = H.actorDeathObserved(death)
      H.expect(ratId ~= previousRatId,
        'A previous generation satisfied the direct child kill assertion')
      previousRatId = ratId

      cell = H.advanceLoadedInteriorToHour(23.0, C.EIGHT_PLATES)
      waitForAbsence(cell,
        'Direct child outputs removed after day guard closes, generation ' .. generation)
    end
  end,
}
