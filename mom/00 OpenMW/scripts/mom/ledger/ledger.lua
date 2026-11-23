-- Schema v1 single-threaded in-memory ledger with synchronous O(1) indexes.
-- OpenMW persists Lua script state strictly between onUpdate ticks via
-- onSave/onLoad, so the in-memory document IS the durable source of truth.
local M = {
  SCHEMA_VERSION = 1,
}

local compactor = require('scripts.mom.ledger.compactor')
local plain_data = require('scripts.mom.contracts.plain_data')
local strings = require('scripts.mom.common.strings')

local nonEmpty = strings.isNonEmpty

local VALID_STATES = {
  applied = true,
  pending = true,
  reverting = true,
  retired = true,
}

local VALID_LIFECYCLES = {
  static = true,
  state = true,
}

local VALID_DURABILITIES = {
  reversible = true,
  permanent = true,
}

local function emptyDoc()
  return {
    schemaVersion = M.SCHEMA_VERSION,
    clock = {frame = 0, seq = 0},
    manifestHash = nil,
    staticScans = {},
    ops = {},
    refs = {},
    variants = {},
  }
end

local function emptyIndexes()
  return {
    bySemanticId = {},      -- semanticId -> opId
    byProducerId = {},      -- producerId -> opId
    claimsByLifecycle = {   -- lifecycle -> targetId -> { [claimKey] = opId }
      static = {},
      state = {},
    },
    opsByTarget = {},       -- targetId -> { [opId] = true }
    opsByParent = {},       -- parentOpId -> { [opId] = true }
    opsByOwner = {},        -- ownerId -> { [opId] = true }
    opsByAction = {},       -- actionId -> { [opId] = true }
    opsByCell = {},         -- cellKey -> { [opId] = true }
    opsByLifecycle = {static = {}, state = {}},
    pendingOps = {},        -- opId -> nextFrame (number)
    positionRecovery = {},  -- targetId -> { [opId] = recoveryCells }
    outputByObjectId = {},  -- objectId -> refId
    opCount = 0,
  }
end

local function addSet(map, key, value)
  if key == nil then return end
  local bucket = map[key]
  if bucket == nil then
    bucket = {}
    map[key] = bucket
  end
  bucket[value] = true
end

local function removeSet(map, key, value)
  if key == nil then return end
  local bucket = map[key]
  if bucket == nil then return end
  bucket[value] = nil
  if next(bucket) == nil then map[key] = nil end
end

local function occupiesClaims(state)
  return state == 'applied' or state == 'pending' or state == 'reverting'
end

local function indexOp(idx, op)
  local id = op.id
  idx.bySemanticId[op.semanticId] = id
  idx.byProducerId[op.producerId or id] = id
  addSet(idx.opsByTarget, op.targetId, id)
  addSet(idx.opsByParent, op.parentOpId, id)
  addSet(idx.opsByOwner, op.ownerId, id)
  addSet(idx.opsByAction, op.actionId, id)
  addSet(idx.opsByCell, op.cellKey, id)
  if op.lifecycle and idx.opsByLifecycle[op.lifecycle] then
    idx.opsByLifecycle[op.lifecycle][id] = true
  end
  if occupiesClaims(op.state) and op.lifecycle and idx.claimsByLifecycle[op.lifecycle] then
    local claimsRoot = idx.claimsByLifecycle[op.lifecycle]
    local byClaim = claimsRoot[op.targetId]
    for i = 1, #(op.claims or {}) do
      local key = op.claims[i]
      if key ~= 'output.existence' then
        if byClaim == nil then
          byClaim = {}
          claimsRoot[op.targetId] = byClaim
        end
        byClaim[key] = id
      end
    end
  end
  if op.state == 'pending' or op.state == 'reverting' then
    local nextFrame = type(op.pending) == 'table' and tonumber(op.pending.nextFrame) or 0
    idx.pendingOps[id] = nextFrame
  end
  if type(op.recoveryCells) == 'table' and #op.recoveryCells > 0 then
    local byOp = idx.positionRecovery[op.targetId]
    if byOp == nil then
      byOp = {}
      idx.positionRecovery[op.targetId] = byOp
    end
    byOp[id] = op.recoveryCells
  end
  idx.opCount = idx.opCount + 1
end

