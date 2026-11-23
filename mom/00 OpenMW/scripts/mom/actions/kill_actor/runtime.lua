-- Clean action runtime for kill_actor (irreversible actor-local death).
local M = {}

local constants = require('scripts.mom.constants')
local target_match_plan = require('scripts.mom.contracts.target_match_plan')

local KILL_SCRIPT = 'scripts/mom/local/kill.lua'

local function matchesPlan(program, facts)
  local plan = program and program.matchPlan
  if plan == nil then return true, nil end
  local cursor = {anyIndex = 1, positionIndex = 1}
  while true do
    local entry, nextCursor, complete = target_match_plan.next(plan, facts, cursor)
    if entry == nil then
      if complete then return false, nil end
      return nil, 'kill_actor match cursor stalled'
    end
    local ok, err = target_match_plan.matches(entry, facts)
    if ok == nil then return nil, err end
    if ok then return true, nil end
    cursor = nextCursor
  end
end

local function sendKill(target, ctx)
  local reqId, err = ctx.localBroker.send(
    ctx.opId,
    target,
    KILL_SCRIPT,
    constants.events.killNow,
    {health = 0, overshoot = -10},
    {frame = ctx.frame, cancelEvent = constants.events.killCancel}
  )
  if reqId == nil then
    return {status = 'failed', changedClaims = {}, message = tostring(err or 'kill send failed')}
  end
  return {
    status = 'pending',
    changedClaims = {},
    pending = {
      phase = 'await-death',
      nextFrame = ctx.frame + 1,
      awaitingCompletion = true,
    },
  }
end

function M.matchesTarget(program, _target, facts)
  local matched = matchesPlan(program, facts)
  return matched == true
end

function M.apply(program, target, _token, ctx)
  local matched, matchErr = matchesPlan(program, ctx.targetFacts)
  if matched == nil then
    return {status = 'failed', changedClaims = {}, message = tostring(matchErr)}
  end
  if not matched then
    return {status = 'noop', changedClaims = {}}
  end
  local life, lifeErr = ctx.actorOps.readLife(target)
  if life == nil then
    return {status = 'failed', changedClaims = {}, message = tostring(lifeErr)}
  end
  if not life.isActor then
    return {status = 'failed', changedClaims = {}, message = 'kill_actor target is not an actor'}
  end
  if not life.alive or life.summoned then
    return {status = 'noop', changedClaims = {}}
  end
  return sendKill(target, ctx)
end

function M.complete(_pending, ack, target, ctx)
  if type(ack) == 'table' and type(ack.data) == 'table' and ack.data.dead == true then
    return {status = 'applied', changedClaims = {'actor.life'}}
  end
  if target ~= nil and ctx.world.isValid(target) then
    local life = ctx.actorOps.readLife(target)
    if life and not life.alive then
      return {status = 'applied', changedClaims = {'actor.life'}}
    end
    if life and life.summoned then
      return {status = 'noop', changedClaims = {}}
    end
  end
  if type(ack) == 'table' and ack.expired == true and target ~= nil and ctx.world.isValid(target) then
    return sendKill(target, ctx)
  end
  return {
    status = 'failed',
    changedClaims = {},
    message = tostring(ack and ack.error or 'kill_actor local script failed'),
  }
end

function M.advance(_pending, target, ctx)
  local life, lifeErr = ctx.actorOps.readLife(target)
  if life == nil then
    return {status = 'failed', changedClaims = {}, message = tostring(lifeErr)}
  end
  if not life.isActor then
    return {status = 'failed', changedClaims = {}, message = 'kill_actor target is not an actor'}
  end
  if not life.alive then
    return {status = 'applied', changedClaims = {'actor.life'}}
  end
  if life.summoned then
    return {status = 'noop', changedClaims = {}}
  end
  return sendKill(target, ctx)
end

return M
