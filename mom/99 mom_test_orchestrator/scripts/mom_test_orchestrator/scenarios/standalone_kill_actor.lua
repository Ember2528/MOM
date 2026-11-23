local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local STANDALONE_KILL_RAT_ID = 'rat'
local STANDALONE_KILL_FORAGER_ID = 'kwama forager'
local STANDALONE_KILL_RAT_POSITION = {
  x = 1110.0,
  y = 840.0,
  z = -311.0,
}
local STANDALONE_KILL_FORAGER_POSITION = {
  x = 1130.0,
  y = 860.0,
  z = -311.0,
}
local STANDALONE_KILL_MUDCRAB_POSITION = {
  x = 1150.0,
  y = 880.0,
  z = -311.0,
}
local TARGETS = {
  {
    recordId = STANDALONE_KILL_RAT_ID,
    position = STANDALONE_KILL_RAT_POSITION,
  },
  {
    recordId = STANDALONE_KILL_FORAGER_ID,
    position = STANDALONE_KILL_FORAGER_POSITION,
  },
  {
    recordId = C.MUDCRAB_RECORD_ID,
    position = STANDALONE_KILL_MUDCRAB_POSITION,
  },
}

local function findTarget(cell, target)
  return H.findFirstObject(cell, function(obj)
    return H.objectRecordId(obj) == H.normalizeRecordId(target.recordId)
      and H.sameStartingIdentity(obj, C.EIGHT_PLATES, target.position, 8)
  end)
end

local function allTargetsLiving(cell)
  for i = 1, #TARGETS do
    local obj = findTarget(cell, TARGETS[i])
    if obj == nil or H.objectIsDead(obj) then
      return false
    end
  end
  return true
end

local function allTargetsRemoved(cell)
  for i = 1, #TARGETS do
    if findTarget(cell, TARGETS[i]) ~= nil then
      return false
    end
  end
  return true
end

local function targetStatus(cell)
  local rows = {}
  for i = 1, #TARGETS do
    local target = TARGETS[i]
    local obj = findTarget(cell, target)
    rows[i] = table.concat({
      target.recordId,
      'present=' .. tostring(obj ~= nil),
      'dead=' .. tostring(obj ~= nil and H.objectIsDead(obj)),
      'enabled=' .. tostring(obj ~= nil and obj.enabled ~= false),
    }, ':')
  end
  return 'targets={' .. table.concat(rows, ',') .. '}'
end

return {
  id = 'standalone_kill_actor',
  description = 'Vanilla placed creatures are killed by delayed standalone quest-stage kill_actor guards.',
  run = function()
    H.setQuestStage(C.KNIGHT_AKAY_QUEST, 0)
    H.advanceToHour(23.0)

    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates standalone kill_actor setup')
    local cell = H.requireCurrentInterior(C.EIGHT_PLATES)

    H.waitUntil(function()
      return allTargetsRemoved(cell)
    end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates standalone kill_actor night baseline')

    H.advanceToHour(12.0)
    local baselineOk, baselineError = pcall(function()
      H.waitUntil(function()
        return allTargetsLiving(cell)
      end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates standalone kill_actor baseline')
    end)
    if not baselineOk then
      error(tostring(baselineError) .. '; ' .. H.runtimeStatusText())
    end

    local deaths = {}
    for i = 1, #TARGETS do
      local target = TARGETS[i]
      deaths[i] = H.watchActorDeath(cell, {
        recordId = target.recordId,
        position = target.position,
        objectId = assert(findTarget(cell, target)).id,
      })
    end
    H.setQuestStage(C.KNIGHT_AKAY_QUEST, 10)
    local killed, killError = pcall(function()
      H.waitUntil(function()
        for i = 1, #deaths do
          if H.actorDeathObserved(deaths[i]) == nil then return false end
        end
        return true
      end, C.LONG_TIMEOUT_FRAMES,
        'Eight Plates standalone kill_actor targets are observed dead')
    end)
    if not killed then
      error(tostring(killError) .. '; ' .. targetStatus(cell)
        .. '; ' .. H.runtimeStatusText())
    end

    H.setQuestStage(C.KNIGHT_AKAY_QUEST, 0)
    H.advanceToHour(23.0)
    local cleanupOk, cleanupError = pcall(function()
      H.waitUntil(function()
        return allTargetsRemoved(cell)
      end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates standalone kill_actor cleanup')
    end)
    if not cleanupOk then
      error(tostring(cleanupError) .. '; ' .. targetStatus(cell)
        .. '; ' .. H.runtimeStatusText())
    end
  end,
}
