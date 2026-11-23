-- Clean action runtime for modify_ref (transform, scale, owner, enabled, Door origins).
local M = {}

local modify_patch = require('scripts.mom.actions.modify_ref.patch')
local plain_data = require('scripts.mom.contracts.plain_data')
local recovery_locations = require('scripts.mom.actions.modify_ref.recovery_locations')
local target_match_plan = require('scripts.mom.contracts.target_match_plan')

local function clone(value)
  if value == nil then return nil end
  return plain_data.cloneValidated(value)
end

local function touchesTransform(patch)
  return patch ~= nil and (patch.position ~= nil or patch.rotation ~= nil or patch.relocate ~= nil)
end

local function resolveEffectivePatch(program, facts)
  local patch = modify_patch.copyPatch(program and program.basePatch) or {}
  local plan = program and program.matchPlan
  if plan == nil then return patch, nil end
  local cursor = {anyIndex = 1, positionIndex = 1}
  while true do
    local entry, nextCursor, complete = target_match_plan.next(plan, facts, cursor)
    if entry == nil then
      if complete then return patch, nil end
      return nil, 'modify_ref match cursor stalled'
    end
    local matched, err = target_match_plan.matches(entry, facts)
    if matched == nil then return nil, err end
    if matched and entry.payload and entry.payload.patch then
      patch = modify_patch.overlayPatch(patch, entry.payload.patch) or {}
    end
    cursor = nextCursor
  end
end

local function sameFloat(a, b)
  if type(a) ~= 'number' or type(b) ~= 'number' then return false end
  if a == b then return true end
  local mag = math.max(math.abs(a), math.abs(b))
  local tol = 0.000001
  if mag > 0 then
    tol = math.max(tol, 2 ^ (math.floor(math.log(mag) / math.log(2)) - 24) * 1.01)
  end
  return math.abs(a - b) <= tol
end

local function samePosition(a, b)
  return type(a) == 'table' and type(b) == 'table'
    and sameFloat(a.x, b.x) and sameFloat(a.y, b.y) and sameFloat(a.z, b.z)
end

