local support = require('pure.test_support')
local expect = support.expect
local M = {}

local function fixture(callback)
  local worldName = 'scripts.mom_test_orchestrator.support.world'
  local old = package.loaded[worldName]
  local cell = {id = 'fixture-cell', objects = {}}
  local world = {
    objectRecordId = function(actor) return actor.recordId end,
    objectIsDead = function(actor) return actor.valid ~= false and actor.dead == true end,
    sameStartingIdentity = function(actor, id, position)
      return actor.cellId == id and actor.position.x == position.x
    end,
    eachCellObject = function(value, visit)
      for _, actor in ipairs(value.objects) do visit(actor) end
    end,
  }
  package.loaded[worldName] = world
  local ok, err = pcall(function()
    local observer = assert(loadfile(arg[1]
      .. '/mom/99 mom_test_orchestrator/scripts/mom_test_orchestrator/support/actor_observation.lua'))()
    local function actor(id, x, dead)
      return {id = id, recordId = 'mudcrab', cellId = cell.id,
        position = {x = x or 1}, dead = dead == true}
    end
    callback(observer, cell, actor)
  end)
  package.loaded[worldName] = old
  if not ok then error(err, 0) end
end

local function rejectsUnrelatedAndDisappearedActors()
  fixture(function(observer, cell, actor)
    local watch = observer.watchActorDeath(cell, {recordId = 'mudcrab', position = {x = 1}})
    observer.observeActorActive(actor('unrelated', 2, true))
    local target = actor('target')
    observer.observeActorActive(target)
    target.valid = false
    observer.updateActorObservations()
    expect(observer.actorDeathObserved(watch) == nil,
      'unrelated death or living-target disappearance satisfied the watch')
  end)
end

local function retainsObservedDeathAndSeparatesGenerations()
  fixture(function(observer, cell, actor)
    local target = actor('first')
    local first = observer.watchActorDeath(cell, {recordId = 'mudcrab', position = {x = 1}})
    observer.observeActorActive(target)
    target.dead = true
    observer.updateActorObservations()
    target.valid = false
    observer.updateActorObservations()
    expect(observer.actorDeathObserved(first) == 'first', 'observed death vanished with the handle')
    local second = observer.watchActorDeath(cell, {recordId = 'mudcrab', position = {x = 1}})
    expect(observer.actorDeathObserved(second) == nil, 'new generation inherited prior evidence')
    local replacement = actor('second')
    observer.observeActorActive(replacement)
    observer.updateActorObservations()
    expect(observer.actorDeathObserved(second) == nil, 'living replacement satisfied the new watch')
    replacement.dead = true
    observer.updateActorObservations()
    expect(observer.actorDeathObserved(second) == 'second', 'new generation lost its own death')
  end)
end

local function ignoresExistingCorpsesAndBindsKnownActors()
  fixture(function(observer, cell, actor)
    local corpse, living = actor('old', 1, true), actor('expected')
    cell.objects = {corpse, living}
    local generated = observer.watchActorDeath(cell, {recordId = 'mudcrab', position = {x = 1}})
    local known = observer.watchActorDeath(cell, {
      recordId = 'mudcrab', position = {x = 1}, objectId = 'expected',
    })
    observer.observeActorActive(corpse)
    observer.observeActorActive(actor('different-instance', 1, true))
    expect(observer.actorDeathObserved(known) == nil,
      'a different instance satisfied a bound actor watch')
    expect(observer.actorDeathObserved(generated) ~= 'old', 'existing corpse proved a new death')
    living.dead = true
    observer.updateActorObservations()
    expect(observer.actorDeathObserved(known) == 'expected', 'bound living actor was not observed')
    observer.resetActorObservations()
    local fresh = observer.watchActorDeath({id = cell.id, objects = {}}, {
      recordId = 'mudcrab', position = {x = 1},
    })
    expect(observer.actorDeathObserved(fresh) == nil, 'scenario reset retained death evidence')
  end)
end

local function scenarioRequiresItsActualWorldEffect()
  for _, kill in ipairs({false, true}) do
    fixture(function(observer, cell, actor)
      local helperName = 'scripts.mom_test_orchestrator.helpers'
      local constantsName = 'scripts.mom_test_orchestrator.constants'
      local oldHelpers, oldConstants = package.loaded[helperName], package.loaded[constantsName]
      local targets = {actor('rat', 1110), actor('forager', 1130), actor('mudcrab', 1150)}
      targets[1].recordId, targets[2].recordId = 'rat', 'kwama forager'
      local helpers = {}
      for key, value in pairs(observer) do helpers[key] = value end
      helpers.teleportInterior = function() end
      helpers.requireCurrentInterior = function() return cell end
      helpers.advanceToHour = function(hour)
        cell.objects = hour == 12 and targets or {}
      end
      helpers.setQuestStage = function(_, stage)
        if stage == 10 then
          for _, target in ipairs(targets) do target.dead = kill end
          observer.updateActorObservations()
        end
      end
      helpers.findFirstObject = function(value, predicate)
        for _, object in ipairs(value.objects) do if predicate(object) then return object end end
      end
      helpers.objectRecordId = function(object) return object.recordId end
      helpers.objectIsDead = function(object) return object.dead end
      helpers.normalizeRecordId = function(value) return value end
      helpers.sameStartingIdentity = function(object, _, position)
        return object.position.x == position.x
      end
      helpers.runtimeStatusText = function() return 'fixture runtime' end
      helpers.waitUntil = function(predicate, _, message) assert(predicate(), message) end
      package.loaded[helperName] = helpers
      package.loaded[constantsName] = {
        EIGHT_PLATES = cell.id, EIGHT_PLATES_SAFE_POSITION = {},
        MUDCRAB_RECORD_ID = 'mudcrab', LONG_TIMEOUT_FRAMES = 1,
      }
      local ok, err = pcall(function()
        local scenario = assert(loadfile(arg[1]
          .. '/mom/99 mom_test_orchestrator/scripts/mom_test_orchestrator/scenarios/standalone_kill_actor.lua'))()
        scenario.run()
      end)
      package.loaded[helperName], package.loaded[constantsName] = oldHelpers, oldConstants
      expect(ok == kill, 'kill scenario accepted the wrong world outcome: ' .. tostring(err))
    end)
  end
end

function M.run()
  return support.runCases('pure actor observation', {
    {'unrelated actors and disappearance are inconclusive', rejectsUnrelatedAndDisappearedActors},
    {'death survives disappearance and stays with its generation', retainsObservedDeathAndSeparatesGenerations},
    {'existing corpses and other instances do not prove a bound effect', ignoresExistingCorpsesAndBindsKnownActors},
    {'actual kill scenario requires its world effect', scenarioRequiresItsActualWorldEffect},
  })
end

return M
