-- Unit & stress tests for the schemaVersion=1 Ledger, Identity, and Compactor.
local M = {}

local compactor = require('scripts.mom.ledger.compactor')
local identity = require('scripts.mom.ledger.identity')
local ledger_api = require('scripts.mom.ledger.ledger')
local plain_data = require('scripts.mom.contracts.plain_data')
local test_support = require('pure.test_support')
local expect = test_support.expect

local function makeOp(id, opts)
  opts = opts or {}
  local actionId = opts.actionId or ('action:modify_ref:' .. id)
  local targetId = opts.targetId or ('content:000001:morrowind.esm')
  local parentOpId = opts.parentOpId
  return {
    id = id,
    producerId = id,
    semanticId = identity.semanticId(actionId, targetId, parentOpId),
    family = opts.family or 'modify_ref',
    actionId = actionId,
    ownerId = opts.ownerId,
    lifecycle = opts.lifecycle or 'static',
    durability = opts.durability or 'reversible',
    targetId = targetId,
    cellKey = opts.cellKey or 'balmora',
    parentOpId = parentOpId,
    depth = opts.depth or 0,
    state = opts.state or 'applied',
    priority = opts.priority or 0,
    specificity = opts.specificity or 0,
    order = opts.order or 1,
    claims = opts.claims or {'ref.enabled'},
    changedClaims = opts.changedClaims or {'ref.enabled'},
    token = opts.token or {enabled = true},
    pending = opts.pending,
    outputs = opts.outputs or {},
    recoveryCells = opts.recoveryCells,
    appliedAt = opts.appliedAt or 1,
  }
end

local function schemaV1RoundtripAndReset()
  local l = ledger_api.new()
  expect(l.doc.schemaVersion == 1, 'new ledger did not use schemaVersion 1')
  l:setManifestHash('mom64:abc')
  l:setFrame(42)

  local opId = l:nextOpId()
  local op = l:putOp(makeOp(opId, {
    claims = {'ref.enabled', 'output.existence'},
    outputs = {'output:1'},
  }))
  l:putRef({
    kind = 'output',
    id = 'output:1',
    objectId = '@0x10',
    recordId = 'lamp_01',
    actualRecordId = 'lamp_01',
    typeName = 'Light',
    cellKey = 'balmora',
    parentTargetId = op.targetId,
    producerId = opId,
    slot = 'a:1',
    recoveryCells = {'balmora, guild of mages'},
  })
  l:setVariant('Static:lamp_01:meshes/x.nif', {recordId = 'generated:1', model = 'meshes/x.nif'})
  l:setStaticScan('balmora', {planHash = 'p1', manifestHash = 'mom64:abc', completedFrame = 42})

  local okAudit, auditErr = l:audit()
  expect(okAudit == true and auditErr == nil, 'valid ledger failed audit: ' .. tostring(auditErr))

  local saved = l:save()
  expect(plain_data.validate(saved) == true, 'saved ledger is not plain data')
  local reloaded, loadInfo = ledger_api.decode(plain_data.cloneValidated(saved))
  expect(reloaded ~= nil and loadInfo.status == 'loaded', 'v1 save did not reload cleanly')
  expect(reloaded:opCount() == 1 and reloaded:frame() == 42
      and reloaded:getOpBySemanticId(op.semanticId) ~= nil
      and reloaded:getOutputIdByObjectId('@0x10') == 'output:1'
      and reloaded:getVariant('Static:lamp_01:meshes/x.nif').recordId == 'generated:1'
      and reloaded:getStaticScan('balmora').planHash == 'p1',
    'reloaded ledger lost ops, indexes, variants, or static scans')

  -- Pre-release schemaVersion=0 save cleanly resets to empty v1.
  local resetLedger, resetInfo = ledger_api.decode({schemaVersion = 0, operations = {}})
  expect(resetLedger ~= nil and resetLedger.doc.schemaVersion == 1
      and resetLedger:opCount() == 0 and resetInfo.status == 'reset',
    'legacy schemaVersion 0 save did not cleanly reset to v1')
end

local function lifecycleClaimsAndExistenceExclusion()
  local l = ledger_api.new()
  local targetId = 'content:000010:morrowind.esm'
  local staticId = l:nextOpId()
  l:putOp(makeOp(staticId, {
    lifecycle = 'static',
    targetId = targetId,
    claims = {'ref.enabled', 'output.existence'},
  }))
  local stateId = l:nextOpId()
  l:putOp(makeOp(stateId, {
    lifecycle = 'state',
    ownerId = 'owner:1',
    targetId = targetId,
    claims = {'ref.enabled', 'output.existence'},
  }))
  expect(l:claimOwner('static', targetId, 'ref.enabled') == staticId
      and l:claimOwner('state', targetId, 'ref.enabled') == stateId,
    'static and state claim indexes did not remain isolated')
  expect(l:claimOwner('static', targetId, 'output.existence') == nil
      and l:claimOwner('state', targetId, 'output.existence') == nil,
    'output.existence must never lock exclusive claim ownership')

  l:deleteOp(stateId)
  expect(l:claimOwner('state', targetId, 'ref.enabled') == nil
      and l:claimOwner('static', targetId, 'ref.enabled') == staticId,
    'deleting state op disturbed static claim ownership')
end