local function unindexOp(idx, op)
  local id = op.id
  if idx.bySemanticId[op.semanticId] == id then
    idx.bySemanticId[op.semanticId] = nil
  end
  if idx.byProducerId[op.producerId or id] == id then
    idx.byProducerId[op.producerId or id] = nil
  end
  removeSet(idx.opsByTarget, op.targetId, id)
  removeSet(idx.opsByParent, op.parentOpId, id)
  removeSet(idx.opsByOwner, op.ownerId, id)
  removeSet(idx.opsByAction, op.actionId, id)
  removeSet(idx.opsByCell, op.cellKey, id)
  if op.lifecycle and idx.opsByLifecycle[op.lifecycle] then
    idx.opsByLifecycle[op.lifecycle][id] = nil
  end
  local claimsRoot = op.lifecycle and idx.claimsByLifecycle[op.lifecycle] or nil
  local byClaim = claimsRoot and claimsRoot[op.targetId] or nil
  if byClaim ~= nil then
    for i = 1, #(op.claims or {}) do
      if byClaim[op.claims[i]] == id then
        byClaim[op.claims[i]] = nil
      end
    end
    if next(byClaim) == nil then
      claimsRoot[op.targetId] = nil
    end
  end
  idx.pendingOps[id] = nil
  local byOp = idx.positionRecovery[op.targetId]
  if byOp ~= nil then
    byOp[id] = nil
    if next(byOp) == nil then
      idx.positionRecovery[op.targetId] = nil
    end
  end
  idx.opCount = math.max(0, idx.opCount - 1)
end

local function indexRef(idx, ref)
  if ref.kind == 'output' and nonEmpty(ref.objectId) then
    idx.outputByObjectId[ref.objectId] = ref.id
  end
end

local function unindexRef(idx, ref)
  if ref.kind == 'output' and nonEmpty(ref.objectId)
      and idx.outputByObjectId[ref.objectId] == ref.id then
    idx.outputByObjectId[ref.objectId] = nil
  end
end

