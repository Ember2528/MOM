-- Run the real scenario assertions against both a correct world and the
-- counterexample each assertion must reject. These are harness tests only.
local support = require('pure.test_support')
local expect = support.expect
local C = require('scripts.mom_test_orchestrator.constants')
local M = {}

local function checkScenario(id, setup, failureText)
  for _, broken in ipairs({false, true}) do
    local H = {expect = assert, scaleNear = function(a, b, tolerance)
      return math.abs(a - b) <= (tolerance or 0.01)
    end}
    H.waitUntil = function(predicate, _, description) assert(predicate(), description) end
    local cell = {}
    H.teleportInterior = function() end
    H.requireCurrentInterior = function() return cell end
    H.teleportInteriorAtHour = function() return cell end
    setup(H, cell, broken)
    local name = 'scripts.mom_test_orchestrator.helpers'
    local old = package.loaded[name]
    package.loaded[name] = H
    local ok, err = pcall(function()
      assert(loadfile(arg[1] .. '/mom/99 mom_test_orchestrator/'
        .. 'scripts/mom_test_orchestrator/scenarios/' .. id .. '.lua'))().run()
    end)
    package.loaded[name] = old
    expect(ok == not broken, id .. ' accepted the wrong world outcome: ' .. tostring(err))
    if broken then
      expect(tostring(err):find(failureText, 1, true),
        id .. ' failed before checking its counterexample: ' .. tostring(err))
    end
  end
end

local function exclusionChecksBothCells()
  checkScenario('cell_exclude', function(H, cell, broken)
    local witnessed = false
    H.recordSetDisabled = function() return true end
    H.countRecordNearPosition = function() witnessed = true; return 1 end
    H.teleportInteriorReady = function(_, _, _, predicate)
      assert(predicate(cell)); return cell
    end
    H.countRecords = function() return 2 end
    H.countEnabledRecords = function()
      assert(witnessed, 'excluded-cell check ran before its positive witness')
      return broken and 1 or 2
    end
  end, 'Cell exclusion changed')
end

local function conflictRejectsBothActions()
  checkScenario('guard_conflict', function(H, cell, broken)
    local bottle = {enabled = true, scale = 1, isValid = function() return true end}
    H.advanceToHour = function(hour)
      bottle.enabled = hour ~= 21
      bottle.scale = broken and hour == 21 and 0.8 or 1
    end
    H.advanceLoadedInteriorToHour = function(hour) H.advanceToHour(hour); return cell end
    H.countRecordNearPosition = function() return bottle.enabled and 1 or 0 end
    H.findRecordNearPosition = function() return bottle end
  end, 'Conflict loser scaled')
end

local function duplicatesPreserveSibling()
  checkScenario('targeting_duplicates', function(H, cell, broken)
    local refs = {
      {recordId = 'misc_com_bottle_05', x = -294.999},
      {recordId = 'misc_com_bottle_05', x = -309.109},
      {recordId = 'misc_de_goblet_01', x = -119.565},
      {recordId = 'misc_com_bottle_05', x = -400},
    }
    for _, ref in ipairs(refs) do
      ref.enabled = true
      ref.isValid = function() return true end
    end
    H.findFirstObject = function(_, predicate)
      for _, ref in ipairs(refs) do if predicate(ref) then return ref end end
    end
    H.objectRecordId = function(ref) return ref.recordId end
    H.sameStartingIdentity = function(ref, _, position) return ref.x == position.x end
    H.advanceLoadedInteriorToHour = function(hour)
      for i, ref in ipairs(refs) do
        ref.enabled = hour ~= 12 or (i == 4 and not broken)
      end
      return cell
    end
  end, 'unselected same-record sibling')
end

function M.run()
  return support.runCases('scenario evidence', {
    {'cell exclusion observes excluded targets', exclusionChecksBothCells},
    {'conflict rejects loser-only effect', conflictRejectsBothActions},
    {'duplicate selection preserves a sibling', duplicatesPreserveSibling},
  })
end
return M