local function pendingParentAndRecoveryIndexes()
  local l = ledger_api.new()
  local parentId = l:nextOpId()
  l:putOp(makeOp(parentId, {
    state = 'pending',
    pending = {phase = 'confirm-outputs', nextFrame = 5},
    outputs = {'output:parent'},
  }))
  expect(l:pendingCount() == 1 and l:pendingOps()[parentId] == 5,
    'pending index missed pending op')

  local childId = l:nextOpId()
  l:putOp(makeOp(childId, {
    targetId = 'output:parent',
    parentOpId = parentId,
    depth = 1,
    recoveryCells = {'balmora, guild of mages'},
  }))
  expect(l:opsForParent(parentId)[childId] == true,
    'parent-child index missed child op')
  local cells = l:recoveryCellsForTarget('output:parent')
  expect(#cells == 1 and cells[1] == 'balmora, guild of mages',
    'recovery cell lookup missed child op recovery cell')

  l:updateOp(parentId, {state = 'applied', pending = ledger_api.NIL})
  expect(l:pendingCount() == 0 and l:getOp(parentId).pending == nil,
    'clearing pending with ledger.NIL did not remove op from pending index')
end

local function compactorPrunesDeadRefsVariantsAndScans()
  local l = ledger_api.new()
  local liveId = l:nextOpId()
  l:putOp(makeOp(liveId, {actionId = 'act:live', outputs = {'output:live'}}))
  l:putRef({
    kind = 'output', id = 'output:live', objectId = '@0x1',
    producerId = liveId, variantKey = 'var:live', cellKey = 'balmora',
  })
  l:putRef({
    kind = 'output', id = 'output:orphan', objectId = '@0x2',
    producerId = 'op:deleted', variantKey = 'var:dead', cellKey = 'balmora',
  })
  l:setManifestHash('mh:current')
  l:setVariant('var:live', {recordId = 'gen:1'})
  l:setVariant('var:dead', {recordId = 'gen:2'})
  l:setStaticScan('cell_keep', {planHash = 'p1', manifestHash = 'mh:current'})
  l:setStaticScan('cell_old', {planHash = 'p0', manifestHash = 'mh:stale'})

  local stats = compactor.compact(l)
  expect(stats.removedRefs == 1 and stats.removedScans == 1,
    'compactor did not prune dead orphan ref and stale scan')
  expect(l:getRef('output:live') ~= nil and l:getRef('output:orphan') == nil
      and l:getVariant('var:live') ~= nil
      and l:getStaticScan('cell_keep') ~= nil and l:getStaticScan('cell_old') == nil,
    'compactor removed live state or left dead state behind')
end

local function stressLedger1000OpsRoundtrip()
  local l = ledger_api.new()
  l:setManifestHash('mom64:stress')
  for i = 1, 1000 do
    local opId = l:nextOpId()
    l:putOp(makeOp(opId, {
      actionId = 'act:' .. tostring(i % 20),
      targetId = string.format('content:%06x:morrowind.esm', i),
      lifecycle = (i % 2 == 0) and 'state' or 'static',
      ownerId = (i % 2 == 0) and ('owner:' .. tostring(i % 10)) or nil,
      claims = {'ref.enabled', 'ref.scale'},
      appliedAt = i,
    }))
  end
  expect(l:opCount() == 1000 and l:audit() == true, '1000-op ledger failed audit')
  local saved = l:save()
  local reloaded = assert(ledger_api.decode(plain_data.cloneValidated(saved)))
  expect(reloaded:opCount() == 1000 and reloaded:audit() == true,
    'reloaded 1000-op ledger failed audit')
  for i = 1, 500 do
    reloaded:deleteOp('op:' .. tostring(i))
  end
  expect(reloaded:opCount() == 500 and reloaded:audit() == true,
    'post-delete 500-op ledger failed audit')
end

local function dirtySaveCompactionAndWakePendingReverts()
  local l = ledger_api.new()
  l:setManifestHash('mh:live')
  l:setStaticScan('cell_old', {planHash = 'p0', manifestHash = 'mh:stale'})
  expect(l.dirty == true, 'setStaticScan did not mark ledger dirty')
  l:save()
  expect(l.dirty == false and l:getStaticScan('cell_old') == nil,
    'first dirty save did not compact stale scan and clear dirty flag')

  -- Mutating doc directly without setting dirty demonstrates clean save skips compaction.
  l.doc.staticScans.cell_probe = {planHash = 'p0', manifestHash = 'mh:stale'}
  l:save()
  expect(l.doc.staticScans.cell_probe ~= nil, 'clean save unnecessarily re-ran compactor')
  l:setStaticScan('cell_keep', {planHash = 'p1', manifestHash = 'mh:live'})
  l:save()
  expect(l.doc.staticScans.cell_probe == nil and l:getStaticScan('cell_keep') ~= nil,
    'subsequent dirty save did not compact stale scans')

  local revId = l:nextOpId()
  l:putOp(makeOp(revId, {
    state = 'reverting',
    pending = {phase = 'await-target', delay = 120, nextFrame = 500},
  }))
  expect(l:pendingOps()[revId] == 500, 'backed-off reverting op nextFrame mismatch')
  expect(l:wakePendingReverts() == 1 and l:pendingOps()[revId] == 0
      and l:getOp(revId).pending.delay == 1,
    'wakePendingReverts did not immediately wake await-target reverting op')
end

function M.run()
  return test_support.runCases('ledger v1', {
    {'schema v1 roundtrip and legacy v0 reset', schemaV1RoundtripAndReset},
    {'lifecycle claim isolation and output.existence exclusion', lifecycleClaimsAndExistenceExclusion},
    {'pending parent and recovery cell indexes', pendingParentAndRecoveryIndexes},
    {'compactor prunes dead refs variants and scans', compactorPrunesDeadRefsVariantsAndScans},
    {'dirty save compaction gate and pending revert wake', dirtySaveCompactionAndWakePendingReverts},
    {'stress 1000-op save load and index maintenance', stressLedger1000OpsRoundtrip, {stress = true}},
  })
end

return M
