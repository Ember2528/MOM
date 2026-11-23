-- Synchronous 1-tick container transfer for place_ref Container replacements.
-- Replaces the 1,067-line 15-phase cursor state machine and 10-table storage DB.
local M = {}

function M.apply(source, output, ctx)
  local invOps = ctx.inventoryOps
  local refOps = ctx.refOps

  local lock, lockErr = refOps.readLock(source)
  if lock == nil then return nil, lockErr end

  local okHideOut, hideOutErr = refOps.setEnabled(output, false)
  if not okHideOut then return nil, hideOutErr end

  local outInv, _, outInvErr = invOps.getInventory(output)
  if outInv == nil then return nil, outInvErr end
  local okResOut, resOutErr = invOps.ensureResolved(outInv)
  if not okResOut then return nil, resOutErr end

  -- Clear default leveled/static items from the newly created output container.
  local okClear, clearErr = invOps.clearInventory(outInv, false)
  if not okClear then return nil, clearErr end

  local srcInv, _, srcInvErr = invOps.getInventory(source)
  if srcInv == nil then return nil, srcInvErr end
  local okResSrc, resSrcErr = invOps.ensureResolved(srcInv)
  if not okResSrc then return nil, resSrcErr end

  -- Move all live source items synchronously into output (rejecting restocking).
  local okMove, moveErr = invOps.moveAllItems(srcInv, outInv, true)
  if not okMove then return nil, moveErr end

  local okLock, writeLockErr = refOps.writeLock(output, lock)
  if not okLock then return nil, writeLockErr end

  local okHideSrc, hideSrcErr = refOps.setEnabled(source, false)
  if not okHideSrc then return nil, hideSrcErr end

  local okShowOut, showOutErr = refOps.setEnabled(output, true)
  if not okShowOut then return nil, showOutErr end

  return {
    lock = lock,
    changedClaims = {'output.existence', 'ref.enabled', 'ref.inventory', 'ref.lock'},
  }, nil
end

function M.revert(source, output, slotToken, sourceEnabled, ctx)
  local invOps = ctx.inventoryOps
  local refOps = ctx.refOps

  local movedItems = false
  if output ~= nil and ctx.world.isValid(output) then
    local outLock, lockErr = refOps.readLock(output)
    if outLock == nil then return nil, lockErr end

    local okHideOut, hideOutErr = refOps.setEnabled(output, false)
    if not okHideOut then return nil, hideOutErr end

    local srcInv, _, srcInvErr = invOps.getInventory(source)
    if srcInv == nil then return nil, srcInvErr end
    local okResSrc, resSrcErr = invOps.ensureResolved(srcInv)
    if not okResSrc then return nil, resSrcErr end

    -- If the hidden source container respawns natively, clear its hidden shadow
    -- refill BEFORE returning the output's live inventory (preserving any
    -- player deposits while preventing loot duplication).
    if slotToken.sourceRespawning == true then
      local okClear, clearErr = invOps.clearInventory(srcInv, true)
      if not okClear then return nil, clearErr end
    end

    local outInv, _, outInvErr = invOps.getInventory(output)
    if outInv == nil then return nil, outInvErr end
    local okResOut, resOutErr = invOps.ensureResolved(outInv)
    if not okResOut then return nil, resOutErr end

    local okMove, moveErr, moved = invOps.moveAllItems(outInv, srcInv, true)
    if not okMove then return nil, moveErr end
    movedItems = moved == true

    local okLock, writeLockErr = refOps.writeLock(source, outLock)
    if not okLock then return nil, writeLockErr end
  end

  if type(sourceEnabled) == 'boolean' then
    local okShow, showErr = refOps.setEnabled(source, sourceEnabled)
    if not okShow then return nil, showErr end
  end

  return {
    movedItems = movedItems,
    changedClaims = {'output.existence', 'ref.enabled', 'ref.inventory', 'ref.lock'},
  }, nil
end

return M
