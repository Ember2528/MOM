-- Single unified OpenMW inventory, container transfer, item-data, and
-- equipment adapter (replaces both inventory_port.lua and container_inventory.lua).
local M = {}

local canonical = require('scripts.mom.contracts.canonical')
local openmw_api = require('scripts.mom.openmw.api')
local strings = require('scripts.mom.common.strings')

local call = openmw_api.call
local property = openmw_api.property
local nonEmpty = strings.isNonEmpty
local lower = strings.lowerString

local ITEM_DATA_FIELDS = {'condition', 'enchantmentCharge', 'soul'}

function M.variantKey(data, restocking)
  return canonical.assertHash({
    data = data or {},
    restocking = restocking == true,
  })
end

function M.new(deps)
  deps = deps or {}
  local world = openmw_api.dependency(deps, 'world', 'openmw.world')
  local types = openmw_api.dependency(deps, 'types', 'openmw.types')
  local core = openmw_api.dependency(deps, 'core', 'openmw.core')

  local ops = {}

  function ops.isActor(target)
    local ok, err = call(types.Actor.objectIsInstance, target)
    if ok == nil then return nil, err end
    return ok == true, nil
  end

  function ops.getInventory(target)
    local actor, actorErr = ops.isActor(target)
    if actor == nil then return nil, nil, actorErr end
    if actor then
      local inv, err = call(types.Actor.inventory, target)
      if inv == nil then return nil, nil, err or 'actor inventory unavailable' end
      return inv, true, nil
    end
    local isContainer, cErr = call(types.Container.objectIsInstance, target)
    if isContainer == nil then return nil, nil, cErr end
    if isContainer ~= true then
      return nil, nil, 'inventory target is not an actor or container'
    end
    local getter = types.Container.content or types.Container.inventory
    local inv, err = call(getter, target)
    if inv == nil then return nil, nil, err or 'container inventory unavailable' end
    return inv, false, nil
  end

  function ops.isResolved(inventory)
    if type(inventory.isResolved) ~= 'function' then return true, nil end
    local res, err = call(inventory.isResolved, inventory)
    if type(res) ~= 'boolean' then return nil, err or 'inventory resolution state invalid' end
    return res, nil
  end

  function ops.ensureResolved(inventory)
    local res, err = ops.isResolved(inventory)
    if res == nil then return nil, err, false end
    if res then return true, nil, false end
    if type(inventory.resolve) ~= 'function' then
      return nil, 'inventory resolve API is unavailable', false
    end
    local ok, resolveErr = pcall(inventory.resolve, inventory)
    if not ok then return nil, tostring(resolveErr), false end
    local after, afterErr = ops.isResolved(inventory)
    if after ~= true then
      return nil, afterErr or 'inventory did not resolve', true
    end
    return true, nil, true
  end

  function ops.readItemData(item)
    local data, err = call(types.Item.itemData, item)
    if data == nil then return nil, err end
    local out = {}
    for i = 1, #ITEM_DATA_FIELDS do
      local field = ITEM_DATA_FIELDS[i]
      local value, fErr = property(data, field)
      if fErr ~= nil then return nil, fErr end
      if value ~= nil then out[field] = value end
    end
    return out, nil
  end

  function ops.applyItemData(item, data)
    if type(data) ~= 'table' or next(data) == nil then return true, nil end
    local target, err = call(types.Item.itemData, item)
    if target == nil then return nil, err end
    for i = 1, #ITEM_DATA_FIELDS do
      local field = ITEM_DATA_FIELDS[i]
      if data[field] ~= nil then
        local ok, fErr = pcall(function() target[field] = data[field] end)
        if not ok then return nil, tostring(fErr) end
      end
    end
    return true, nil
  end

  function ops.isRestocking(item)
    local val, err = call(types.Item.isRestocking, item)
    if val == nil then return nil, err end
    return val == true, nil
  end

  function ops.listItems(inventory, recordId)
    local raw, err
    if recordId ~= nil then
      raw, err = call(inventory.findAll, inventory, recordId)
    else
      raw, err = call(inventory.getAll, inventory)
    end
    if raw == nil then return nil, err or 'inventory list failed' end
    local out = {}
    for i = 1, #raw do
      local item = raw[i]
      local recId = lower(property(item, 'recordId'))
      local count = tonumber(property(item, 'count')) or 0
      local data, dataErr = ops.readItemData(item)
      if data == nil then return nil, dataErr end
      local restocking, restErr = ops.isRestocking(item)
      if restocking == nil then return nil, restErr end
      if count > 0 and recId ~= nil then
        out[#out + 1] = {
          item = item,
          id = tostring(property(item, 'id') or ''),
          recordId = recId,
          count = count,
          data = data,
          restocking = restocking,
          variantKey = M.variantKey(data, restocking),
        }
      end
    end
    return out, nil
  end

  -- Creates `count` items with optional ItemData and moves them into `inventory`.
  -- Returns exact created receipt `{recordId, count, data, variantKey}`.
  function ops.addItems(inventory, recordId, count, data)
    if type(count) ~= 'number' or count < 1 or count % 1 ~= 0 then
      return nil, 'invalid item add count'
    end
    local item, createErr = call(world.createObject, recordId, count)
    if item == nil then return nil, createErr or ('failed creating ' .. tostring(recordId)) end
    local okData, dataErr = ops.applyItemData(item, data)
    if not okData then
      pcall(item.remove, item)
      return nil, dataErr
    end
    local actualData, readErr = ops.readItemData(item)
    if actualData == nil then
      pcall(item.remove, item)
      return nil, readErr
    end
    local actualCount = tonumber(property(item, 'count')) or count
    local okMove, moveErr = pcall(item.moveInto, item, inventory)
    if not okMove then
      pcall(item.remove, item)
      return nil, tostring(moveErr)
    end
    return {
      recordId = lower(recordId),
      count = actualCount,
      data = actualData,
      variantKey = M.variantKey(actualData, false),
    }, nil
  end

  -- Removes up to `limit` (or all if nil) non-restocking stacks of `recordId`.
  -- If `onlyVariantKey` is given, only removes stacks matching that exact metadata.
  -- Returns array of removed stack receipts `{recordId, count, data, variantKey}`.
  function ops.removeItems(inventory, recordId, limit, onlyVariantKey)
    local stacks, err = ops.listItems(inventory, recordId)
    if stacks == nil then return nil, err end
    local remaining = limit or math.huge
    local removed = {}
    for i = 1, #stacks do
      if remaining <= 0 then break end
      local stack = stacks[i]
      if not stack.restocking and (onlyVariantKey == nil or stack.variantKey == onlyVariantKey) then
        local take = math.min(stack.count, remaining)
        if take > 0 then
          local ok, remErr = pcall(
            stack.item.remove,
            stack.item,
            take == stack.count and nil or take
          )
          if not ok then return nil, tostring(remErr) end
          removed[#removed + 1] = {
            recordId = stack.recordId,
            count = take,
            data = stack.data,
            variantKey = stack.variantKey,
          }
          remaining = remaining - take
        end
      end
    end
    return removed, nil
  end

  -- Synchronous container inventory clear (removes all items in `inventory`).
  function ops.clearInventory(inventory, protectRestocking)
    local stacks, err = ops.listItems(inventory, nil)
    if stacks == nil then return nil, err, false end
    if protectRestocking then
      for i = 1, #stacks do
        if stacks[i].restocking then
          return nil, 'restocking container items cannot be removed', false
        end
      end
    end
    local changed = false
    for i = 1, #stacks do
      local ok, remErr = pcall(stacks[i].item.remove, stacks[i].item)
      if not ok then return nil, tostring(remErr), changed end
      changed = true
    end
    return true, nil, changed
  end

  -- Synchronous container inventory move (moves every stack from sourceInv to destInv).
  function ops.moveAllItems(sourceInv, destInv, protectRestocking)
    local stacks, err = ops.listItems(sourceInv, nil)
    if stacks == nil then return nil, err, false end
    if protectRestocking then
      for i = 1, #stacks do
        if stacks[i].restocking then
          return nil, 'restocking container items cannot be transferred', false
        end
      end
    end
    local changed = false
    for i = 1, #stacks do
      local ok, moveErr = pcall(stacks[i].item.moveInto, stacks[i].item, destInv)
      if not ok then return nil, tostring(moveErr), changed end
      changed = true
    end
    return true, nil, changed
  end

  function ops.getEquipment(actor)
    local raw, err = call(types.Actor.getEquipment, actor)
    if raw == nil then return nil, err or 'equipment unavailable' end
    local out = {}
    for slot, item in pairs(raw) do
      local numeric = tonumber(slot)
      local recId = lower(property(item, 'recordId'))
      if numeric ~= nil and recId ~= nil then
        out[numeric] = recId
      end
    end
    return out, nil
  end

  function ops.autoEquip(actor, inventory, recordId, commandId)
    local item, err = call(inventory.find, inventory, recordId)
    if item == nil then return nil, err or ('inventory item unavailable: ' .. tostring(recordId)) end
    local ok, sendErr = pcall(core.sendGlobalEvent, 'UseItem', {
      object = item,
      actor = actor,
      force = true,
      commandId = commandId,
      requestId = commandId,
    })
    if not ok then return nil, tostring(sendErr) end
    return true, nil
  end

  return ops
end

return M
