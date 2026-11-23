-- Actor-local equipment bridge. The global runtime attaches this script for
-- one queued equip request and waits for the completion event.
local types = require('openmw.types')
local selfObj = require('openmw.self')
local core = require('openmw.core')
local constants = require('scripts.mom.constants')
local EQUIP_EVENT = constants.events.equipItem
local COMPLETE_EVENT = constants.events.equipDone
local function isActorSelf()
  return types.Actor.objectIsInstance(selfObj)
end
local function emitComplete(commandId, requestId, ok, err)
  core.sendGlobalEvent(COMPLETE_EVENT, {
    object = selfObj,
    commandId = commandId,
    requestId = requestId,
    ok = ok == true,
    error = err,
  })
end
local function handleEquip(data)
  if not data then return end
  local commandId = data.commandId
  local requestId = data.requestId
  if not isActorSelf() then
    emitComplete(
      commandId,
      requestId,
      false,
      'local script owner is not an actor'
    )
    return
  end
  local equipment = types.Actor.getEquipment(selfObj)
  if type(equipment) ~= 'table' then
    emitComplete(commandId, requestId, false, 'equipment unavailable')
    return
  end
  local item = data.item
  local recordId = data.recordId
  local slots = data.slots
  local changes = data.changes
  if type(changes) == 'table' and #changes > 0 then
    for i = 1, #changes do
      local change = changes[i]
      if type(change) ~= 'table' or type(change.slot) ~= 'number'
          or change.slot < 0 or change.slot % 1 ~= 0
          or (change.recordId ~= nil and type(change.recordId) ~= 'string') then
        emitComplete(
          commandId,
          requestId,
          false,
          'invalid equipment change'
        )
        return
      end
      equipment[change.slot] = change.recordId
    end
  else
    if not slots or #slots == 0 then
      emitComplete(
        commandId,
        requestId,
        false,
        'missing equipment slots'
      )
      return
    end
    for _, slot in ipairs(slots) do
      equipment[slot] = item or recordId
    end
  end
  local okSet, errSet = pcall(types.Actor.setEquipment, selfObj, equipment)
  if not okSet then
    emitComplete(commandId, requestId, false, tostring(errSet))
    return
  end
  emitComplete(commandId, requestId, true)
end
return {
  eventHandlers = {
    [EQUIP_EVENT] = handleEquip,
  },
}
