local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')
local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local M = {
  CELL = 'Ald-ruhn, Guild of Mages',
  POSITION = {x = 200, y = 100, z = 200},
  STATIC_POSITION = {x = 400, y = 100, z = 200},
  KEEP_POSITION = {x = 600, y = 100, z = 200},
  DECORATION_POSITION = {x = 800, y = 100, z = 200},
  DECORATION = 'furn_de_tapestry_02',
  PLANT = 'flora_bc_fern_01', ITEM = 'ingred_bc_spore_pod',
  PLANT_MODEL = 'meshes/f/flora_heather_01.nif',
  STATIC = 'furn_de_tapestry_04', STATIC_MODEL = 'meshes/f/furn_de_tapestry_03.nif',
  KEEP = 'furn_de_tapestry_01', GOLD = 'gold_001', COUNT = 3, GOLD_COUNT = 37,
}

local function model(ref)
  local kind = H.objectIsInstance(types.Container, ref) and types.Container or types.Static
  local record = kind.record(ref)
  local path = tostring(record and record.model or ''):lower():gsub('\\', '/')
  return path:match('^meshes/') and path or 'meshes/' .. path
end

local function near(cell, position, predicate)
  return H.findFirstObject(cell, function(ref)
    return H.positionNear(ref.position, position, 8) and predicate(ref)
  end)
end

local function describeNear(cell, position)
  local values = {}
  H.countObjects(cell, function(ref)
    if H.positionNear(ref.position, position, 8) then
      values[#values + 1] = string.format('%s (%s, enabled=%s, model=%s)',
        tostring(ref.id), H.objectRecordId(ref), tostring(ref.enabled), model(ref))
    end
    return false
  end)
  table.sort(values)
  return table.concat(values, '; ')
end

