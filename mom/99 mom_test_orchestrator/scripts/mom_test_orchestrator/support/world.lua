-- Player, cell, object, and inventory queries against OpenMW.
local C = require('scripts.mom_test_orchestrator.constants')
local values = require('scripts.mom_test_orchestrator.support.values')
local I = require('openmw.interfaces')
local types = require('openmw.types')
local world = require('openmw.world')

local M = {}

function M.player()
  return world.players and world.players[1] or nil
end

function M.playerReady()
  local actor = M.player()
  return actor ~= nil and actor.cell ~= nil
end

function M.currentCell()
  local actor = M.player()
  return actor and actor.cell or nil
end

function M.momInterface()
  return I and I.MOM or nil
end

-- Object lookup helpers

function M.lookupFormIdFromRefId(refId)
  local value = refId and tostring(refId) or nil
  if not value or value == '' then return nil end
  if value:find(':', 1, true) then
    return value
  end
  if value:sub(1, 1) == '#' then
    return 'Esm3ExteriorCell:' .. value:sub(2):gsub(' ', ':', 1)
  end
  return 'FormId:' .. value
end

function M.getObjectByRefId(refId)
  local lookupFormId = M.lookupFormIdFromRefId(refId)
  if not lookupFormId or not (world and world.getObjectByFormId) then return nil end
  local ok, obj = pcall(world.getObjectByFormId, lookupFormId)
  if not ok or not obj then return nil end
  if obj.isValid and not obj:isValid() then return nil end
  return obj
end

-- Cell object iteration

function M.eachCellObject(cell, fn)
  local all = cell and cell.getAll and cell:getAll() or nil
  for i = 1, #((all) or {}) do
    local obj = all[i]
    if obj and obj.isValid then
      local ok, valid = pcall(obj.isValid, obj)
      if ok and valid and fn(obj) == false then return end
    end
  end
end

function M.findFirstObject(cell, predicate)
  local found = nil
  M.eachCellObject(cell, function(obj)
    if predicate(obj) then
      found = obj
      return false
    end
  end)
  return found
end

function M.findClosestObject(cell, predicate, targetPosition)
  local found = nil
  local bestDistance = nil
  M.eachCellObject(cell, function(obj)
    if predicate(obj) then
      local distance = values.distanceSquared(obj.position, targetPosition)
      if bestDistance == nil or distance < bestDistance then
        bestDistance = distance
        found = obj
      end
    end
  end)
  return found
end

function M.countObjects(cell, predicate)
  local count = 0
  M.eachCellObject(cell, function(obj)
    if predicate(obj) then
      count = count + 1
    end
  end)
  return count
end

-- Object property helpers

function M.objectRecordId(obj)
  return values.normalizeRecordId(obj and obj.recordId)
end

function M.objectMatchesRecordSet(obj, recordIds)
  local recordId = M.objectRecordId(obj)
  return recordId and recordIds and recordIds[recordId] == true or false
end

function M.objectIsInstance(typeApi, obj)
  if not (typeApi and typeApi.objectIsInstance and obj) then return false end
  local ok, result = pcall(typeApi.objectIsInstance, obj)
  return ok and result == true or false
end

function M.objectIsDead(obj)
  if not (obj and types.Actor and types.Actor.isDead) then return false end
  local ok, dead = pcall(types.Actor.isDead, obj)
  return ok and dead == true or false
end

function M.objectOwnerRecordId(obj)
  local owner = obj and obj.owner or nil
  if not owner then return nil end
  local ok, recordId = pcall(function()
    return owner.recordId
  end)
  return ok and values.normalizeRecordId(recordId) or nil
end

function M.objectOwnerFactionId(obj)
  local owner = obj and obj.owner or nil
  if not owner then return nil end
  local ok, factionId = pcall(function()
    return owner.factionId
  end)
  return ok and values.normalizeRecordId(factionId) or nil
end

function M.objectOwnerFactionRank(obj)
  local owner = obj and obj.owner or nil
  if not owner then return nil end
  local ok, rank = pcall(function()
    return owner.factionRank
  end)
  return ok and rank or nil
end

function M.sameStartingIdentity(obj, startingCellId, startingPosition, tolerance)
  local objStartingCellId = values.normalizeCellId(obj and obj.startingCell and obj.startingCell.id)
  if objStartingCellId ~= values.normalizeCellId(startingCellId) then
    return false
  end
  return values.positionNear(obj and obj.startingPosition, startingPosition, tolerance or 8)
end

-- Compound query helpers

function M.countEnabledRecords(cell, recordIds)
  return M.countObjects(cell, function(obj)
    return M.objectMatchesRecordSet(obj, recordIds) and obj.enabled ~= false
  end)
end

function M.countRecords(cell, recordIds)
  return M.countObjects(cell, function(obj)
    return M.objectMatchesRecordSet(obj, recordIds)
  end)
end

function M.recordSetDisabled(cell, recordIds)
  local found, enabled = false, false
  M.eachCellObject(cell, function(obj)
    if M.objectMatchesRecordSet(obj, recordIds) then
      found = true
      if obj.enabled ~= false then enabled = true; return false end
    end
  end)
  return found and not enabled
end

function M.countLivingRecords(cell, recordIds)
  return M.countObjects(cell, function(obj)
    return M.objectMatchesRecordSet(obj, recordIds) and not M.objectIsDead(obj)
  end)
end

