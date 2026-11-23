-- Clean action runtime for modify_inventory (add, ensure, remove, replace,
-- equip, unequip). Stores compact plain-table receipts directly in op.token
-- without any bespoke 20-table relational family database.
local M = {}

local constants = require('scripts.mom.constants')
local plain_data = require('scripts.mom.contracts.plain_data')
local ref_position = require('scripts.mom.domain.ref.position')
local selection_matcher = require('scripts.mom.runtime.selection_matcher')
local strings = require('scripts.mom.common.strings')

local EQUIP_SCRIPT = 'scripts/mom/local/equip.lua'
local MAX_AUTO_EQUIP_ATTEMPTS = 8
local lower = strings.lowerString

local function clone(value)
  if value == nil then return nil end
  return plain_data.cloneValidated(value)
end

local function groupMatchesTarget(group, facts, authoredRecordId)
  local matchId = lower(authoredRecordId or facts.recordId)
  if group.sourceRecordId ~= nil and lower(group.sourceRecordId) ~= matchId then
    return false
  end
  if group.inferredType ~= nil and group.inferredType ~= facts.typeName then
    return false
  end
  if group.sourcePosition ~= nil then
    local originPos = facts.origin and facts.origin.position or facts.position
    if not ref_position.positionsEqual(group.sourcePosition, originPos) then
      return false
    end
  end
  if type(group.filters) == 'table' and #group.filters > 0 then
    local checkFacts = facts
    if matchId ~= facts.recordId then
      checkFacts = {}
      for k, v in pairs(facts) do checkFacts[k] = v end
      checkFacts.recordId = matchId
    end
    local ok = selection_matcher.matchesPredicates(group.filters, checkFacts)
    if ok ~= true then return false end
  end
  return true
end

