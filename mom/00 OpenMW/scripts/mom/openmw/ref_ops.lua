-- OpenMW live reference operations: read, starting transform (with Door
-- origin persistence), owner, scale (with deferred-visibility overlay),
-- teleport (with scale/enabled restamping & exterior grid fencing), enabled,
-- and per-field Lockable read/write.
local M = {}

local cell_identity = require('scripts.mom.domain.cell.identity')
local deadline_queue = require('scripts.mom.common.deadline_queue')
local openmw_api = require('scripts.mom.openmw.api')
local ownership = require('scripts.mom.domain.ref.ownership')
local strings = require('scripts.mom.common.strings')

local call = openmw_api.call
local property = openmw_api.property
local nonEmpty = strings.isNonEmpty
local SCALE_RETENTION_FRAMES = 300

local function scalesEqual(a, b)
  return type(a) == 'number' and type(b) == 'number' and math.abs(a - b) <= 0.000001
end

function M.new(deps, worldAdapter)
  deps = deps or {}
  local types = openmw_api.dependency(deps, 'types', 'openmw.types')
  local util = openmw_api.dependency(deps, 'util', 'openmw.util')

  local currentFrame = 0
  local scaleOverlays = {}
  local scaleDeadlines = deadline_queue.new()
  local teleportedThisFrame = {}

  local function scaleKey(ref)
    local id = property(ref, 'id')
    return nonEmpty(id) and tostring(id) or nil
  end

  local function ageScales(frame)
    local nextFrame = math.max(currentFrame, math.floor(tonumber(frame) or currentFrame))
    if nextFrame ~= currentFrame then
      teleportedThisFrame = {}
    end
    currentFrame = nextFrame
    while true do
      local due = deadline_queue.popNextDue(scaleDeadlines, currentFrame)
      if due == nil then break end
      scaleOverlays[due.id] = nil
    end
  end

  local function retainScale(key, scale)
    if key == nil then return end
    scaleOverlays[key] = scale
    deadline_queue.upsert(scaleDeadlines, key, currentFrame + SCALE_RETENTION_FRAMES + 1)
  end

  local function authoritativeScale(ref, liveScale)
    local key = scaleKey(ref)
    local pending = key and scaleOverlays[key] or nil
    if pending == nil then return liveScale, key end
    if scalesEqual(liveScale, pending) then
      scaleOverlays[key] = nil
      deadline_queue.remove(scaleDeadlines, key)
    end
    return pending, key
  end

  local function rotationTransform(rotation)
    local t = util and util.transform
    if type(t) ~= 'table' and not openmw_api.isNamespace(t) then
      return nil, 'OpenMW util.transform is unavailable'
    end
    local ok, value = pcall(function()
      return t.rotateZ(math.rad(rotation.yaw or 0))
        * t.rotateY(math.rad(rotation.pitch or 0))
        * t.rotateX(math.rad(rotation.roll or 0))
    end)
    if not ok then return nil, tostring(value) end
    return value, nil
  end

  local ops = {}

  function ops.beginFrame(frame)
    ageScales(frame)
  end

  function ops.read(ref)
    if not worldAdapter.isValid(ref) then return nil, 'ref is invalid' end
    local enabled, enErr = property(ref, 'enabled')
    if enErr ~= nil or type(enabled) ~= 'boolean' then
      return nil, enErr or 'ref enabled state is invalid'
    end
    local liveScale, scErr = property(ref, 'scale')
    if scErr ~= nil or type(liveScale) ~= 'number' then
      return nil, scErr or 'ref scale is invalid'
    end
    local scale = authoritativeScale(ref, liveScale)
    local rawPos, posErr = property(ref, 'position')
    if posErr ~= nil then return nil, posErr end
    local position = worldAdapter.plainPosition(rawPos)
    if position == nil then return nil, 'ref position is invalid' end
    local cell, cellErr = property(ref, 'cell')
    if cell == nil then return nil, cellErr or 'ref is not in a cell' end
    local cellFacts, factsErr = worldAdapter.describeCell(cell)
    if cellFacts == nil then return nil, factsErr end
    local rawRot, rotErr = property(ref, 'rotation')
    if rotErr ~= nil then return nil, rotErr end
    local angles, angErr = worldAdapter.rotationDegrees(rawRot)
    if angles == nil then return nil, angErr end
    local owner, ownErr = property(ref, 'owner')
    if ownErr ~= nil then return nil, ownErr end
    return {
      enabled = enabled,
      owner = ownership.snapshot(owner),
      scale = scale,
      cell = cellFacts,
      position = position,
      rotation = {yaw = angles.yaw, pitch = angles.pitch, roll = angles.roll},
    }, nil
  end

  function ops.readStarting(ref, ledger, targetId)
    if not worldAdapter.isValid(ref) then return nil, 'ref is invalid' end
    local typeName, typeErr = worldAdapter.typeNameForRef(ref)
    if typeName == nil then return nil, typeErr end
    -- Prefer persisted Door origin when available (OpenMW door startingTransform
    -- can shift or lack reliable starting cell/rotation after moves).
    if typeName == 'Door' and ledger ~= nil and nonEmpty(targetId) then
      local stored = ledger:getRef(targetId)
      if stored and type(stored.origin) == 'table' and stored.origin.cellId then
        local c = worldAdapter.resolveCell(stored.origin.cellId)
        local cFacts = c and worldAdapter.describeCell(c) or nil
        if cFacts and stored.origin.position and stored.origin.rotation then
          return {
            cell = cFacts,
            position = stored.origin.position,
            rotation = stored.origin.rotation,
            typeName = typeName,
          }, nil
        end
      end
    end
    local sCell, sCellErr = property(ref, 'startingCell')
    if sCellErr ~= nil then return nil, sCellErr end
    local cellFacts
    if sCell ~= nil then
      cellFacts, sCellErr = worldAdapter.describeCell(sCell)
      if cellFacts == nil then return nil, sCellErr end
    end
    local sPos, sPosErr = property(ref, 'startingPosition')
    if sPosErr ~= nil then return nil, sPosErr end
    local sRot, sRotErr = property(ref, 'startingRotation')
    if sRotErr ~= nil then return nil, sRotErr end
    local angles
    if sRot ~= nil then
      angles, sRotErr = worldAdapter.rotationDegrees(sRot)
      if angles == nil then return nil, sRotErr end
    end
    return {
      cell = cellFacts,
      position = worldAdapter.plainPosition(sPos),
      rotation = angles and {yaw = angles.yaw, pitch = angles.pitch, roll = angles.roll} or nil,
      typeName = typeName,
    }, nil
  end

  function ops.setOwner(ref, owner)
    local ok, err = ownership.apply(ref, owner)
    if ok ~= true then return nil, err end
    return true, nil
  end

  function ops.setScale(ref, scale)
    local _, err = call(ref.setScale, ref, scale)
    if err ~= nil then return nil, err end
    retainScale(scaleKey(ref), scale)
    return true, nil
  end

  function ops.setEnabled(ref, enabled)
    local ok, err = pcall(function() ref.enabled = enabled == true end)
    if not ok then return nil, tostring(err) end
    return true, nil
  end

  function ops.teleport(ref, destination)
    if type(destination) ~= 'table' or type(destination.cell) ~= 'table'
        or type(destination.position) ~= 'table' then
      return nil, 'teleport destination is invalid'
    end
    local cell, cellErr = worldAdapter.resolveCell(destination.cell.key or destination.cell.id)
    if cell == nil then return nil, cellErr end
    local pos = worldAdapter.plainPosition(destination.position)
    if pos == nil then return nil, 'teleport position is invalid' end
    local vec, vecErr = call(util.vector3, pos.x, pos.y, pos.z)
    if vec == nil then return nil, vecErr end

    local srcCell = property(ref, 'cell')
    local wasEnabled = srcCell ~= nil and property(ref, 'enabled') or nil
    local liveScale = srcCell ~= nil and property(ref, 'scale') or nil
    local wasScale, key = nil, nil
    if type(liveScale) == 'number' then
      wasScale, key = authoritativeScale(ref, liveScale)
    end

    -- Fence source, requested destination, and actual exterior grid cell.
    if srcCell ~= nil then worldAdapter.fenceCell(srcCell, currentFrame) end
    worldAdapter.fenceCell(cell, currentFrame)
    local destFacts = worldAdapter.describeCell(cell)
    if destFacts then
      local parsed = cell_identity.parseExteriorKey(destFacts.key)
      if destFacts.isExterior == true or parsed ~= nil then
        local actualKey = cell_identity.exteriorKey(
          destFacts.worldspaceKey or (parsed and parsed.worldspace),
          math.floor(pos.x / 8192), math.floor(pos.y / 8192))
        if actualKey then
          local actualCell = worldAdapter.resolveCell(actualKey)
          if actualCell then worldAdapter.fenceCell(actualCell, currentFrame) end
        end
      end
    end

    local refKey = scaleKey(ref)
    if refKey ~= nil and teleportedThisFrame[refKey] == currentFrame then
      return nil, 'ref_teleport_busy'
    end

    local _, tpErr
    if destination.rotation ~= nil then
      local rot, rotErr = rotationTransform(destination.rotation)
      if rot == nil then return nil, rotErr end
      _, tpErr = call(ref.teleport, ref, cell, vec, {rotation = rot})
    else
      _, tpErr = call(ref.teleport, ref, cell, vec)
    end
    if tpErr ~= nil then return nil, tpErr end
    if refKey ~= nil then teleportedThisFrame[refKey] = currentFrame end

    -- Restamp authoritative scale & disabled visibility after OpenMW teleport.
    if type(wasScale) == 'number' then
      local _, scErr = call(ref.setScale, ref, wasScale)
      if scErr ~= nil then return nil, scErr end
      retainScale(key, wasScale)
    end
    if wasEnabled == false then
      local ok, enErr = pcall(function() ref.enabled = false end)
      if not ok then return nil, tostring(enErr) end
    end
    return true, nil
  end

  function ops.readLock(ref)
    local lockable = types and types.Lockable
    if not openmw_api.isNamespace(lockable) then
      return {locked = false, lockLevel = 0}, nil
    end
    local locked, lockErr = call(lockable.isLocked, ref)
    if type(locked) ~= 'boolean' then return nil, lockErr or 'lock state unavailable' end
    local level, levelErr = call(lockable.getLockLevel, ref)
    if levelErr ~= nil then return nil, levelErr end
    local keyRec = call(lockable.getKeyRecord, ref)
    local trapRec = call(lockable.getTrapSpell, ref)
    local keyId = keyRec and property(keyRec, 'id')
    local trapId = trapRec and property(trapRec, 'id')
    return {
      locked = locked,
      lockLevel = locked and math.max(1, math.floor(tonumber(level) or 0)) or 0,
      keyRecordId = nonEmpty(keyId) and tostring(keyId):lower() or nil,
      trapSpellId = nonEmpty(trapId) and tostring(trapId):lower() or nil,
    }, nil
  end

  function ops.writeLock(ref, lock)
    local lockable = types and types.Lockable
    if not openmw_api.isNamespace(lockable) then return true, nil, false end
    local current, readErr = ops.readLock(ref)
    if current == nil then return nil, readErr, false end
    local changed = false
    if lock.locked then
      if not current.locked or current.lockLevel ~= lock.lockLevel then
        local _, err = call(lockable.lock, ref, lock.lockLevel)
        if err ~= nil then return nil, err, changed end
        changed = true
      end
    elseif current.locked then
      local _, err = call(lockable.unlock, ref)
      if err ~= nil then return nil, err, changed end
      changed = true
    end
    if current.keyRecordId ~= lock.keyRecordId then
      local _, err = call(lockable.setKeyRecord, ref, lock.keyRecordId)
      if err ~= nil then return nil, err, changed end
      changed = true
    end
    if current.trapSpellId ~= lock.trapSpellId then
      local _, err = call(lockable.setTrapSpell, ref, lock.trapSpellId)
      if err ~= nil then return nil, err, changed end
      changed = true
    end
    return true, nil, changed
  end

  function ops.clear()
    scaleOverlays = {}
    teleportedThisFrame = {}
    deadline_queue.clear(scaleDeadlines)
  end

  return ops
end

return M