local function validateOp(op, key, errors)
  if type(op) ~= 'table' then
    errors[#errors + 1] = 'ops.' .. tostring(key) .. ': expected table'
    return false
  end
  if op.id ~= key or not nonEmpty(op.id) then
    errors[#errors + 1] = 'ops.' .. tostring(key) .. '.id: must match key'
  end
  if not nonEmpty(op.semanticId) then
    errors[#errors + 1] = 'ops.' .. tostring(key) .. '.semanticId: required'
  end
  if not nonEmpty(op.family) or not nonEmpty(op.actionId) or not nonEmpty(op.targetId) then
    errors[#errors + 1] = 'ops.' .. tostring(key) .. ': family, actionId, targetId required'
  end
  if not VALID_LIFECYCLES[op.lifecycle] then
    errors[#errors + 1] = 'ops.' .. tostring(key) .. '.lifecycle: invalid'
  end
  if not VALID_DURABILITIES[op.durability] then
    errors[#errors + 1] = 'ops.' .. tostring(key) .. '.durability: invalid'
  end
  if not VALID_STATES[op.state] then
    errors[#errors + 1] = 'ops.' .. tostring(key) .. '.state: invalid'
  end
  if type(op.claims) ~= 'table' then
    errors[#errors + 1] = 'ops.' .. tostring(key) .. '.claims: expected array'
  end
  for _, vField in ipairs({'familyAbiVersion', 'behaviorVersion', 'programVersion', 'revertTokenVersion'}) do
    local v = op[vField]
    if v ~= nil and (type(v) ~= 'number' or v < 0 or v % 1 ~= 0) then
      errors[#errors + 1] = 'ops.' .. tostring(key) .. '.' .. vField .. ': expected non-negative integer'
    end
  end
  return #errors == 0
end

local function validateDoc(doc)
  local errors = {}
  if type(doc) ~= 'table' then
    return nil, {'ledger must be a table'}
  end
  if doc.schemaVersion ~= M.SCHEMA_VERSION then
    return nil, {'unsupported ledger schemaVersion: ' .. tostring(doc.schemaVersion)}
  end
  local plain, plainErrors = plain_data.validate(doc, {path = 'ledger'})
  if not plain then return nil, plainErrors end
  if type(doc.clock) ~= 'table'
      or type(doc.clock.frame) ~= 'number' or doc.clock.frame < 0 or doc.clock.frame % 1 ~= 0
      or type(doc.clock.seq) ~= 'number' or doc.clock.seq < 0 or doc.clock.seq % 1 ~= 0 then
    errors[#errors + 1] = 'ledger.clock: invalid frame or seq'
  end
  for _, field in ipairs({'staticScans', 'ops', 'refs', 'variants'}) do
    if type(doc[field]) ~= 'table' then
      errors[#errors + 1] = 'ledger.' .. field .. ': expected table'
    end
  end
  if #errors > 0 then return nil, errors end
  for key, op in pairs(doc.ops) do
    validateOp(op, key, errors)
  end
  for key, ref in pairs(doc.refs) do
    if type(ref) ~= 'table' or ref.id ~= key or (ref.kind ~= 'ref' and ref.kind ~= 'output') then
      errors[#errors + 1] = 'refs.' .. tostring(key) .. ': invalid ref entry'
    end
  end
  if #errors > 0 then return nil, errors end
  return true, nil
end

local Ledger = {}
Ledger.__index = Ledger

local function wrap(doc, dirty)
  local idx = emptyIndexes()
  for _, op in pairs(doc.ops) do indexOp(idx, op) end
  for _, ref in pairs(doc.refs) do indexRef(idx, ref) end
  return setmetatable({
    doc = doc,
    idx = idx,
    dirty = dirty == true,
  }, Ledger)
end

function M.new()
  return wrap(emptyDoc(), false)
end

-- Decodes an OpenMW onLoad payload in one pass without full-ledger cloning.
-- Pre-release schemaVersion 0 saves reset cleanly to schemaVersion 1.
-- Malformed or future-version payloads are quarantined cleanly.
function M.decode(payload)
  if payload == nil then
    return M.new(), {status = 'new'}
  end
  if type(payload) ~= 'table' then
    return nil, {
      status = 'quarantined',
      code = 'saved_state_invalid',
      message = 'Saved MOM state is not a table',
      raw = payload,
    }
  end
  if payload.schemaVersion == 0 then
    return M.new(), {
      status = 'reset',
      code = 'schema_v0_reset',
      message = 'Pre-release schema v0 ledger reset to schema v1',
    }
  end
  local valid, errors = validateDoc(payload)
  if not valid then
    return nil, {
      status = 'quarantined',
      code = 'saved_state_invalid',
      message = table.concat(errors or {'invalid saved ledger'}, ' | '),
      errors = errors,
      raw = payload,
    }
  end
  return wrap(payload), {status = 'loaded'}
end

function Ledger:nextOpId()
  local clock = self.doc.clock
  clock.seq = clock.seq + 1
  return 'op:' .. tostring(clock.seq)
end

function Ledger:setFrame(frame)
  if type(frame) == 'number' and frame >= self.doc.clock.frame then
    self.doc.clock.frame = frame
  end
end

function Ledger:frame()
  return self.doc.clock.frame
end

function Ledger:manifestHash()
  return self.doc.manifestHash
end

function Ledger:setManifestHash(hash)
  if self.doc.manifestHash ~= hash then
    self.doc.manifestHash = hash
    self.dirty = true
  end
end

function Ledger:getOp(opId)
  return self.doc.ops[opId]
end

function Ledger:getOpBySemanticId(semanticId)
  local id = self.idx.bySemanticId[semanticId]
  return id ~= nil and self.doc.ops[id] or nil
end

function Ledger:getOpByProducerId(producerId)
  local id = self.idx.byProducerId[producerId]
  return id ~= nil and self.doc.ops[id] or nil
end

function Ledger:putOp(op)
  assert(type(op) == 'table' and nonEmpty(op.id), 'putOp requires op.id')
  local existing = self.doc.ops[op.id]
  if existing ~= nil then
    unindexOp(self.idx, existing)
  end
  op.producerId = op.producerId or op.id
  self.doc.ops[op.id] = op
  indexOp(self.idx, op)
  self.dirty = true
  return op
end

function Ledger:updateOp(opId, patch)
  local op = self.doc.ops[opId]
  if op == nil then return nil end
  unindexOp(self.idx, op)
  for key, value in pairs(patch) do
    if value == M.NIL then
      op[key] = nil
    else
      op[key] = value
    end
  end
  indexOp(self.idx, op)
  self.dirty = true
  return op
end

function Ledger:deleteOp(opId)
  local op = self.doc.ops[opId]
  if op == nil then return false end
  unindexOp(self.idx, op)
  self.doc.ops[opId] = nil
  self.dirty = true
  return true
end

-- Sentinel for clearing fields in updateOp.
M.NIL = {}

function Ledger:claimOwner(lifecycle, targetId, claimKey)
  local claimsRoot = self.idx.claimsByLifecycle[lifecycle]
  local byClaim = claimsRoot and claimsRoot[targetId] or nil
  return byClaim and byClaim[claimKey] or nil
end

function Ledger:claimsForLifecycle(lifecycle)
  return self.idx.claimsByLifecycle[lifecycle] or {}
end

function Ledger:opsForTarget(targetId)
  return self.idx.opsByTarget[targetId]
end

function Ledger:opsForParent(parentOpId)
  return self.idx.opsByParent[parentOpId]
end

function Ledger:opsForOwner(ownerId)
  return self.idx.opsByOwner[ownerId]
end

function Ledger:opsForCell(cellKey)
  return self.idx.opsByCell[cellKey]
end

function Ledger:opsForLifecycle(lifecycle)
  return self.idx.opsByLifecycle[lifecycle]
end

function Ledger:pendingOps()
  return self.idx.pendingOps
end

function Ledger:recoveryCellsForTarget(targetId)
  local byOp = self.idx.positionRecovery[targetId]
  if byOp == nil then return nil end
  local out, seen = {}, {}
  for _, cells in pairs(byOp) do
    for i = 1, #cells do
      local key = cells[i]
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = key
      end
    end
  end
  table.sort(out)
  return out
end

function Ledger:getRef(refId)
  return self.doc.refs[refId]
end

function Ledger:getOutputIdByObjectId(objectId)
  return self.idx.outputByObjectId[objectId]
end

function Ledger:putRef(ref)
  assert(type(ref) == 'table' and nonEmpty(ref.id), 'putRef requires ref.id')
  local existing = self.doc.refs[ref.id]
  if existing ~= nil then unindexRef(self.idx, existing) end
  self.doc.refs[ref.id] = ref
  indexRef(self.idx, ref)
  self.dirty = true
  return ref
end

function Ledger:deleteRef(refId)
  local existing = self.doc.refs[refId]
  if existing == nil then return false end
  unindexRef(self.idx, existing)
  self.doc.refs[refId] = nil
  self.dirty = true
  return true
end

function Ledger:getStaticScan(cellKey)
  return self.doc.staticScans[cellKey]
end

function Ledger:setStaticScan(cellKey, entry)
  self.doc.staticScans[cellKey] = entry
  self.dirty = true
end

function Ledger:getVariant(variantKey)
  return self.doc.variants[variantKey]
end

function Ledger:setVariant(variantKey, entry)
  self.doc.variants[variantKey] = entry
  self.dirty = true
end

-- Wakes any reverting ops backed off in `await-target` so newly loaded cells
-- trigger deferred cleanup on the very next tick.
function Ledger:wakePendingReverts()
  local woke = 0
  for opId in pairs(self.idx.pendingOps) do
    local op = self.doc.ops[opId]
    if op ~= nil and op.state == 'reverting'
        and type(op.pending) == 'table' and op.pending.phase == 'await-target' then
      op.pending.nextFrame = 0
      op.pending.delay = 1
      self.idx.pendingOps[opId] = 0
      woke = woke + 1
    end
  end
  return woke
end

function Ledger:opCount()
  return self.idx.opCount
end

function Ledger:pendingCount()
  local count = 0
  for _ in pairs(self.idx.pendingOps) do count = count + 1 end
  return count
end

function Ledger:audit()
  local valid, errors = validateDoc(self.doc)
  if not valid then return nil, errors end
  local counted = 0
  for id, op in pairs(self.doc.ops) do
    counted = counted + 1
    if self.idx.bySemanticId[op.semanticId] ~= id then
      return nil, {'ledger index mismatch for semanticId ' .. tostring(op.semanticId)}
    end
  end
  if counted ~= self.idx.opCount then
    return nil, {'ledger opCount index mismatch'}
  end
  return true, nil
end

function Ledger:save()
  if self.dirty then
    compactor.compact(self)
    self.dirty = false
  end
  return self.doc, {status = 'saved'}
end

return M