local function effectiveOpsForTarget(program, facts, authoredRecordId)
  local ops = {}
  for i = 1, #(program.itemOps or {}) do
    ops[#ops + 1] = program.itemOps[i]
  end
  for i = 1, #(program.ownerGroups or {}) do
    local group = program.ownerGroups[i]
    if groupMatchesTarget(group, facts, authoredRecordId) then
      for j = 1, #(group.objects or {}) do
        ops[#ops + 1] = group.objects[j]
      end
    end
  end
  return ops
end

local function isEquipped(equipMap, recordId)
  for _, recId in pairs(equipMap or {}) do
    if recId == recordId then return true end
  end
  return false
end

local function slotsWithRecord(equipMap, recordId)
  local slots = {}
  for slot, recId in pairs(equipMap or {}) do
    if recId == recordId then slots[#slots + 1] = slot end
  end
  table.sort(slots)
  return slots
end

local function countRecord(invOps, inv, recordId)
  local stacks, err = invOps.listItems(inv, recordId)
  if stacks == nil then return nil, err end
  local total = 0
  for i = 1, #stacks do total = total + stacks[i].count end
  return total, nil
end

local function sendLocalEquip(target, changes, phase, extraPending, ctx)
  local reqId, err = ctx.localBroker.send(
    ctx.opId,
    target,
    EQUIP_SCRIPT,
    constants.events.equipItem,
    {changes = changes},
    {frame = ctx.frame}
  )
  if reqId == nil then
    return {status = 'failed', changedClaims = extraPending.changedClaims or {}, message = tostring(err)}
  end
  local pending = {
    phase = phase,
    changes = changes,
    autoEquip = extraPending.autoEquip,
    changedClaims = extraPending.changedClaims or {'ref.inventory'},
    nextFrame = ctx.frame + 1,
    awaitingCompletion = true,
  }
  return {status = 'pending', changedClaims = pending.changedClaims, pending = pending}
end

local function triggerAutoEquip(target, inv, remainingItems, changedClaims, attempts, ctx)
  local currentEquip, eqErr = ctx.inventoryOps.getEquipment(target)
  if currentEquip == nil then
    return {status = 'failed', changedClaims = changedClaims, message = tostring(eqErr)}
  end
  local stillNeeded = {}
  for i = 1, #remainingItems do
    local recId = remainingItems[i]
    if not isEquipped(currentEquip, recId) then
      stillNeeded[#stillNeeded + 1] = recId
    end
  end
  if #stillNeeded == 0 then
    return {status = 'applied', changedClaims = changedClaims}
  end
  if attempts > MAX_AUTO_EQUIP_ATTEMPTS then
    -- Item may be un-equippable by this actor (e.g. beast race boots/helm); do not deadlock.
    return {status = #changedClaims > 0 and 'applied' or 'noop', changedClaims = changedClaims}
  end
  for i = 1, #stillNeeded do
    local ok, err = ctx.inventoryOps.autoEquip(target, inv, stillNeeded[i], ctx.opId)
    if not ok then
      -- moveInto() commits at end-of-tick in OpenMW; retry on next frame until visible.
      if attempts < MAX_AUTO_EQUIP_ATTEMPTS and tostring(err):find('inventory item unavailable', 1, true) then
        return {
          status = 'pending',
          changedClaims = changedClaims,
          pending = {
            phase = 'await-auto-equip',
            autoEquip = stillNeeded,
            attempts = attempts + 1,
            changedClaims = changedClaims,
            nextFrame = ctx.frame + 1,
          },
        }
      end
      return {status = 'failed', changedClaims = changedClaims, message = tostring(err)}
    end
  end
  return {
    status = 'pending',
    changedClaims = changedClaims,
    pending = {
      phase = 'await-auto-equip',
      autoEquip = stillNeeded,
      attempts = attempts + 1,
      changedClaims = changedClaims,
      nextFrame = ctx.frame + 2,
    },
  }
end

function M.matchesTarget(program, _target, facts, ctx)
  local ops = effectiveOpsForTarget(program, facts, ctx and ctx.authoredRecordId)
  return #ops > 0
end

function M.capture(program, target, ctx)
  local ops = effectiveOpsForTarget(program, ctx.targetFacts, ctx.authoredRecordId)
  if #ops == 0 then return {noop = true}, nil end
  local inv, isActor, invErr = ctx.inventoryOps.getInventory(target)
  if inv == nil then return nil, invErr end
  local baselineEquipment = nil
  if isActor then
    local eq, eqErr = ctx.inventoryOps.getEquipment(target)
    if eq == nil then return nil, eqErr end
    -- Store with string keys for plain-data JSON/canonical safety.
    baselineEquipment = {}
    for slot, recId in pairs(eq) do
      baselineEquipment[tostring(slot)] = recId
    end
  end
  return {
    ops = clone(ops),
    isActor = isActor,
    baselineEquipment = baselineEquipment,
    added = {},
    removed = {},
    equipmentChanged = false,
  }, nil
end

function M.prepareTransition(nextProgram, prevToken, target, ctx)
  local nextToken, err = M.capture(nextProgram, target, ctx)
  if nextToken == nil then return nil, err end
  if prevToken and prevToken.baselineEquipment ~= nil and nextToken.isActor then
    nextToken.baselineEquipment = clone(prevToken.baselineEquipment)
  end
  return nextToken, nil
end

function M.apply(_program, target, token, ctx)
  if token == nil or token.noop or #(token.ops or {}) == 0 then
    return {status = 'noop', changedClaims = {}}
  end
  local invOps = ctx.inventoryOps
  local inv, isActor, invErr = invOps.getInventory(target)
  if inv == nil then return {status = 'failed', changedClaims = {}, message = tostring(invErr)} end
  local okRes, resErr, resolvedChanged = invOps.ensureResolved(inv)
  if not okRes then return {status = 'failed', changedClaims = {}, message = tostring(resErr)} end

  local changedSet = {}
  if resolvedChanged then changedSet['ref.inventory'] = true end
  local function mark(c) changedSet[c] = true end
  local function claimList()
    local out = {}
    for c in pairs(changedSet) do out[#out + 1] = c end
    table.sort(out)
    return out
  end

  local currentEquip = nil
  if isActor then
    local eqErr
    currentEquip, eqErr = invOps.getEquipment(target)
    if currentEquip == nil then
      return {status = 'failed', changedClaims = claimList(), message = tostring(eqErr)}
    end
  end

  local added = {}
  local removed = {}
  local unequipChanges = {}
  local autoEquipList = {}
  local autoEquipSeen = {}
  local function queueAutoEquip(recId)
    if isActor and not autoEquipSeen[recId] then
      autoEquipSeen[recId] = true
      autoEquipList[#autoEquipList + 1] = recId
    end
  end

  for i = 1, #token.ops do
    local entry = token.ops[i]
    local op = entry.op
    if op == 'remove' then
      local rem, err = invOps.removeItems(inv, entry.sourceRecordId, entry.limit)
      if rem == nil then return {status = 'failed', changedClaims = claimList(), message = tostring(err)} end
      for j = 1, #rem do
        removed[#removed + 1] = rem[j]
        mark('ref.inventory')
      end
      if isActor and #rem > 0 and isEquipped(currentEquip, entry.sourceRecordId) then
        token.equipmentChanged = true
      end
    elseif op == 'replace' then
      local wasEquipped = isActor and isEquipped(currentEquip, entry.sourceRecordId)
      local rem, err = invOps.removeItems(inv, entry.sourceRecordId, nil)
      if rem == nil then return {status = 'failed', changedClaims = claimList(), message = tostring(err)} end
      local totalReplaced = 0
      for j = 1, #rem do
        removed[#removed + 1] = rem[j]
        totalReplaced = totalReplaced + rem[j].count
        mark('ref.inventory')
      end
      if totalReplaced > 0 then
        local receipt, addErr = invOps.addItems(inv, entry.targetRecordId, totalReplaced)
        if receipt == nil then return {status = 'failed', changedClaims = claimList(), message = tostring(addErr)} end
        added[#added + 1] = receipt
        mark('ref.inventory')
        if isActor and (entry.equip == true or wasEquipped) then
          token.equipmentChanged = true
          queueAutoEquip(entry.targetRecordId)
        end
      end
    elseif op == 'add' then
      local receipt, addErr = invOps.addItems(inv, entry.sourceRecordId, entry.count)
      if receipt == nil then return {status = 'failed', changedClaims = claimList(), message = tostring(addErr)} end
      added[#added + 1] = receipt
      mark('ref.inventory')
      if isActor and entry.equip == true then
        token.equipmentChanged = true
        queueAutoEquip(entry.sourceRecordId)
      end
    elseif op == 'ensure' then
      local existingCount, cntErr = countRecord(invOps, inv, entry.sourceRecordId)
      if existingCount == nil then return {status = 'failed', changedClaims = claimList(), message = tostring(cntErr)} end
      if existingCount < entry.count then
        local deficit = entry.count - existingCount
        local receipt, addErr = invOps.addItems(inv, entry.sourceRecordId, deficit)
        if receipt == nil then return {status = 'failed', changedClaims = claimList(), message = tostring(addErr)} end
        added[#added + 1] = receipt
        mark('ref.inventory')
      end
      if isActor and entry.equip == true and not isEquipped(currentEquip, entry.sourceRecordId) then
        token.equipmentChanged = true
        queueAutoEquip(entry.sourceRecordId)
      end
    elseif op == 'unequip' then
      if isActor then
        local slots = slotsWithRecord(currentEquip, entry.sourceRecordId)
        for j = 1, #slots do
          unequipChanges[#unequipChanges + 1] = {slot = slots[j], recordId = nil}
          token.equipmentChanged = true
          mark('ref.inventory')
        end
      end
    elseif op == 'equip' then
      if isActor and not isEquipped(currentEquip, entry.sourceRecordId) then
        local count, cntErr = countRecord(invOps, inv, entry.sourceRecordId)
        if count == nil then return {status = 'failed', changedClaims = claimList(), message = tostring(cntErr)} end
        if count > 0 then
          token.equipmentChanged = true
          mark('ref.inventory')
          queueAutoEquip(entry.sourceRecordId)
        end
      end
    end
  end

  token.added = added
  token.removed = removed
  local claims = claimList()

  if #unequipChanges > 0 then
    return sendLocalEquip(target, unequipChanges, 'apply-local-equip', {
      autoEquip = #autoEquipList > 0 and autoEquipList or nil,
      changedClaims = claims,
    }, ctx)
  end
  if #autoEquipList > 0 then
    if #added > 0 then
      -- moveInto() commits at end-of-tick; dispatch UseItem on frame + 1.
      return {
        status = 'pending',
        changedClaims = claims,
        pending = {
          phase = 'await-auto-equip',
          autoEquip = autoEquipList,
          attempts = 1,
          changedClaims = claims,
          nextFrame = ctx.frame + 1,
        },
      }
    end
    return triggerAutoEquip(target, inv, autoEquipList, claims, 1, ctx)
  end
  return {
    status = #claims > 0 and 'applied' or 'noop',
    changedClaims = claims,
  }
end

function M.revert(token, target, ctx)
  if token == nil or token.noop then
    return {status = 'noop', changedClaims = {}}
  end
  local invOps = ctx.inventoryOps
  local inv, isActor, invErr = invOps.getInventory(target)
  if inv == nil then return {status = 'failed', changedClaims = {}, message = tostring(invErr)} end
  local okRes, resErr = invOps.ensureResolved(inv)
  if not okRes then return {status = 'failed', changedClaims = {}, message = tostring(resErr)} end

  local changed = false
  -- 1. Remove items MOM added (matching exact receipt metadata so pre-existing
  --    unique/custom-data items are preserved!).
  for i = #(token.added or {}), 1, -1 do
    local receipt = token.added[i]
    local rem, remErr = invOps.removeItems(inv, receipt.recordId, receipt.count, receipt.variantKey)
    if rem == nil then return {status = 'failed', changedClaims = changed and {'ref.inventory'} or {}, message = tostring(remErr)} end
    if #rem > 0 then changed = true end
  end

  -- 2. Re-add items MOM removed or replaced with their exact captured ItemData.
  for i = #(token.removed or {}), 1, -1 do
    local receipt = token.removed[i]
    local added, addErr = invOps.addItems(inv, receipt.recordId, receipt.count, receipt.data)
    if added == nil then return {status = 'failed', changedClaims = changed and {'ref.inventory'} or {}, message = tostring(addErr)} end
    changed = true
  end

  -- 3. Restore actor baseline equipment if equipment was modified.
  if isActor and token.equipmentChanged and type(token.baselineEquipment) == 'table' then
    local currentEquip, eqErr = invOps.getEquipment(target)
    if currentEquip == nil then
      return {status = 'failed', changedClaims = changed and {'ref.inventory'} or {}, message = tostring(eqErr)}
    end
    local restoreChanges = {}
    local seenSlots = {}
    for slotKey, recId in pairs(token.baselineEquipment) do
      local slot = tonumber(slotKey)
      if slot ~= nil then
        seenSlots[slot] = true
        if currentEquip[slot] ~= recId then
          restoreChanges[#restoreChanges + 1] = {slot = slot, recordId = recId}
        end
      end
    end
    for slot in pairs(currentEquip) do
      if not seenSlots[slot] then
        restoreChanges[#restoreChanges + 1] = {slot = slot, recordId = nil}
      end
    end
    table.sort(restoreChanges, function(a, b) return a.slot < b.slot end)
    if #restoreChanges > 0 then
      return sendLocalEquip(target, restoreChanges, 'revert-local-equip', {
        changedClaims = {'ref.inventory'},
      }, ctx)
    end
  end

  return {
    status = changed and 'applied' or 'noop',
    changedClaims = changed and {'ref.inventory'} or {},
  }
end

function M.complete(pending, ack, target, ctx)
  local claims = pending.changedClaims or {'ref.inventory'}
  if type(ack) == 'table' and ack.ok == true then
    if pending.phase == 'apply-local-equip' and type(pending.autoEquip) == 'table' and #pending.autoEquip > 0 then
      local inv, _, invErr = ctx.inventoryOps.getInventory(target)
      if inv == nil then return {status = 'failed', changedClaims = claims, message = tostring(invErr)} end
      return triggerAutoEquip(target, inv, pending.autoEquip, claims, 1, ctx)
    end
    return {status = 'applied', changedClaims = claims}
  end
  if type(ack) == 'table' and ack.expired == true and type(pending.changes) == 'table' then
    return sendLocalEquip(target, pending.changes, pending.phase, pending, ctx)
  end
  return {
    status = 'failed',
    changedClaims = claims,
    message = tostring(ack and ack.error or 'modify_inventory local equip failed'),
  }
end

function M.advance(pending, target, ctx)
  local claims = pending.changedClaims or {'ref.inventory'}
  if pending.phase == 'await-auto-equip' then
    local inv, _, invErr = ctx.inventoryOps.getInventory(target)
    if inv == nil then return {status = 'failed', changedClaims = claims, message = tostring(invErr)} end
    return triggerAutoEquip(target, inv, pending.autoEquip or {}, claims, pending.attempts or 1, ctx)
  end
  if (pending.phase == 'apply-local-equip' or pending.phase == 'revert-local-equip')
      and type(pending.changes) == 'table' then
    return sendLocalEquip(target, pending.changes, pending.phase, pending, ctx)
  end
  return {status = 'applied', changedClaims = claims}
end

return M
