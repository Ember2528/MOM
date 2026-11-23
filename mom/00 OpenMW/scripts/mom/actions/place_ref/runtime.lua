-- Clean synchronous action runtime for place_ref (place, attach, model variants,
-- appearance choices, Creature replacement, and synchronous Container transfers).
local M = {}

local container_transfer = require('scripts.mom.actions.place_ref.container_transfer')
local identity = require('scripts.mom.ledger.identity')
local model_path = require('scripts.mom.contracts.model_path')
local plain_data = require('scripts.mom.contracts.plain_data')
local ref_position = require('scripts.mom.domain.ref.position')
local selection_matcher = require('scripts.mom.runtime.selection_matcher')
local strings = require('scripts.mom.common.strings')
local type_capabilities = require('scripts.mom.actions.place_ref.type_capabilities')

local lower = strings.lowerString
local nonEmpty = strings.isNonEmpty

local function clone(value)
  if value == nil then return nil end
  return plain_data.cloneValidated(value)
end

local function normRotation(rot)
  if type(rot) ~= 'table' then return {yaw = 0, pitch = 0, roll = 0} end
  return {
    yaw = tonumber(rot.yaw) or 0,
    pitch = tonumber(rot.pitch) or 0,
    roll = tonumber(rot.roll) or 0,
  }
end

local function entryMatchesTarget(entry, program, target, facts, ctx)
  if program.inheritedAnchor == true and #(entry.filters or {}) == 0 then
    return true, nil
  end
  local matchRecordId = lower(ctx.authoredRecordId or facts.recordId)
  if entry.sourceKeyKind == 'inherited' then
    -- Inherited relative child binds directly to parent output.
  elseif entry.sourceKeyKind == 'model_path' then
    local expected = model_path.normalize(entry.sourceRecordId)
    local actual, err = ctx.world.recordModelForRef(target, facts.typeName)
    if actual == nil then return nil, err end
    if expected ~= actual then return false, nil end
  elseif entry.sourceKeyKind == nil or entry.sourceKeyKind == 'record_id' then
    if entry.sourceRecordId ~= nil and lower(entry.sourceRecordId) ~= matchRecordId then
      return false, nil
    end
  end
  if entry.inferredType ~= nil and entry.inferredType ~= facts.typeName then
    return false, nil
  end
  if entry.sourcePosition ~= nil then
    local originPos = facts.origin and facts.origin.position or facts.position
    if not ref_position.positionsEqual(entry.sourcePosition, originPos) then
      return false, nil
    end
  end
  if type(entry.filters) == 'table' and #entry.filters > 0 then
    local checkFacts = facts
    if matchRecordId ~= facts.recordId then
      checkFacts = {}
      for k, v in pairs(facts) do checkFacts[k] = v end
      checkFacts.recordId = matchRecordId
    end
    return selection_matcher.matchesPredicates(entry.filters, checkFacts)
  end
  return true, nil
end

