local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')
local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')

local M = {
  CELL = C.VASSAMSI_GROTTO,
  SOURCE_RECORD = 'flora_bc_fern_01',
  OUTPUT_MODEL = 'meshes/f/flora_heather_01.nif',
  ITEM_RECORD = 'ingred_bc_spore_pod',
  ITEM_COUNT = 3,
  EXTRA_RECORD = 'gold_001',
  EXTRA_COUNT = 37,
  POSITION = {x = -2050, y = 3800, z = -32},
  TOGGLE = 'respawning_container_replacement',
}

local function containerAtPosition(obj)
  return H.objectIsInstance(types.Container, obj)
    and H.positionNear(obj.position, M.POSITION, 8)
end

function M.source(cell)
  return H.findFirstObject(cell, function(obj)
    return containerAtPosition(obj) and H.objectRecordId(obj) == M.SOURCE_RECORD
  end)
end

function M.outputs(cell)
  local outputs = {}
  H.eachCellObject(cell, function(obj)
    if containerAtPosition(obj) and H.objectRecordId(obj) ~= M.SOURCE_RECORD then
      local record = types.Container.record(obj)
      if tostring(record.model):lower():gsub('\\', '/') == M.OUTPUT_MODEL then
        outputs[#outputs + 1] = obj
      end
    end
  end)
  return outputs
end

function M.output(cell)
  return M.outputs(cell)[1]
end

function M.teleport()
  H.teleportInterior(M.CELL, C.VASSAMSI_GROTTO_SAFE_POSITION,
    'respawning plant native destination cell')
  return H.requireCurrentInterior(M.CELL)
end

local function inventory(ref)
  local result = assert(H.containerInventory(ref), 'respawning plant inventory unavailable')
  if not result:isResolved() then result:resolve() end
  H.waitUntil(function() return result:isResolved() end, C.LONG_TIMEOUT_FRAMES,
    'respawning plant inventory resolved')
  return result
end

local function harvest(ref, count)
  local player = H.player()
  local before = H.countInventoryRecord(player, M.ITEM_RECORD)
  local items = inventory(ref):findAll(M.ITEM_RECORD)
  H.expect(H.countContainerRecord(ref, M.ITEM_RECORD) == count,
    'respawning plant harvest did not start with its exact native inventory')
  for i = 1, #items do items[i]:moveInto(H.actorInventory(player)) end
  H.waitUntil(function()
    return H.countContainerRecord(ref, M.ITEM_RECORD) == 0
      and H.countInventoryRecord(player, M.ITEM_RECORD) == before + count
  end, C.LONG_TIMEOUT_FRAMES, 'respawning plant harvest reaches player inventory')
end

function M.expectIdentity(cell, state)
  local source, output = M.source(cell), M.output(cell)
  H.expect(source ~= nil and tostring(source.id) == state.sourceId,
    'respawning source native reference changed')
  H.expect(output ~= nil and tostring(output.id) == state.outputId,
    'respawning output was replaced by a different native reference')
  H.expect(#M.outputs(cell) == 1, 'respawning replacement has duplicate native outputs')
  H.expect(source.enabled == false and output.enabled ~= false,
    'respawning replacement visibility changed')
  return source, output
end

function M.logState(cell, label)
  local source, output = M.source(cell), M.output(cell)
  print(string.format(
    '[MOMCampaign][RESPAWN_STATE] label=%s sourceId=%s sourceEnabled=%s outputId=%s outputEnabled=%s sourceItems=%d outputItems=%d sourceGold=%d outputGold=%d outputs=%d',
    label, tostring(source and source.id), tostring(source and source.enabled),
    tostring(output and output.id), tostring(output and output.enabled),
    source and H.countContainerRecord(source, M.ITEM_RECORD) or -1,
    output and H.countContainerRecord(output, M.ITEM_RECORD) or -1,
    source and H.countContainerRecord(source, M.EXTRA_RECORD) or -1,
    output and H.countContainerRecord(output, M.EXTRA_RECORD) or -1,
    #M.outputs(cell)))
end

local function nativeRefill(state)
  -- A real interior change unloads the native destination. Advancing time in
  -- the loaded cell alone does not execute CellStore's regular-entry reset.
  H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
    'unload respawning replacement destination')
  H.waitFrames(20)
  local hours = core.getGMST('iMonthsToRespawn') * 30 * 24 + 1
  H.expect(hours > 1, 'native container respawn interval unavailable')
  local before = core.getGameTime()
  world.advanceTime(hours)
  H.waitUntil(function() return core.getGameTime() >= before + hours * 3600 - 1 end,
    C.LONG_TIMEOUT_FRAMES, 'native container respawn interval elapsed')
  H.waitForWeatherCatchup(hours)
  local cell = M.teleport()
  local source, output = M.expectIdentity(cell, state)
  inventory(source)
  inventory(output)
  H.waitUntil(function()
    return H.countContainerRecord(source, M.ITEM_RECORD) == M.ITEM_COUNT
      and H.countContainerRecord(output, M.ITEM_RECORD) == M.ITEM_COUNT
  end, C.LONG_TIMEOUT_FRAMES, 'same hidden source and visible output refill natively')
  M.logState(cell, 'native_refill')
  return cell, source, output
end

function M.prepareHarvestedReplacement()
  G.setToggle(M.TOGGLE, false)
  local cell = M.teleport()
  H.expect(M.source(cell) == nil and #M.outputs(cell) == 0,
    'respawning plant fixture is already present')
  local record = types.Container.records[M.SOURCE_RECORD]
  H.expect(record.isRespawning == true and (record.mwscript == nil or record.mwscript == ''),
    'respawning plant fixture must be a scriptless native respawning container')
  local created = world.createObject(M.SOURCE_RECORD)
  created:teleport(M.CELL, H.vector3From(M.POSITION))
  H.waitUntil(function() return M.source(cell) ~= nil end, C.LONG_TIMEOUT_FRAMES,
    'respawning source first native destination placement')
  local source = M.source(cell)
  local untouched = assert(H.containerInventory(source), 'untouched source inventory unavailable')
  H.expect(untouched:isResolved() == false,
    'untouched native source inventory was resolved before replacement')

  G.setToggle(M.TOGGLE, true)
  H.waitUntil(function()
    local output = M.output(cell)
    return source.enabled == false and output ~= nil and output.enabled ~= false
      and #M.outputs(cell) == 1
      and H.countContainerRecord(output, M.ITEM_RECORD) == M.ITEM_COUNT
  end, 1800, 'apply resolves untouched native source and transfers all ingredients')
  harvest(M.output(cell), M.ITEM_COUNT)
  G.setToggle(M.TOGGLE, false)
  H.waitUntil(function()
    return source.enabled ~= false and #M.outputs(cell) == 0
      and H.countContainerRecord(source, M.ITEM_RECORD) == 0
  end, 1800, 'untouched source replacement restores the harvested current inventory')

  G.setToggle(M.TOGGLE, true)
  H.waitUntil(function()
    local output = M.output(cell)
    return source.enabled == false and output ~= nil and output.enabled ~= false
      and #M.outputs(cell) == 1
      and H.countContainerRecord(output, M.ITEM_RECORD) == 0
  end, 1800, 'harvested respawning source creates an empty visible mesh clone')
  local output = M.output(cell)
  H.expect(types.Container.record(output).isRespawning == true,
    'generated mesh clone lost native respawning flag')
  local state = {sourceId = tostring(source.id), outputId = tostring(output.id)}
  M.logState(cell, 'harvested_apply')
  cell, source, output = nativeRefill(state)
  harvest(output, M.ITEM_COUNT)

  -- Deposit a real player-held stack after the native refill. Revert must
  -- preserve this current output inventory while discarding hidden refill.
  local player = H.player()
  state.playerGold = H.countInventoryRecord(player, M.EXTRA_RECORD)
  world.createObject(M.EXTRA_RECORD, M.EXTRA_COUNT):moveInto(H.actorInventory(player))
  H.waitUntil(function()
    return H.countInventoryRecord(player, M.EXTRA_RECORD) == state.playerGold + M.EXTRA_COUNT
  end, C.LONG_TIMEOUT_FRAMES, 'respawning fixture extra gold enters player inventory')
  local money = assert(H.actorInventory(player):find(M.EXTRA_RECORD), 'player gold stack unavailable')
  money:split(M.EXTRA_COUNT):moveInto(inventory(output))
  H.waitUntil(function()
    return H.countContainerRecord(output, M.EXTRA_RECORD) == M.EXTRA_COUNT
      and H.countInventoryRecord(player, M.EXTRA_RECORD) == state.playerGold
  end, C.LONG_TIMEOUT_FRAMES, 'player deposits extra gold into harvested output')
  state.playerItems = H.countInventoryRecord(player, M.ITEM_RECORD)
  M.expectHarvested(cell, state)
  return cell, state
end

function M.expectHarvested(cell, state)
  local source, output = M.expectIdentity(cell, state)
  H.expect(H.countContainerRecord(source, M.ITEM_RECORD) == M.ITEM_COUNT,
    'hidden source native refill is missing')
  H.expect(H.countContainerRecord(output, M.ITEM_RECORD) == 0,
    'harvested output regenerated ingredients')
  H.expect(H.countContainerRecord(output, M.EXTRA_RECORD) == M.EXTRA_COUNT,
    'output lost player-added gold')
  H.expect(H.countInventoryRecord(H.player(), M.ITEM_RECORD) == state.playerItems
      and H.countInventoryRecord(H.player(), M.EXTRA_RECORD) == state.playerGold,
    'player inventory changed after the output harvest and deposit')
  M.logState(cell, 'harvested_output')
end

function M.revert(cell, state)
  G.setToggle(M.TOGGLE, false)
  H.waitUntil(function()
    local source = M.source(cell)
    return source ~= nil and tostring(source.id) == state.sourceId
      and source.enabled ~= false and #M.outputs(cell) == 0
      and H.countContainerRecord(source, M.ITEM_RECORD) == 0
      and H.countContainerRecord(source, M.EXTRA_RECORD) == M.EXTRA_COUNT
  end, 1800, 'revert discards hidden refill and restores current output inventory')
  H.waitFrames(20)
  local source = M.source(cell)
  H.expect(H.countContainerRecord(source, M.ITEM_RECORD) == 0
      and H.countContainerRecord(source, M.EXTRA_RECORD) == M.EXTRA_COUNT
      and #M.outputs(cell) == 0,
    'respawning revert did not retain one harvested source with added gold')
  H.expect(H.countInventoryRecord(H.player(), M.ITEM_RECORD) == state.playerItems
      and H.countInventoryRecord(H.player(), M.EXTRA_RECORD) == state.playerGold,
    'respawning revert duplicated or removed player inventory')
  M.logState(cell, 'reverted')
end

function M.reactivate(cell, state)
  local source = M.source(cell)
  H.expect(source ~= nil and tostring(source.id) == state.sourceId,
    'respawning reactivation lost the original native source')
  local previousOutputId = state.outputId
  G.setToggle(M.TOGGLE, true)
  H.waitUntil(function()
    local output = M.output(cell)
    return source.enabled == false and output ~= nil and output.enabled ~= false
      and #M.outputs(cell) == 1
      and H.countContainerRecord(source, M.ITEM_RECORD) == 0
      and H.countContainerRecord(source, M.EXTRA_RECORD) == 0
      and H.countContainerRecord(output, M.ITEM_RECORD) == 0
      and H.countContainerRecord(output, M.EXTRA_RECORD) == M.EXTRA_COUNT
  end, 1800, 'reactivation transfers harvested current inventory and player gold')
  state.outputId = tostring(M.output(cell).id)
  H.expect(state.outputId ~= previousOutputId,
    'respawning reactivation retained a removed output reference')
  M.expectIdentity(cell, state)
  H.expect(H.countInventoryRecord(H.player(), M.ITEM_RECORD) == state.playerItems
      and H.countInventoryRecord(H.player(), M.EXTRA_RECORD) == state.playerGold,
    'respawning reactivation changed player inventory')
  M.logState(cell, 'reactivated')
  M.revert(cell, state)
end

return M