function M.countRecordNearPosition(cell, recordId, targetPosition, tolerance)
  recordId = values.normalizeRecordId(recordId)
  return M.countObjects(cell, function(obj)
    return M.objectRecordId(obj) == recordId
      and values.positionNear(obj.position, targetPosition, tolerance or 96)
      and obj.enabled ~= false
  end)
end

-- One traversal checks every expected placement independently, so an extra
-- copy at one position cannot hide a missing copy at another.
function M.placementsMatch(cell, recordId, positions, expectedEach, tolerance)
  recordId = values.normalizeRecordId(recordId)
  local counts = {}
  M.eachCellObject(cell, function(obj)
    if M.objectRecordId(obj) == recordId and obj.enabled ~= false then
      for i, position in ipairs(positions) do
        if values.positionNear(obj.position, position, tolerance) then
          counts[i] = (counts[i] or 0) + 1
        end
      end
    end
  end)
  for i = 1, #positions do
    if (counts[i] or 0) ~= expectedEach then return false end
  end
  return true
end

function M.findRecordNearPosition(cell, recordId, targetPosition, tolerance)
  recordId = values.normalizeRecordId(recordId)
  return M.findClosestObject(cell, function(obj)
    return M.objectRecordId(obj) == recordId
      and values.positionNear(obj.position, targetPosition, tolerance or 96)
  end, targetPosition)
end

function M.recordNearPositionEnabled(cell, recordId, targetPosition, tolerance)
  return M.countRecordNearPosition(cell, recordId, targetPosition, tolerance) > 0
end

function M.recordNearPositionDisabled(cell, recordId, targetPosition, tolerance)
  local obj = M.findRecordNearPosition(cell, recordId, targetPosition, tolerance)
  return obj ~= nil and obj.enabled == false
end

function M.countChestAtTarget(cell, startingCellId, startingPosition, targetPosition, requireEnabled)
  return M.countObjects(cell, function(obj)
    return M.objectRecordId(obj) == C.CHEST_RECORD_ID
      and M.sameStartingIdentity(obj, startingCellId, startingPosition, 8)
      and values.positionNear(obj.position, targetPosition, 96)
      and (requireEnabled ~= true or obj.enabled ~= false)
  end)
end

function M.findChestAtTarget(cell, startingCellId, startingPosition, targetPosition)
  return M.findClosestObject(cell, function(obj)
    return M.objectRecordId(obj) == C.CHEST_RECORD_ID
      and M.sameStartingIdentity(obj, startingCellId, startingPosition, 8)
      and values.positionNear(obj.position, targetPosition, 96)
  end, targetPosition)
end

function M.findGuildChest(cell)
  return M.findFirstObject(cell, function(obj)
    local sourcePosition = obj and (obj.startingPosition or obj.position) or nil
    return M.objectRecordId(obj) == C.CHEST_RECORD_ID
      and sourcePosition ~= nil
      and values.positionNear(sourcePosition, C.GUILD_CHEST_SOURCE_POSITION, 8)
  end)
end

function M.guildChestEnabled(cell, startingCellId, startingPosition)
  local chest = M.findFirstObject(cell, function(obj)
    return M.objectRecordId(obj) == C.CHEST_RECORD_ID
      and M.sameStartingIdentity(obj, startingCellId, startingPosition, 8)
  end)
  return chest and chest.enabled ~= false or false
end

-- Inventory helpers

function M.actorInventory(ref)
  if not (M.objectIsInstance(types and types.Actor, ref) and types and types.Actor and types.Actor.inventory) then
    return nil
  end
  local ok, inventory = pcall(types.Actor.inventory, ref)
  return ok and inventory or nil
end

function M.countInventoryRecord(ref, recordId)
  local inventory = M.actorInventory(ref)
  if not (inventory and inventory.findAll) then return 0 end
  local ok, list = pcall(inventory.findAll, inventory, recordId)
  if not (ok and list) then return 0 end
  local total = 0
  for i = 1, #list do
    total = total + (list[i].count or 1)
  end
  return total
end

function M.isEquippedRecord(ref, recordId)
  if not (M.objectIsInstance(types and types.Actor, ref) and types and types.Actor and types.Actor.getEquipment) then
    return false
  end
  local targetId = values.normalizeRecordId(recordId)
  if not targetId then return false end
  local ok, equipment = pcall(types.Actor.getEquipment, ref)
  if not (ok and type(equipment) == 'table') then return false end
  for _, item in pairs(equipment) do
    if M.objectRecordId(item) == targetId then
      return true
    end
  end
  return false
end

function M.containerInventory(ref)
  if not (types and types.Container) then return nil end
  if types.Container.inventory then
    local ok, inv = pcall(types.Container.inventory, ref)
    if ok and inv then return inv end
  end
  if types.Container.content then
    local ok, content = pcall(types.Container.content, ref)
    if ok and content then return content end
  end
  return nil
end

function M.countContainerRecord(ref, recordId)
  local inventory = M.containerInventory(ref)
  if not (inventory and inventory.findAll) then return 0 end
  local ok, list = pcall(inventory.findAll, inventory, recordId)
  if not (ok and list) then return 0 end
  local total = 0
  for i = 1, #list do
    total = total + (list[i].count or 1)
  end
  return total
end

function M.addContainerRecord(ref, recordId, count)
  local inventory = assert(M.containerInventory(ref), 'Container inventory unavailable')
  local item = assert(world.createObject(recordId, count))
  local ok, err = pcall(item.moveInto, item, inventory)
  if not ok then error('Could not seed container inventory: ' .. tostring(err), 2) end
end

-- Coroutine waits

return M
