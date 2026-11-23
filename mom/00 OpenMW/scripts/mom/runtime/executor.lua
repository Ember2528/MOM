-- Single-commit synchronous action executor + durable pending/local resumption.
-- Replaces the 6-commit operation journal & projection pipeline.
local M = {}

local log = require('scripts.mom.diagnostics.log')

local function copyList(values)
  local out = {}
  for i = 1, #(values or {}) do out[i] = values[i] end
  return out
end

local function appendUniqueCells(dst, src)
  if type(src) ~= 'table' or #src == 0 then return dst end
  dst = dst or {}
  local seen = {}
  for i = 1, #dst do seen[dst[i]] = true end
  for i = 1, #src do
    local k = type(src[i]) == 'string' and src[i]:lower() or nil
    if k ~= nil and k ~= '' and not seen[k] then
      seen[k] = true
      dst[#dst + 1] = k
    end
  end
  return dst
end

function M.new(opts)
  local ledger = assert(opts.ledger, 'executor requires ledger')
  local session = assert(opts.session, 'executor requires session')
  local localBroker = assert(opts.localBroker, 'executor requires localBroker')
  local actionModules = assert(opts.actionModules, 'executor requires actionModules')
  local targetFilters = opts.targetFilters or {}
  local manifest = assert(opts.manifest, 'executor requires manifest')

  local errors = {}
  local MAX_RETAINED_ERRORS = 32

  local function recordError(code, actionId, targetId, message)
    log.warn('executor', '%s action=%s target=%s: %s',
      tostring(code), tostring(actionId), tostring(targetId), tostring(message))
    if #errors >= MAX_RETAINED_ERRORS then table.remove(errors, 1) end
    errors[#errors + 1] = {
      code = code,
      actionId = actionId,
      targetId = targetId,
      message = tostring(message),
    }
  end

  local function authoredRecordIdFor(targetId)
    local ref = ledger:getRef(targetId)
    return ref and ref.kind == 'output' and ref.recordId or nil
  end

  local function persistRecoveryCellsOnRef(targetId, recoveryCells)
    if type(recoveryCells) ~= 'table' or #recoveryCells == 0 then return end
    local stored = ledger:getRef(targetId)
    if stored ~= nil then
      stored.recoveryCells = appendUniqueCells(stored.recoveryCells, recoveryCells)
      ledger:putRef(stored)
    end
  end

  local function makeCtx(frame, opId, actionId, targetId, target, targetFacts)
    return {
      frame = frame,
      opId = opId,
      actionId = actionId,
      targetId = targetId,
      target = target,
      targetFacts = targetFacts,
      authoredRecordId = authoredRecordIdFor(targetId),
      ledger = ledger,
      world = session.world,
      refOps = session.refOps,
      inventoryOps = session.inventoryOps,
      placementOps = session.placementOps,
      actorOps = session.actorOps,
      localBroker = localBroker,
      targetFilter = targetFilters[actionId],
      choicePort = session.choicePort,
    }
  end

  local exec = {}

  function exec.apply(candidate, target, targetFacts, frame)
    local action = candidate.action
    local mod = actionModules[action.family]
    if mod == nil or type(mod.apply) ~= 'function' then
      recordError('action_unavailable', action.id, candidate.targetId, 'action module unavailable')
      return {status = 'failed', message = 'action module unavailable'}
    end

    local opId = ledger:nextOpId()
    local ctx = makeCtx(frame, opId, action.id, candidate.targetId, target, targetFacts)

    local token = nil
    if type(mod.capture) == 'function' then
      local okCap, capVal, capErr = pcall(mod.capture, action.program, target, ctx)
      if not okCap then
        recordError('capture_failed', action.id, candidate.targetId, capVal)
        return {status = 'failed', message = tostring(capVal)}
      end
      if capVal == nil then
        recordError('capture_failed', action.id, candidate.targetId, capErr)
        return {status = 'failed', message = tostring(capErr)}
      end
      if capVal.status == 'withdrawn' then
        return {status = 'withdrawn'}
      end
      token = capVal
    end

    local okApply, res = pcall(mod.apply, action.program, target, token, ctx)
    if not okApply or type(res) ~= 'table' then
      local msg = okApply and 'apply returned invalid result' or tostring(res)
      recordError('apply_failed', action.id, candidate.targetId, msg)
      return {status = 'failed', message = msg}
    end

    if res.status == 'failed' then
      recordError('apply_failed', action.id, candidate.targetId, res.message)
      return res
    end
    if res.status == 'noop' then
      return res
    end

    local recoveryCells = res.recoveryCells or (type(token) == 'table' and token.recoveryCells or nil)
    persistRecoveryCellsOnRef(candidate.targetId, recoveryCells)

    local op = ledger:putOp({
      id = opId,
      producerId = opId,
      semanticId = candidate.semanticId,
      family = action.family,
      actionId = action.id,
      ownerId = action.ownerId,
      lifecycle = action.lifecycle,
      durability = action.reversible == true and 'reversible' or 'permanent',
      targetId = candidate.targetId,
      targetRecordId = candidate.recordId or (targetFacts and targetFacts.recordId) or nil,
      cellKey = candidate.cellKey,
      parentOpId = candidate.parentOpId,
      depth = candidate.depth or 0,
      state = res.status == 'pending' and 'pending' or 'applied',
      priority = action.priority,
      specificity = action.specificity,
      order = action.order,
      claims = copyList(action.claims and action.claims.keys),
      changedClaims = copyList(res.changedClaims),
      token = token,
      pending = res.pending,
      outputs = copyList(res.outputs),
      recoveryCells = recoveryCells ~= nil and copyList(recoveryCells) or nil,
      appliedAt = frame,
      reassertable = type(mod.reassert) == 'function' or nil,
    })

    return {status = res.status, op = op, outputs = op.outputs}
  end

  function exec.reassert(op, action, target, targetFacts, frame)
    local mod = actionModules[action.family]
    if mod == nil or type(mod.reassert) ~= 'function' then
      return {status = 'noop'}
    end
    local ctx = makeCtx(frame, op.id, action.id, op.targetId, target, targetFacts)
    local ok, res = pcall(mod.reassert, action.program, target, op.token, ctx)
    if not ok or type(res) ~= 'table' then
      recordError('reassert_failed', action.id, op.targetId, ok and 'invalid reassert result' or res)
      return {status = 'failed', message = tostring(res)}
    end
    if res.status == 'applied' and res.recoveryCells ~= nil then
      persistRecoveryCellsOnRef(op.targetId, res.recoveryCells)
      ledger:updateOp(op.id, {recoveryCells = res.recoveryCells})
    end
    return res
  end

  function exec.revert(op, frame)
    if op == nil then return {status = 'noop'} end
    -- Permanent ops (e.g. kill_actor, permanent child modify_ref) never revert world state;
    -- preserve any recoveryCells onto ledger.refs before retiring!
    if op.durability == 'permanent' then
      persistRecoveryCellsOnRef(op.targetId, op.recoveryCells)
      ledger:deleteOp(op.id)
      return {status = 'applied'}
    end

    local mod = actionModules[op.family]
    if mod == nil or type(mod.revert) ~= 'function' then
      recordError('revert_unavailable', op.actionId, op.targetId, 'revert hook unavailable')
      return {status = 'failed', message = 'revert hook unavailable'}
    end

    local target = nil
    if op.targetId:sub(1, 5) == 'cell:' then
      target = session.world.resolveCell(op.targetId:sub(6))
    else
      target = session.world.resolveTarget(op.targetId, ledger)
    end
    if target == nil then
      -- Defer revert until the target cell/object is loaded.
      ledger:updateOp(op.id, {
        state = 'reverting',
        pending = {phase = 'await-target', nextFrame = frame + 1},
      })
      return {status = 'pending'}
    end

    local facts = nil
    if op.targetId:sub(1, 5) ~= 'cell:' then
      facts = session.world.describeRef(target, ledger)
    end
    local ctx = makeCtx(frame, op.id, op.actionId, op.targetId, target, facts)
    local ok, res = pcall(mod.revert, op.token, target, ctx)
    if not ok or type(res) ~= 'table' then
      local msg = ok and 'revert returned invalid result' or tostring(res)
      recordError('revert_failed', op.actionId, op.targetId, msg)
      return {status = 'failed', message = msg}
    end
    if res.status == 'failed' then
      recordError('revert_failed', op.actionId, op.targetId, res.message)
      return res
    end
    if res.status == 'pending' then
      ledger:updateOp(op.id, {state = 'reverting', pending = res.pending})
      return {status = 'pending'}
    end
    ledger:deleteOp(op.id)
    return {status = res.status}
  end

  -- Static plan evolution transition: capture next token (inheriting original baseline),
  -- revert previous op, then apply new action with next token.
  function exec.transition(prevOp, candidate, target, targetFacts, frame)
    local action = candidate.action
    local mod = actionModules[action.family]
    if mod == nil or type(mod.prepareTransition) ~= 'function'
        or type(mod.revert) ~= 'function' or type(mod.apply) ~= 'function' then
      recordError('transition_unsupported', action.id, candidate.targetId, 'family does not support transition')
      return {status = 'failed', message = 'family does not support transition'}
    end

    local opId = ledger:nextOpId()
    local nextCtx = makeCtx(frame, opId, action.id, candidate.targetId, target, targetFacts)
    local okPrep, nextToken, prepErr = pcall(mod.prepareTransition, action.program, prevOp.token, target, nextCtx)
    if not okPrep or nextToken == nil then
      recordError('transition_prepare_failed', action.id, candidate.targetId, okPrep and prepErr or nextToken)
      return {status = 'failed', message = tostring(okPrep and prepErr or nextToken)}
    end
    if nextToken.status == 'withdrawn' then
      return {status = 'withdrawn'}
    end

    local revRes = exec.revert(prevOp, frame)
    if revRes.status ~= 'applied' and revRes.status ~= 'noop' then
      return revRes
    end

    local okApply, res = pcall(mod.apply, action.program, target, nextToken, nextCtx)
    if not okApply or type(res) ~= 'table' then
      recordError('transition_apply_failed', action.id, candidate.targetId, okApply and 'invalid apply result' or res)
      return {status = 'failed', message = tostring(res)}
    end
    if res.status == 'failed' then
      recordError('transition_apply_failed', action.id, candidate.targetId, res.message)
      return res
    end
    if res.status == 'noop' then return res end

    local recoveryCells = res.recoveryCells or (type(nextToken) == 'table' and nextToken.recoveryCells or nil)
    persistRecoveryCellsOnRef(candidate.targetId, recoveryCells)

    local op = ledger:putOp({
      id = opId,
      producerId = opId,
      semanticId = candidate.semanticId,
      family = action.family,
      actionId = action.id,
      ownerId = action.ownerId,
      lifecycle = action.lifecycle,
      durability = action.reversible == true and 'reversible' or 'permanent',
      targetId = candidate.targetId,
      targetRecordId = candidate.recordId or (targetFacts and targetFacts.recordId) or nil,
      cellKey = candidate.cellKey,
      parentOpId = candidate.parentOpId,
      depth = candidate.depth or 0,
      state = res.status == 'pending' and 'pending' or 'applied',
      priority = action.priority,
      specificity = action.specificity,
      order = action.order,
      claims = copyList(action.claims and action.claims.keys),
      changedClaims = copyList(res.changedClaims),
      token = nextToken,
      pending = res.pending,
      outputs = copyList(res.outputs),
      recoveryCells = recoveryCells ~= nil and copyList(recoveryCells) or nil,
      appliedAt = frame,
      reassertable = type(mod.reassert) == 'function' or nil,
    })
    return {status = res.status, op = op, outputs = op.outputs}
  end

  local function finishPendingResult(op, res, frame)
    if res.status == 'pending' then
      ledger:updateOp(op.id, {pending = res.pending})
      return 'pending'
    end
    if res.status == 'failed' then
      recordError('pending_failed', op.actionId, op.targetId, res.message)
      if op.state == 'reverting' then
        -- Retry revert later instead of abandoning cleanup.
        ledger:updateOp(op.id, {
          pending = {phase = 'await-target', nextFrame = frame + 5},
        })
      else
        ledger:deleteOp(op.id)
      end
      return 'failed'
    end
    if op.state == 'reverting' then
      ledger:deleteOp(op.id)
      return 'reverted'
    end
    if res.status == 'noop' then
      ledger:deleteOp(op.id)
      return 'noop'
    end
    ledger:updateOp(op.id, {
      state = 'applied',
      pending = ledger.NIL,
      changedClaims = copyList(res.changedClaims or op.changedClaims),
      outputs = copyList(res.outputs or op.outputs),
    })
    return 'applied'
  end

  function exec.deliverCompletion(ack, frame)
    local op = ledger:getOp(ack.opId)
    if op == nil or (op.state ~= 'pending' and op.state ~= 'reverting') then
      return false
    end
    local mod = actionModules[op.family]
    if mod == nil or type(mod.complete) ~= 'function' then return false end
    local target = session.world.resolveTarget(op.targetId, ledger)
    local facts = target and op.targetId:sub(1, 5) ~= 'cell:' and session.world.describeRef(target, ledger) or nil
    local ctx = makeCtx(frame, op.id, op.actionId, op.targetId, target, facts)
    local ok, res = pcall(mod.complete, op.pending, ack, target, ctx)
    if not ok or type(res) ~= 'table' then
      recordError('complete_failed', op.actionId, op.targetId, ok and 'invalid complete result' or res)
      return false
    end
    finishPendingResult(op, res, frame)
    return true
  end

  function exec.advancePending(op, frame)
    if op == nil or (op.state ~= 'pending' and op.state ~= 'reverting') then
      return 'noop'
    end
    local pending = op.pending
    if type(pending) == 'table' and pending.awaitingCompletion == true
        and localBroker.hasInFlight(op.id) then
      return 'waiting'
    end
    if op.state == 'reverting' and type(pending) == 'table' and pending.phase == 'await-target' then
      local res = exec.revert(op, frame)
      return res.status
    end
    local target = op.targetId:sub(1, 5) == 'cell:'
      and session.world.resolveCell(op.targetId:sub(6))
      or session.world.resolveTarget(op.targetId, ledger)
    if target == nil then
      ledger:updateOp(op.id, {
        pending = {
          phase = pending and pending.phase or 'await-target',
          autoEquip = pending and pending.autoEquip,
          changes = pending and pending.changes,
          attempts = pending and pending.attempts,
          changedClaims = pending and pending.changedClaims,
          nextFrame = frame + 1,
        },
      })
      return 'waiting'
    end
    local mod = actionModules[op.family]
    if mod == nil or type(mod.advance) ~= 'function' then
      if op.state == 'reverting' then
        local res = exec.revert(op, frame)
        return res.status
      end
      return 'waiting'
    end
    local facts = op.targetId:sub(1, 5) ~= 'cell:' and session.world.describeRef(target, ledger) or nil
    local ctx = makeCtx(frame, op.id, op.actionId, op.targetId, target, facts)
    ctx.token = op.token
    local ok, res = pcall(mod.advance, pending, target, ctx)
    if not ok or type(res) ~= 'table' then
      recordError('advance_failed', op.actionId, op.targetId, ok and 'invalid advance result' or res)
      return 'failed'
    end
    return finishPendingResult(op, res, frame)
  end

  function exec.errors()
    return errors
  end

  return exec
end

return M
