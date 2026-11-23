-- Clean OpenMW engine session factory composing the 2-layer openmw/* adapters.
local M = {}

local guard_reads = require('scripts.mom.openmw.guard_reads')
local inventory_ops = require('scripts.mom.openmw.inventory_ops')
local openmw_api = require('scripts.mom.openmw.api')
local placement_ops = require('scripts.mom.openmw.placement_ops')
local ref_ops = require('scripts.mom.openmw.ref_ops')
local world_adapter = require('scripts.mom.openmw.world')

local call = openmw_api.call
local property = openmw_api.property

function M.newFactory(deps)
  deps = deps or {}
  return {
    open = function(_self, opts)
      opts = opts or {}
      local types = openmw_api.dependency(deps, 'types', 'openmw.types')
      local worldApi = world_adapter.new(deps, opts)
      local refApi = ref_ops.new(deps, worldApi)
      local invApi = inventory_ops.new(deps)
      local placeApi = placement_ops.new(deps, refApi, invApi)
      local guardApi = guard_reads.new(deps, worldApi)

      local actorApi = {
        readLife = function(target)
          local actor = types and types.Actor
          if not openmw_api.isNamespace(actor) then
            return nil, 'Actor API is unavailable'
          end
          local isActor, isErr = call(actor.objectIsInstance, target)
          if isActor == nil then return nil, isErr end
          if isActor ~= true then
            return {isActor = false, alive = false, summoned = false}, nil
          end
          local dead, deadErr = call(actor.isDead, target)
          if type(dead) ~= 'boolean' then return nil, deadErr or 'Actor.isDead failed' end
          local summonedBy, sumErr = property(target, 'summonedBy')
          if sumErr ~= nil then return nil, sumErr end
          return {
            isActor = true,
            alive = not dead,
            summoned = summonedBy ~= nil,
          }, nil
        end,
      }

      -- Build external guard providers declared via guard.providerInterface.
      local providers = {}
      for guardId, interfaceName in pairs(opts.guardProviderInterfaces or {}) do
        providers[guardId] = {
          read = function(...)
            local iface, ifaceErr = guardApi.provider(interfaceName)
            if iface == nil then return nil, ifaceErr end
            local readFn, fnErr = property(iface, 'read')
            if type(readFn) ~= 'function' then
              return nil, fnErr or 'guard provider read is unavailable'
            end
            return call(readFn, ...)
          end,
        }
      end

      local guardCapabilities = {
        readTime = guardApi.readTime,
        readWeather = guardApi.readWeather,
        readQuestStage = guardApi.readQuestStage,
        provider = guardApi.provider,
        providers = providers,
      }

      local choicePort = {
        readRegionClimate = guardApi.readRegionClimate,
        resolveCell = function(id)
          local cell, err = worldApi.resolveCell(id)
          if cell == nil then return nil, err end
          return worldApi.describeCell(cell)
        end,
      }

      local session = {
        world = worldApi,
        refOps = refApi,
        inventoryOps = invApi,
        placementOps = placeApi,
        actorOps = actorApi,
        guardReads = guardApi,
        guardCapabilities = guardCapabilities,
        choicePort = choicePort,
      }

      function session:beginFrame(frame)
        worldApi.beginFrame(frame)
        refApi.beginFrame(frame)
        guardApi.beginFrame(frame)
      end

      function session:previsitCells(manifest, frame)
        local entries = {}
        local previsit = manifest and manifest.indexes and manifest.indexes.previsitCells or {}
        local keys = {}
        for routeKey in pairs(previsit) do keys[#keys + 1] = routeKey end
        table.sort(keys)
        for i = 1, #keys do
          local entry = worldApi.previsitRoute(keys[i], frame or 0)
          if entry ~= nil then entries[#entries + 1] = entry end
        end
        return entries
      end

      function session:syncObservedCells(frame)
        return worldApi.syncObservedCells(frame)
      end

      function session:observeObject(object, frame)
        if not worldApi.isValid(object) then return nil end
        local cell = property(object, 'cell')
        if cell == nil then return nil end
        return worldApi.observeCell(cell, frame, false)
      end

      function session:observeCell(cell, frame)
        return worldApi.observeCell(cell, frame, false)
      end

      function session:pollGuardEvents(frame, watchTime, watchWeather)
        return guardApi.poll(frame, watchTime, watchWeather)
      end

      function session:replaceQuestSnapshot(quests)
        return guardApi.replaceQuestSnapshot(quests)
      end

      function session:updateQuestStage(questId, stage)
        return guardApi.updateQuestStage(questId, stage)
      end

      function session:clear()
        worldApi.clear()
        refApi.clear()
        guardApi.clear()
        return true
      end

      return session, nil
    end,
  }
end

return M