local function prepareSlot(entry, program, target, current, facts, isTransition, ctx)
  if program.mode == 'absolute' then
    local destCell = target
    if nonEmpty(program.destinationCellKey) then
      local cellErr
      destCell, cellErr = ctx.world.resolveCell(program.destinationCellKey)
      if destCell == nil then return nil, cellErr end
    end
    local cellFacts, cellErr = ctx.world.describeCell(destCell)
    if cellFacts == nil then return nil, cellErr end
    return {
      slot = entry.slot,
      targetKind = entry.targetKind,
      targetValue = entry.targetValue,
      authoredRecordId = entry.targetValue,
      typeName = entry.targetType,
      cell = clone(cellFacts),
      position = {x = entry.position.x, y = entry.position.y, z = entry.position.z},
      rotation = normRotation(entry.rotation),
    }, nil
  end

  if current.enabled ~= true and not isTransition then return false, nil end
  local policy = type_capabilities.classify(facts.typeName)
  if policy.kind == 'unsupported' then
    return nil, 'place_ref source type ' .. tostring(facts.typeName) .. ' is unsupported: ' .. tostring(policy.reason)
  end
  if entry.inferredType ~= nil and entry.inferredType ~= facts.typeName then
    return false, nil
  end
  local sourceInfo, infoErr = ctx.placementOps.sourceRecordInfo(facts.typeName, target)
  if sourceInfo == nil then return nil, infoErr end
  if policy.requiresScriptless and nonEmpty(sourceInfo.mwscript) then
    return false, nil
  end
  if policy.kind == 'creature-model' then
    local eligible, eligErr = ctx.placementOps.creatureEligible(target)
    if eligible == nil then return nil, eligErr end
    if not eligible then return false, nil end
  end

  local matched, matchErr = entryMatchesTarget(entry, program, target, facts, ctx)
  if matched == nil then return nil, matchErr end
  if not matched then return false, nil end

  local chosenKind, chosenValue, chosenType = entry.targetKind, entry.targetValue, entry.targetType
  if entry.choices ~= nil then
    if type(ctx.targetFilter) ~= 'function' then
      return nil, 'place_ref choice targetFilter is unavailable'
    end
    local choiceFacts = {}
    for k, v in pairs(facts) do choiceFacts[k] = v end
    choiceFacts.position = current.position
    choiceFacts.currentCell = current.cell
    local selected, choiceErr, chosen = ctx.targetFilter(choiceFacts, ctx.choicePort, ctx)
    if selected == nil then return nil, tostring(choiceErr or 'choice evaluation failed') end
    if not selected then return false, nil, 'withdrawn' end
    if type(chosen) ~= 'table' then return nil, 'choice target is unavailable' end
    chosenKind, chosenValue, chosenType = chosen.targetKind, chosen.targetValue, chosen.targetType
  end

  local targetType = chosenKind == 'model_path' and facts.typeName or chosenType
  if not nonEmpty(targetType) then return nil, 'place_ref output type is unavailable' end
  if chosenKind == 'model_path' then
    local targetModel = model_path.normalize(chosenValue)
    if targetModel == nil then return nil, 'invalid replacement model path' end
    if sourceInfo.model == targetModel then return false, nil end
    chosenValue = targetModel
  end

  local outputRespawning = false
  if policy.transferKind == 'container' then
    if chosenKind == 'model_path' then
      outputRespawning = sourceInfo.isRespawning
    else
      local outInfo = ctx.placementOps.sourceRecordInfo(targetType, chosenValue)
      outputRespawning = outInfo and outInfo.isRespawning == true or false
    end
  end

  local authoredRecordId = chosenKind == 'model_path'
    and lower(ctx.authoredRecordId or facts.recordId)
    or lower(chosenValue)

  return {
    slot = entry.slot,
    targetKind = chosenKind,
    targetValue = chosenValue,
    authoredRecordId = authoredRecordId,
    sourceRecordId = facts.recordId,
    typeName = targetType,
    cell = clone(current.cell),
    position = {
      x = current.position.x + (entry.position and entry.position.x or 0),
      y = current.position.y + (entry.position and entry.position.y or 0),
      z = current.position.z + (entry.position and entry.position.z or 0),
    },
    rotation = entry.rotation ~= nil and normRotation(entry.rotation) or normRotation(current.rotation),
    scale = current.scale,
    owner = chosenKind == 'model_path' and clone(current.owner) or nil,
    transferKind = policy.transferKind,
    sourceRespawning = sourceInfo.isRespawning,
    outputRespawning = outputRespawning,
  }, nil
end