local function decorations(cell)
  local values = {}
  H.countObjects(cell, function(ref)
    if H.objectRecordId(ref) == M.DECORATION and ref.enabled ~= false
        and H.positionNear(ref.position, M.DECORATION_POSITION, 8) then
      values[#values + 1] = ref
    end
    return false
  end)
  table.sort(values, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return values
end

function M.source(cell)
  return near(cell, M.POSITION, function(ref) return H.objectRecordId(ref) == M.PLANT end)
end

function M.output(cell)
  return near(cell, M.POSITION, function(ref)
    return H.objectIsInstance(types.Container, ref) and H.objectRecordId(ref) ~= M.PLANT
      and model(ref) == M.PLANT_MODEL
  end)
end

local function inventory(ref)
  local value = assert(H.containerInventory(ref), 'VFR output inventory unavailable')
  if not value:isResolved() then value:resolve() end
  H.waitUntil(function() return value:isResolved() end, C.LONG_TIMEOUT_FRAMES, 'VFR container resolves')
  return value
end

function M.teleport()
  H.teleportInterior(M.CELL, {x = 0, y = 100, z = 300}, 'VFR native replacement cell')
  return H.requireCurrentInterior(M.CELL)
end

function M.verify(cell, state)
  local source, output = M.source(cell), M.output(cell)
  H.expect(source and tostring(source.id) == state.sourceId and source.enabled == false,
    'VFR hidden source identity or visibility changed')
  H.expect(output and tostring(output.id) == state.outputId and output.enabled ~= false,
    'VFR native output identity or visibility changed')
  H.expect(types.Container.record(output).isRespawning == true, 'VFR mesh clone lost native respawn')
  H.expect(H.countContainerRecord(output, M.ITEM) == 0
      and H.countContainerRecord(output, M.GOLD) == M.GOLD_COUNT,
    'VFR harvested current inventory did not retain player deposit')
  local original = near(cell, M.STATIC_POSITION, function(ref) return H.objectRecordId(ref) == M.STATIC end)
  local replacement = near(cell, M.STATIC_POSITION, function(ref)
    return H.objectIsInstance(types.Static, ref) and H.objectRecordId(ref) ~= M.STATIC and model(ref) == M.STATIC_MODEL
  end)
  H.expect(original and original.enabled == false and replacement and replacement.enabled ~= false
      and tostring(replacement.id) == state.staticOutputId,
    'VFR static clone or exact-source SSS priority was lost')
  H.expect(H.countObjects(cell, function(ref)
    return H.positionNear(ref.position, M.STATIC_POSITION, 8) and ref.enabled ~= false
      and H.objectRecordId(ref) ~= M.STATIC
  end) == 1, 'SSS and VFR produced concurrent visible replacements for one exact source')
  local kept = near(cell, M.KEEP_POSITION, function(ref) return H.objectRecordId(ref) == M.KEEP end)
  H.expect(kept and tostring(kept.id) == state.keepId and kept.enabled ~= false,
    'VFR exact-record KEEP source changed; expected ' .. state.keepId
      .. '; nearby references: ' .. describeNear(cell, M.KEEP_POSITION))
  local outputCount = H.countObjects(cell, function(ref)
    return H.positionNear(ref.position, M.POSITION, 8) and H.objectRecordId(ref) ~= M.PLANT
  end)
  H.expect(outputCount == 1, 'VFR native replacement duplicated its output')
  local placed = decorations(cell)
  H.expect(#placed == 2 and tostring(placed[1].id) == state.decorationAId
      and tostring(placed[2].id) == state.decorationBId
      and placed[1].scale == 1.25 and placed[2].scale == 1.25,
    'VFR coincident placement identity, multiplicity, or scale changed')
  H.expect(H.countInventoryRecord(H.player(), M.ITEM) == state.playerItems
      and H.countInventoryRecord(H.player(), M.GOLD) == state.playerGold,
    'VFR player inventory changed across observation or restart')
end

local function harvest(output)
  local playerInventory = H.actorInventory(H.player())
  local before = H.countInventoryRecord(H.player(), M.ITEM)
  H.expect(H.countContainerRecord(output, M.ITEM) == M.COUNT, 'VFR output did not start with native ingredients')
  local items = inventory(output):findAll(M.ITEM)
  for i = 1, #items do items[i]:moveInto(playerInventory) end
  H.waitUntil(function()
    return H.countContainerRecord(output, M.ITEM) == 0
      and H.countInventoryRecord(H.player(), M.ITEM) == before + M.COUNT
  end, C.LONG_TIMEOUT_FRAMES, 'VFR plant harvest reaches player')
end

function M.setup()
  -- This destination is not visited by the other harness scenarios. Create
  -- references before entering, so ordinary observed-cell discovery owns them.
  local source = world.createObject(M.PLANT)
  source:teleport(M.CELL, H.vector3From(M.POSITION))
  local original = world.createObject(M.STATIC)
  original:teleport(M.CELL, H.vector3From(M.STATIC_POSITION))
  local kept = world.createObject(M.KEEP)
  kept:teleport(M.CELL, H.vector3From(M.KEEP_POSITION))
  H.expect(model(original) == 'meshes/f/furn_de_tapestry_04.nif'
      and model(kept) == 'meshes/f/furn_de_tapestry_01.nif',
    'VFR fixture mesh selectors do not match their exact native source records')
  H.expect(H.containerInventory(source):isResolved() == false,
    'VFR untouched plant was resolved before discovery')
  local cell = M.teleport()
  local output, staticOutput, placed
  H.waitUntil(function()
    output = M.output(cell)
    staticOutput = near(cell, M.STATIC_POSITION, function(ref)
      return H.objectIsInstance(types.Static, ref) and H.objectRecordId(ref) ~= M.STATIC
        and ref.enabled ~= false and model(ref) == M.STATIC_MODEL
    end)
    placed = decorations(cell)
    return source.enabled == false and output and output.enabled ~= false
      and H.countContainerRecord(output, M.ITEM) == M.COUNT
      and original.enabled == false and staticOutput and #placed == 2
      and placed[1].scale == 1.25 and placed[2].scale == 1.25
  end, 2400, 'VFR native Static and Container replacement')
  local state = {sourceId = tostring(source.id), outputId = tostring(output.id),
    staticOutputId = tostring(staticOutput.id), keepId = tostring(kept.id),
    decorationAId = tostring(placed[1].id), decorationBId = tostring(placed[2].id)}
  harvest(output)
  H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION, 'unload VFR native respawn cell')
  H.waitFrames(20)
  local hours = core.getGMST('iMonthsToRespawn') * 30 * 24 + 1
  local before = core.getGameTime()
  world.advanceTime(hours)
  H.waitUntil(function() return core.getGameTime() >= before + hours * 3600 - 1 end,
    C.LONG_TIMEOUT_FRAMES, 'VFR native respawn interval elapsed')
  H.waitForWeatherCatchup(hours)
  cell = M.teleport()
  source, output = M.source(cell), M.output(cell)
  H.expect(source and tostring(source.id) == state.sourceId
      and output and tostring(output.id) == state.outputId,
    'native VFR respawn recreated a managed reference')
  inventory(output)
  H.waitUntil(function() return H.countContainerRecord(output, M.ITEM) == M.COUNT end,
    C.LONG_TIMEOUT_FRAMES, 'VFR output refills through native Container lifecycle')
  harvest(output)
  local player = H.player()
  state.playerGold = H.countInventoryRecord(player, M.GOLD)
  world.createObject(M.GOLD, M.GOLD_COUNT):moveInto(H.actorInventory(player))
  H.waitUntil(function() return H.countInventoryRecord(player, M.GOLD) == state.playerGold + M.GOLD_COUNT end,
    C.LONG_TIMEOUT_FRAMES, 'VFR player deposit fixture')
  H.actorInventory(player):find(M.GOLD):split(M.GOLD_COUNT):moveInto(inventory(output))
  H.waitUntil(function() return H.countContainerRecord(output, M.GOLD) == M.GOLD_COUNT
      and H.countInventoryRecord(player, M.GOLD) == state.playerGold end,
    C.LONG_TIMEOUT_FRAMES, 'VFR player deposit reaches harvested output')
  state.playerItems = H.countInventoryRecord(player, M.ITEM)
  M.verify(cell, state)
  return cell, state
end

return M
