-- OpenMW placement & generated-record adapter for place_ref.
-- Caches created model-variant records directly in ledger.variants (no full
-- record-catalog baseline scan).
local M = {}

local canonical = require('scripts.mom.contracts.canonical')
local model_path = require('scripts.mom.contracts.model_path')
local openmw_api = require('scripts.mom.openmw.api')
local strings = require('scripts.mom.common.strings')

local call = openmw_api.call
local property = openmw_api.property
local nonEmpty = strings.isNonEmpty

function M.variantKey(typeName, sourceRecordId, targetModel)
  return 'var:' .. canonical.assertHash({
    typeName = typeName,
    sourceRecordId = tostring(sourceRecordId):lower(),
    targetModel = targetModel,
  }):sub(7)
end

function M.new(deps, refOps, inventoryOps)
  deps = deps or {}
  local world = openmw_api.dependency(deps, 'world', 'openmw.world')
  local types = openmw_api.dependency(deps, 'types', 'openmw.types')

  local ops = {}

  function ops.sourceRecordInfo(typeName, refOrRecordId)
    local ns = types and types[typeName]
    if not openmw_api.isNamespace(ns) or type(ns.record) ~= 'function' then
      return nil, 'record API unavailable for ' .. tostring(typeName)
    end
    local rec, err = call(ns.record, refOrRecordId)
    if rec == nil then return nil, err or 'record unavailable' end
    local id = property(rec, 'id')
    local rawModel = property(rec, 'model')
    local mwscript = property(rec, 'mwscript')
    local isRespawning = typeName == 'Container' and property(rec, 'isRespawning') == true or false
    return {
      record = rec,
      id = nonEmpty(id) and tostring(id):lower() or nil,
      model = type(rawModel) == 'string' and rawModel ~= '' and model_path.normalize(rawModel) or nil,
      mwscript = nonEmpty(mwscript) and tostring(mwscript) or nil,
      isRespawning = isRespawning,
    }, nil
  end

  function ops.creatureEligible(target)
    local actor = types and types.Actor
    if not openmw_api.isNamespace(actor) or type(actor.isDead) ~= 'function' then
      return nil, 'Actor.isDead API unavailable'
    end
    local dead, err = call(actor.isDead, target)
    if type(dead) ~= 'boolean' then return nil, err or 'creature death state unavailable' end
    if dead then return false, 'dead creature cannot be mesh-replaced' end
    local summonedBy, sErr = property(target, 'summonedBy')
    if sErr ~= nil then return nil, sErr end
    if summonedBy ~= nil then return false, 'summoned creature cannot be mesh-replaced' end
    return true, nil
  end

  function ops.ensureVariantRecord(typeName, sourceRef, sourceRecordId, targetModel, ledger)
    local key = M.variantKey(typeName, sourceRecordId, targetModel)
    local ns = types and types[typeName]
    if not openmw_api.isNamespace(ns) or type(ns.createRecordDraft) ~= 'function' then
      return nil, nil, 'createRecordDraft unavailable for ' .. tostring(typeName)
    end
    local cached = ledger and ledger:getVariant(key) or nil
    if cached ~= nil and nonEmpty(cached.recordId) then
      local existing = call(ns.record, cached.recordId)
      if existing ~= nil then
        return cached.recordId, key, nil
      end
    end
    local info, infoErr = ops.sourceRecordInfo(typeName, sourceRef)
    if info == nil then return nil, nil, infoErr end
    local draft, draftErr = call(ns.createRecordDraft, {
      template = info.record,
      model = targetModel,
    })
    if draft == nil then return nil, nil, draftErr or 'failed creating record draft' end
    local created, createErr = call(world.createRecord, draft)
    if created == nil then return nil, nil, createErr or 'failed creating variant record' end
    local recordId, idErr = property(created, 'id')
    if not nonEmpty(recordId) then
      return nil, nil, idErr or 'created variant record has no id'
    end
    recordId = tostring(recordId)
    if ledger ~= nil then
      ledger:setVariant(key, {
        recordId = recordId,
        typeName = typeName,
        sourceRecordId = tostring(sourceRecordId):lower(),
        targetModel = targetModel,
      })
    end
    return recordId, key, nil
  end

  -- Spawns an object, teleports to placement FIRST (OpenMW forbids mutating
  -- enabled/scale on an un-teleported object), applies scale & owner, and for
  -- Container placements resolves inventory and hides it until transfer completes.
  function ops.createObject(recordId, placement)
    local ref, createErr = call(world.createObject, recordId)
    if ref == nil then return nil, 'createObject(' .. tostring(recordId) .. '): ' .. tostring(createErr) end
    local function cleanup(step, reason)
      pcall(ref.remove, ref)
      return nil, step .. ': ' .. tostring(reason)
    end
    if placement.typeName == 'Container' then
      local inv, _, invErr = inventoryOps.getInventory(ref)
      if inv == nil then return cleanup('containerInv', invErr) end
      local okRes, resErr = inventoryOps.ensureResolved(inv)
      if not okRes then return cleanup('containerResolve', resErr) end
    end
    if placement.transferKind == 'container' then
      local okHide, hideErr = refOps.setEnabled(ref, false)
      if not okHide then return cleanup('hide', hideErr) end
    end
    local okTp, tpErr = refOps.teleport(ref, {
      cell = placement.cell,
      position = placement.position,
      rotation = placement.rotation,
    })
    if not okTp then return cleanup('teleport', tpErr) end
    if placement.scale ~= nil and placement.scale ~= 1 then
      local okSc, scErr = refOps.setScale(ref, placement.scale)
      if not okSc then return cleanup('scale', scErr) end
    end
    if placement.owner ~= nil then
      local okOwn, ownErr = refOps.setOwner(ref, placement.owner)
      if not okOwn then return cleanup('owner', ownErr) end
    end
    local objectId, idErr = property(ref, 'id')
    if not nonEmpty(objectId) then return cleanup('id', idErr or 'created object has no id') end
    return {ref = ref, objectId = tostring(objectId)}, nil
  end

  function ops.removeObject(ref)
    if ref == nil then return true, nil end
    local validFn = property(ref, 'isValid')
    if validFn == nil or call(validFn, ref) ~= true then return true, nil end
    local count = property(ref, 'count')
    if type(count) == 'number' and count <= 0 then return true, nil end
    local _, err = call(ref.remove, ref)
    if err ~= nil then return nil, err end
    return true, nil
  end

  return ops
end

return M
