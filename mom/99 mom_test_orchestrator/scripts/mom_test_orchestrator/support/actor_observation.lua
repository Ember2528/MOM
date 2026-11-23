-- Scenario-owned evidence from concrete OpenMW actors. Journal status and
-- disappearance never stand in for an observed death.
local world = require('scripts.mom_test_orchestrator.support.world')

local M = {}
local watches = {}

local function matches(watch, actor)
  return world.objectRecordId(actor) == watch.recordId
    and (watch.objectId == nil or actor.id == watch.objectId)
    and world.sameStartingIdentity(actor, watch.cellId, watch.position, 8)
end

local function observe(watch, actor)
  local ok, id = pcall(function()
    if not matches(watch, actor) or watch.ignored[actor.id] then return nil end
    return actor.id
  end)
  if not ok or id == nil then return end
  watch.actors[id] = actor
  if world.objectIsDead(actor) then watch.deaths[id] = true end
end

function M.watchActorDeath(cell, target)
  local watch = {
    recordId = target.recordId:lower(),
    cellId = cell.id,
    position = target.position,
    objectId = target.objectId,
    actors = {},
    deaths = {},
    ignored = {},
  }
  -- Existing corpses cannot establish a new generation's effect. Existing
  -- living actors are bound before a quest guard is opened.
  world.eachCellObject(cell, function(actor)
    if matches(watch, actor) then
      if world.objectIsDead(actor) then
        watch.ignored[actor.id] = true
      else
        observe(watch, actor)
      end
    end
  end)
  watches[#watches + 1] = watch
  return watch
end

function M.observeActorActive(actor)
  for i = 1, #watches do observe(watches[i], actor) end
end

function M.updateActorObservations()
  for i = 1, #watches do
    local watch = watches[i]
    for id, actor in pairs(watch.actors) do
      if watch.deaths[id] then
        watch.actors[id] = nil
      elseif world.objectIsDead(actor) then
        watch.deaths[id] = true
        watch.actors[id] = nil
      end
    end
  end
end

function M.actorDeathObserved(watch)
  return next(watch.deaths)
end

function M.resetActorObservations()
  watches = {}
end

return M