local function sameRotation(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  local function quat(v)
    local yaw, pitch, roll = v.yaw or 0, v.pitch or 0, v.roll or 0
    if type(yaw) ~= 'number' or type(pitch) ~= 'number' or type(roll) ~= 'number' then return nil end
    local z, y, x = math.rad(yaw) / 2, math.rad(pitch) / 2, math.rad(roll) / 2
    local cz, sz = math.cos(z), math.sin(z)
    local cy, sy = math.cos(y), math.sin(y)
    local cx, sx = math.cos(x), math.sin(x)
    return {
      cz * cy * cx + sz * sy * sx,
      cz * cy * sx - sz * sy * cx,
      cz * sy * cx + sz * cy * sx,
      sz * cy * cx - cz * sy * sx,
    }
  end
  local q1, q2 = quat(a), quat(b)
  if q1 == nil or q2 == nil then return false end
  return math.abs(q1[1] * q2[1] + q1[2] * q2[2] + q1[3] * q2[3] + q1[4] * q2[4]) >= 0.999999
end

local function sameCell(current, desired)
  local key = current.cell and (current.cell.key or current.cell.id)
  local dest = recovery_locations.cellAt(desired.cell, desired.position)
  return type(key) == 'string' and key:lower() == dest
end

local function desiredPosition(patch, starting, current)
  if patch.relocate ~= nil then return clone(patch.relocate.position) end
  if patch.position == nil then return clone(current.position) end
  if patch.position.mode == 'move' then
    return {
      x = starting.position.x + patch.position.x,
      y = starting.position.y + patch.position.y,
      z = starting.position.z + patch.position.z,
    }
  end
  return {x = patch.position.x, y = patch.position.y, z = patch.position.z}
end

local function desiredRotation(patch, starting)
  if patch.relocate and patch.relocate.rotation then return clone(patch.relocate.rotation) end
  if patch.rotation == nil then return nil end
  local src = starting.rotation or {yaw = 0, pitch = 0, roll = 0}
  if patch.rotation.mode == 'rotate' then
    return {
      yaw = (src.yaw or 0) + (patch.rotation.yaw or 0),
      pitch = (src.pitch or 0) + (patch.rotation.pitch or 0),
      roll = (src.roll or 0) + (patch.rotation.roll or 0),
    }
  end
  return {
    yaw = patch.rotation.yaw ~= nil and patch.rotation.yaw or src.yaw,
    pitch = patch.rotation.pitch ~= nil and patch.rotation.pitch or src.pitch,
    roll = patch.rotation.roll ~= nil and patch.rotation.roll or src.roll,
  }
end

local function desiredTransform(patch, starting, current)
  if not touchesTransform(patch) then return nil end
  return {
    cell = clone(patch.relocate and patch.relocate.cell
      or (patch.position and starting.cell) or current.cell),
    position = desiredPosition(patch, starting, current),
    rotation = desiredRotation(patch, starting),
  }
end

local function transformClaims(current, desired, patch)
  local claims = {}
  local hasPos = patch.position ~= nil or patch.relocate ~= nil
  if hasPos and (not sameCell(current, desired) or not samePosition(current.position, desired.position)) then
    claims[#claims + 1] = 'ref.position'
  end
  if desired.rotation ~= nil and not sameRotation(current.rotation, desired.rotation) then
    claims[#claims + 1] = 'ref.rotation'
  end
  return claims
end

local function baselineFor(patch, state)
  local baseline = {}
  if patch.enabled ~= nil then baseline.enabled = state.enabled end
  if patch.owner ~= nil then baseline.owner = clone(state.owner) or {clear = true} end
  if patch.scale ~= nil then baseline.scale = state.scale end
  if patch.position ~= nil or patch.relocate ~= nil then
    baseline.cell = clone(state.cell)
  end
  return baseline
end

local function appendUniqueCell(list, cellKey)
  if type(cellKey) ~= 'string' or cellKey == '' then return end
  local key = cellKey:lower()
  for i = 1, #list do if list[i] == key then return end end
  list[#list + 1] = key
end

local function ensureDoorOriginPersisted(target, starting, ctx)
  if starting.typeName ~= 'Door' or ctx.ledger == nil then return nil end
  local cellKey = starting.cell and (starting.cell.key or starting.cell.id)
  if type(cellKey) ~= 'string' or starting.position == nil or starting.rotation == nil then
    return nil
  end
  local origin = {
    cellId = cellKey:lower(),
    position = clone(starting.position),
    rotation = clone(starting.rotation),
  }
  local existing = ctx.ledger:getRef(ctx.targetId)
  if existing == nil then
    ctx.ledger:putRef({
      kind = 'ref',
      id = ctx.targetId,
      objectId = ctx.targetFacts and ctx.targetFacts.objectId or ctx.targetId,
      recordId = ctx.targetFacts and ctx.targetFacts.recordId,
      typeName = 'Door',
      cellKey = origin.cellId,
      origin = origin,
    })
  elseif existing.origin == nil then
    existing.origin = origin
    ctx.ledger:putRef(existing)
  else
    return existing.origin
  end
  return origin
end

function M.matchesTarget(program, _target, facts)
  local patch = resolveEffectivePatch(program, facts)
  return patch ~= nil and next(patch) ~= nil
end

function M.capture(program, target, ctx)
  local patch, patchErr = resolveEffectivePatch(program, ctx.targetFacts)
  if patch == nil then return nil, patchErr end
  if next(patch) == nil then return {noop = true, patch = {}, baseline = {}}, nil end
  local state, stateErr = ctx.refOps.read(target)
  if state == nil then return nil, stateErr end
  local starting = {}
  local recoveryCells = {}
  if touchesTransform(patch) then
    local startErr
    starting, startErr = ctx.refOps.readStarting(target, ctx.ledger, ctx.targetId)
    if starting == nil then return nil, startErr end
    -- For generated outputs that have no startingCell/startingPosition, use current transform.
    if starting.cell == nil then starting.cell = state.cell end
    if starting.position == nil then starting.position = state.position end
    if starting.rotation == nil then starting.rotation = state.rotation end
    ensureDoorOriginPersisted(target, starting, ctx)
    local cells, recErr = recovery_locations.forTransform(starting, patch)
    if recErr ~= nil then return nil, recErr end
    recoveryCells = cells or {}
    appendUniqueCell(recoveryCells, recovery_locations.cellAt(state.cell, state.position))
  end
  return {
    patch = patch,
    baseline = baselineFor(patch, state),
    starting = touchesTransform(patch) and {
      cell = clone(starting.cell),
      position = clone(starting.position),
      rotation = clone(starting.rotation),
      typeName = starting.typeName,
    } or nil,
    recoveryCells = recoveryCells,
  }, nil
end

function M.prepareTransition(nextProgram, prevToken, target, ctx)
  local nextToken, err = M.capture(nextProgram, target, ctx)
  if nextToken == nil then return nil, err end
  local prevBase = prevToken and prevToken.baseline or {}
  local nextBase = nextToken.baseline or {}
  for _, key in ipairs({'enabled', 'owner', 'scale'}) do
    if prevBase[key] ~= nil and nextBase[key] ~= nil then
      nextBase[key] = clone(prevBase[key])
    end
  end
  if prevToken and prevToken.starting ~= nil and nextToken.starting ~= nil then
    nextToken.starting = clone(prevToken.starting)
  end
  return nextToken, nil
end

local function readStartingForOp(token, target, patch, ctx)
  if not touchesTransform(patch) then return {}, nil end
  local starting, err = ctx.refOps.readStarting(target, ctx.ledger, ctx.targetId)
  if starting == nil then
    if token.starting ~= nil then return token.starting, nil end
    return nil, err
  end
  if starting.cell == nil and token.starting then starting.cell = token.starting.cell end
  if starting.position == nil and token.starting then starting.position = token.starting.position end
  if starting.rotation == nil and token.starting then starting.rotation = token.starting.rotation end
  return starting, nil
end

local function isTransientTeleportError(err)
  local msg = tostring(err or '')
  return msg == 'ref_teleport_busy'
    or msg:find('already in the process of teleporting', 1, true) ~= nil
    or msg:find('Object is removed', 1, true) ~= nil
end

function M.apply(_program, target, token, ctx)
  if token == nil or token.noop or next(token.patch or {}) == nil then
    return {status = 'noop', changedClaims = {}}
  end
  local patch, baseline = token.patch, token.baseline
  local current, readErr = ctx.refOps.read(target)
  if current == nil then return {status = 'failed', changedClaims = {}, message = tostring(readErr)} end
  local starting, startErr = readStartingForOp(token, target, patch, ctx)
  if starting == nil then return {status = 'failed', changedClaims = {}, message = tostring(startErr)} end

  local changed, seen = {}, {}
  local function mark(c) if not seen[c] then seen[c] = true; changed[#changed + 1] = c end end
  local recoveryCells = clone(token.recoveryCells) or {}

  if patch.owner ~= nil and not plain_data.equalValidated(current.owner or {clear = true}, patch.owner) then
    local ok, err = ctx.refOps.setOwner(target, patch.owner)
    if not ok then return {status = 'failed', changedClaims = changed, message = tostring(err)} end
    mark('ref.owner')
  end
  if patch.scale ~= nil then
    local desired = patch.scale.mode == 'scaleBy' and (baseline.scale * patch.scale.value) or patch.scale.value
    if current.scale ~= desired then
      local ok, err = ctx.refOps.setScale(target, desired)
      if not ok then return {status = 'failed', changedClaims = changed, message = tostring(err)} end
      mark('ref.scale')
    end
  end
  local dest = desiredTransform(patch, starting, current)
  if dest ~= nil then
    local claims = transformClaims(current, dest, patch)
    if #claims > 0 then
      appendUniqueCell(recoveryCells, recovery_locations.cellAt(current.cell, current.position))
      appendUniqueCell(recoveryCells, recovery_locations.cellAt(dest.cell, dest.position))
      local ok, err = ctx.refOps.teleport(target, dest)
      if not ok then
        if isTransientTeleportError(err) then
          return {
            status = 'pending',
            changedClaims = changed,
            recoveryCells = #recoveryCells > 0 and recoveryCells or nil,
            pending = {phase = 'retry-apply', nextFrame = ctx.frame + 1},
          }
        end
        return {status = 'failed', changedClaims = changed, message = tostring(err)}
      end
      for i = 1, #claims do mark(claims[i]) end
    end
  end
  if patch.enabled ~= nil and current.enabled ~= (patch.enabled == true) then
    local ok, err = ctx.refOps.setEnabled(target, patch.enabled == true)
    if not ok then return {status = 'failed', changedClaims = changed, message = tostring(err)} end
    mark('ref.enabled')
  end

  table.sort(changed)
  return {
    status = #changed > 0 and 'applied' or 'noop',
    changedClaims = changed,
    recoveryCells = #recoveryCells > 0 and recoveryCells or nil,
  }
end

function M.advance(pending, target, ctx)
  if pending and pending.phase == 'retry-apply' then
    return M.apply(nil, target, ctx.token, ctx)
  end
  return {status = 'applied', changedClaims = {}}
end

function M.reassert(_program, target, token, ctx)
  if token == nil or not touchesTransform(token.patch) then
    return {status = 'noop', changedClaims = {}}
  end
  local patch = token.patch
  local current, readErr = ctx.refOps.read(target)
  if current == nil then return {status = 'failed', changedClaims = {}, message = tostring(readErr)} end
  local starting, startErr = readStartingForOp(token, target, patch, ctx)
  if starting == nil then return {status = 'failed', changedClaims = {}, message = tostring(startErr)} end
  local dest = desiredTransform(patch, starting, current)
  local claims = transformClaims(current, dest, patch)
  if #claims == 0 then return {status = 'noop', changedClaims = {}} end
  local recoveryCells = clone(token.recoveryCells) or {}
  appendUniqueCell(recoveryCells, recovery_locations.cellAt(current.cell, current.position))
  appendUniqueCell(recoveryCells, recovery_locations.cellAt(dest.cell, dest.position))
  local ok, err = ctx.refOps.teleport(target, dest)
  if not ok then return {status = 'failed', changedClaims = {}, message = tostring(err)} end
  table.sort(claims)
  return {
    status = 'applied',
    changedClaims = claims,
    recoveryCells = recoveryCells,
  }
end

function M.revert(token, target, ctx)
  if token == nil or token.noop or next(token.patch or {}) == nil then
    return {status = 'noop', changedClaims = {}}
  end
  local patch, baseline = token.patch, token.baseline or {}
  local current, readErr = ctx.refOps.read(target)
  if current == nil then return {status = 'failed', changedClaims = {}, message = tostring(readErr)} end
  local starting, startErr = readStartingForOp(token, target, patch, ctx)
  if starting == nil then return {status = 'failed', changedClaims = {}, message = tostring(startErr)} end

  local changed, seen = {}, {}
  local function mark(c) if not seen[c] then seen[c] = true; changed[#changed + 1] = c end end

  if baseline.owner ~= nil and not plain_data.equalValidated(current.owner or {clear = true}, baseline.owner) then
    local ok, err = ctx.refOps.setOwner(target, baseline.owner)
    if not ok then return {status = 'failed', changedClaims = changed, message = tostring(err)} end
    mark('ref.owner')
  end
  if baseline.scale ~= nil and current.scale ~= baseline.scale then
    local ok, err = ctx.refOps.setScale(target, baseline.scale)
    if not ok then return {status = 'failed', changedClaims = changed, message = tostring(err)} end
    mark('ref.scale')
  end
  local hasPos = patch.position ~= nil or patch.relocate ~= nil
  local hasRot = patch.rotation ~= nil or (patch.relocate and patch.relocate.rotation ~= nil)
  if hasPos or hasRot then
    local dest = {
      cell = clone(hasPos and starting.cell or current.cell),
      position = clone(hasPos and starting.position or current.position),
      rotation = hasRot and clone(starting.rotation) or nil,
    }
    local claims = {}
    if hasPos and (not sameCell(current, dest) or not samePosition(current.position, dest.position)) then
      claims[#claims + 1] = 'ref.position'
    end
    if dest.rotation ~= nil and not sameRotation(current.rotation, dest.rotation) then
      claims[#claims + 1] = 'ref.rotation'
    end
    if #claims > 0 then
      local ok, err = ctx.refOps.teleport(target, dest)
      if not ok then
        if isTransientTeleportError(err) then
          return {
            status = 'pending',
            changedClaims = changed,
            pending = {phase = 'await-target', nextFrame = ctx.frame + 1},
          }
        end
        return {status = 'failed', changedClaims = changed, message = tostring(err)}
      end
      for i = 1, #claims do mark(claims[i]) end
    end
  end
  if baseline.enabled ~= nil and current.enabled ~= baseline.enabled then
    local ok, err = ctx.refOps.setEnabled(target, baseline.enabled)
    if not ok then
      if isTransientTeleportError(err) then
        return {
          status = 'pending',
          changedClaims = changed,
          pending = {phase = 'await-target', nextFrame = ctx.frame + 1},
        }
      end
      return {status = 'failed', changedClaims = changed, message = tostring(err)}
    end
    mark('ref.enabled')
  end

  table.sort(changed)
  return {
    status = #changed > 0 and 'applied' or 'noop',
    changedClaims = changed,
  }
end

return M
