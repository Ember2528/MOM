-- Actor-local kill helper. Request IDs identify physical sends while command
-- IDs retain the durable mutation identity expected by the global journal.
local selfObj = require('openmw.self')
local types = require('openmw.types')
local core = require('openmw.core')
local constants = require('scripts.mom.constants')

local COMPLETE_EVENT = constants.events.killDone
local pending = {}

local nonEmpty = require('scripts.mom.common.strings').isNonEmpty

local function isActorSelf()
  return types.Actor.objectIsInstance(selfObj)
end

local function actorIsDead()
  if not isActorSelf() then return false end
  local ok, dead = pcall(types.Actor.isDead, selfObj)
  return ok and dead == true or false
end

local function emitComplete(
    commandId,
    requestId,
    ok,
    dead,
    err)
  core.sendGlobalEvent(COMPLETE_EVENT, {
    object = selfObj,
    commandId = commandId,
    requestId = requestId,
    ok = ok == true,
    dead = dead == true,
    error = err,
  })
end

local function applyOneShotHealthReduction(target, overshoot)
  if not isActorSelf() then
    return false, false,
      'local script owner is not an actor'
  end
  if actorIsDead() then return true, true, nil end
  local health = types.Actor.stats.dynamic.health(selfObj)
  if not (health and health.current ~= nil) then
    return false, actorIsDead(), 'health unavailable'
  end
  local targetHealth = target or 0
  local overshootHealth = overshoot or -1
  local killHealth = math.min(targetHealth, overshootHealth)
  if health.current ~= killHealth then
    health.current = killHealth
  end
  return true, actorIsDead(), nil
end

local function handleOneShotKillRequest(data)
  local commandId =
    type(data) == 'table' and data.commandId or nil
  local requestId =
    type(data) == 'table' and data.requestId or nil
  if not nonEmpty(commandId)
      or not nonEmpty(requestId) then
    emitComplete(
      commandId,
      requestId,
      false,
      actorIsDead(),
      'missing command or request id'
    )
    return
  end
  if pending[requestId] ~= nil then return end
  local okCall, ok, dead, err = pcall(
    applyOneShotHealthReduction,
    data.health or 0,
    data.overshoot or -10
  )
  if not okCall then
    emitComplete(
      commandId,
      requestId,
      false,
      actorIsDead(),
      tostring(ok)
    )
    return
  end
  if not ok then
    emitComplete(
      commandId,
      requestId,
      false,
      dead,
      err
    )
  elseif dead then
    emitComplete(
      commandId,
      requestId,
      true,
      true
    )
  else
    pending[requestId] = commandId
  end
end

local function handleCancel(data)
  if type(data) == 'table' and data.clear == true then
    pending = {}
    return
  end
  local requestId =
    type(data) == 'table' and data.requestId or nil
  if nonEmpty(requestId) then pending[requestId] = nil end
end

local function onUpdate()
  if next(pending) == nil or not actorIsDead() then
    return
  end
  local requestIds = {}
  for requestId in pairs(pending) do
    requestIds[#requestIds + 1] = requestId
  end
  table.sort(requestIds)
  local completed = pending
  pending = {}
  for i = 1, #requestIds do
    local requestId = requestIds[i]
    emitComplete(
      completed[requestId],
      requestId,
      true,
      true
    )
  end
end

return {
  eventHandlers = {
    [constants.events.killNow] =
      handleOneShotKillRequest,
    [constants.events.killCancel] =
      handleCancel,
  },
  engineHandlers = {
    onUpdate = onUpdate,
  },
}