local function captureImpl(program, target, prevToken, ctx)
  local current, facts
  local isTransition = prevToken ~= nil
  if program.mode == 'relative' then
    local readErr
    current, readErr = ctx.refOps.read(target)
    if current == nil then return nil, readErr end
    facts = ctx.targetFacts
    if facts == nil then
      local fErr
      facts, fErr = ctx.world.describeRef(target, ctx.ledger)
      if facts == nil then return nil, fErr end
    end
  end

  local slots = {}
  local anyWithdrawn = false
  for i = 1, #(program.objects or {}) do
    local prepared, err, withdrawn = prepareSlot(
      program.objects[i], program, target, current, facts, isTransition, ctx
    )
    if prepared == nil then return nil, err end
    if withdrawn == 'withdrawn' then anyWithdrawn = true end
    if prepared ~= false then
      prepared.outputId = identity.outputId(ctx.targetId, 'place_ref', ctx.opId, prepared.slot)
      slots[#slots + 1] = prepared
    end
  end

  if #slots == 0 and anyWithdrawn then
    return {status = 'withdrawn'}, nil
  end
  if #slots == 0 then
    return {noop = true, mode = program.mode, slots = {}}, nil
  end

  local sourceEnabled = nil
  if program.mode == 'relative' and program.disableOriginal == true then
    if prevToken ~= nil and type(prevToken.sourceEnabled) == 'boolean' then
      sourceEnabled = prevToken.sourceEnabled
    else
      sourceEnabled = current.enabled
    end
  end

  return {
    mode = program.mode,
    disableOriginal = program.disableOriginal == true,
    sourceEnabled = sourceEnabled,
    slots = slots,
  }, nil
end

function M.matchesTarget(program, target, facts, ctx)
  if program.mode == 'absolute' then return true end
  for i = 1, #(program.objects or {}) do
    local ok = entryMatchesTarget(program.objects[i], program, target, facts, ctx)
    if ok == true then return true end
  end
  return false
end

function M.capture(program, target, ctx)
  return captureImpl(program, target, nil, ctx)
end

function M.prepareTransition(nextProgram, prevToken, target, ctx)
  return captureImpl(nextProgram, target, prevToken, ctx)
end

function M.apply(_program, target, token, ctx)
  if token == nil or token.noop or #(token.slots or {}) == 0 then
    return {status = 'noop', changedClaims = {}, outputs = {}}
  end
  local placeOps = ctx.placementOps
  local world = ctx.world
  local ledger = ctx.ledger

  local outputs = {}
  for i = 1, #token.slots do
    local slot = token.slots[i]
    if slot.typeName == 'Creature' and slot.targetKind == 'model_path' then
      local okElig, eligErr = placeOps.creatureEligible(target)
      if okElig ~= true then
        return {status = 'failed', changedClaims = {}, outputs = outputs, message = tostring(eligErr)}
      end
    end

    local actualRecordId = slot.targetValue
    local variantKey = nil
    if slot.targetKind == 'model_path' then
      local vErr
      actualRecordId, variantKey, vErr = placeOps.ensureVariantRecord(
        slot.typeName, target, slot.sourceRecordId, slot.targetValue, ledger
      )
      if actualRecordId == nil then
        return {status = 'failed', changedClaims = {}, outputs = outputs, message = tostring(vErr)}
      end
    end

    local created, createErr = placeOps.createObject(actualRecordId, slot)
    if created == nil then
      return {status = 'failed', changedClaims = {}, outputs = outputs, message = tostring(createErr)}
    end

    slot.objectId = created.objectId
    slot.actualRecordId = actualRecordId
    slot.variantKey = variantKey

    world.registerLiveOutput(slot.outputId, created.ref)
    ledger:putRef({
      kind = 'output',
      id = slot.outputId,
      objectId = created.objectId,
      recordId = slot.authoredRecordId,
      actualRecordId = actualRecordId,
      typeName = slot.typeName,
      cellKey = slot.cell.key,
      parentTargetId = ctx.targetId,
      producerId = ctx.opId,
      slot = slot.slot,
      variantKey = variantKey,
    })
    outputs[#outputs + 1] = slot.outputId
  end

  if #outputs == 0 then
    return {status = 'noop', changedClaims = {}, outputs = {}}
  end

  -- OpenMW queues world.createObject + teleport until end-of-tick; finalize
  -- container transfers, original disabling, and child eligibility on frame + 1
  -- once every spawned output has materialized in its destination cell.
  return {
    status = 'pending',
    changedClaims = {'output.existence'},
    outputs = outputs,
    pending = {
      phase = 'confirm-outputs',
      nextFrame = ctx.frame + 1,
    },
  }
end

function M.advance(pending, target, ctx)
  local token = ctx.token
  if token == nil or token.noop or #(token.slots or {}) == 0 then
    return {status = 'noop', changedClaims = {}}
  end
  local placeOps = ctx.placementOps
  local refOps = ctx.refOps
  local world = ctx.world
  local ledger = ctx.ledger

  if pending.phase == 'remove-outputs' then
    for i = #token.slots, 1, -1 do
      local slot = token.slots[i]
      local outputRef = slot.outputId and world.resolveTarget(slot.outputId, ledger) or nil
      if outputRef ~= nil then
        local okRem, remErr = placeOps.removeObject(outputRef)
        if not okRem then
          return {status = 'failed', changedClaims = {'output.existence'}, message = tostring(remErr)}
        end
      end
      if slot.outputId ~= nil then
        world.unregisterLiveOutput(slot.outputId)
        ledger:deleteRef(slot.outputId)
      end
    end
    return {
      status = 'applied',
      changedClaims = {'output.existence', 'ref.enabled', 'ref.inventory', 'ref.lock'},
    }
  end

  local changedSet = {['output.existence'] = true}
  local function mark(c) changedSet[c] = true end
  local function claimsList()
    local out = {}
    for c in pairs(changedSet) do out[#out + 1] = c end
    table.sort(out)
    return out
  end

  local outputs = {}
  local resolvedOutputs = {}
  for i = 1, #token.slots do
    local slot = token.slots[i]
    local outputRef = slot.outputId and world.resolveTarget(slot.outputId, ledger) or nil
    if outputRef == nil or not world.isValid(outputRef) or outputRef.cell == nil then
      return {
        status = 'pending',
        changedClaims = claimsList(),
        pending = {phase = 'confirm-outputs', nextFrame = ctx.frame + 1},
      }
    end
    resolvedOutputs[i] = outputRef
    outputs[#outputs + 1] = slot.outputId
  end

  local hasTransfer = false
  for i = 1, #token.slots do
    local slot = token.slots[i]
    local outputRef = resolvedOutputs[i]
    if slot.transferKind == 'container' then
      hasTransfer = true
      local xfer, xferErr = container_transfer.apply(target, outputRef, ctx)
      if xfer == nil then
        return {status = 'failed', changedClaims = claimsList(), outputs = outputs, message = tostring(xferErr)}
      end
      slot.lock = xfer.lock
      for j = 1, #xfer.changedClaims do mark(xfer.changedClaims[j]) end
    end
  end

  if token.mode == 'relative' and token.disableOriginal and not hasTransfer and #outputs > 0 then
    local okHide, hideErr = refOps.setEnabled(target, false)
    if not okHide then
      return {status = 'failed', changedClaims = claimsList(), outputs = outputs, message = tostring(hideErr)}
    end
    mark('ref.enabled')
  end

  return {
    status = 'applied',
    changedClaims = claimsList(),
    outputs = outputs,
  }
end

function M.revert(token, target, ctx)
  if token == nil or token.noop or #(token.slots or {}) == 0 then
    return {status = 'noop', changedClaims = {}}
  end
  local placeOps = ctx.placementOps
  local refOps = ctx.refOps
  local world = ctx.world
  local ledger = ctx.ledger

  local changedSet = {}
  local function mark(c) changedSet[c] = true end
  local function claimsList()
    local out = {}
    for c in pairs(changedSet) do out[#out + 1] = c end
    table.sort(out)
    return out
  end

  local hasTransfer = false
  local deferRemove = false
  for i = #token.slots, 1, -1 do
    local slot = token.slots[i]
    local outputRef = slot.outputId and world.resolveTarget(slot.outputId, ledger) or nil
    if slot.transferKind == 'container' then
      hasTransfer = true
      if outputRef == nil then
        return {
          status = 'pending',
          changedClaims = claimsList(),
          pending = {phase = 'await-target', nextFrame = ctx.frame + 1},
        }
      end
      local xfer, xferErr = container_transfer.revert(target, outputRef, slot, token.sourceEnabled, ctx)
      if xfer == nil then
        return {status = 'failed', changedClaims = claimsList(), message = tostring(xferErr)}
      end
      for j = 1, #xfer.changedClaims do mark(xfer.changedClaims[j]) end
      if xfer.movedItems then
        -- Wait 1 tick for OpenMW's moveInto() queue to flush before removing output container.
        deferRemove = true
      else
        local okRem, remErr = placeOps.removeObject(outputRef)
        if not okRem then
          return {status = 'failed', changedClaims = claimsList(), message = tostring(remErr)}
        end
      end
    else
      if outputRef ~= nil then
        local okRem, remErr = placeOps.removeObject(outputRef)
        if not okRem then
          return {status = 'failed', changedClaims = claimsList(), message = tostring(remErr)}
        end
        mark('output.existence')
      end
    end
    if not deferRemove and slot.outputId ~= nil then
      world.unregisterLiveOutput(slot.outputId)
      ledger:deleteRef(slot.outputId)
    end
  end

  if deferRemove then
    return {
      status = 'pending',
      changedClaims = claimsList(),
      pending = {phase = 'remove-outputs', nextFrame = ctx.frame + 1},
    }
  end

  if token.mode == 'relative' and token.disableOriginal and not hasTransfer
      and type(token.sourceEnabled) == 'boolean' and target ~= nil and world.isValid(target) then
    local okShow, showErr = refOps.setEnabled(target, token.sourceEnabled)
    if not okShow then
      return {status = 'failed', changedClaims = claimsList(), message = tostring(showErr)}
    end
    mark('ref.enabled')
  end

  local claims = claimsList()
  return {
    status = #claims > 0 and 'applied' or 'noop',
    changedClaims = claims,
  }
end

return M
