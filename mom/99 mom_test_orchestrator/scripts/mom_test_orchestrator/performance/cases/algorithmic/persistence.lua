local support = require('scripts.mom_test_orchestrator.performance.cases.algorithmic.support')
local compactor = support.compactor
local coordinator_api = support.coordinator_api
local executor_api = support.executor_api
local ledger_api = support.ledger_api
local local_broker_api = support.local_broker_api
local stateManifest = support.stateManifest
local newRuntime = support.newRuntime

return function(define)
  local function populatedLedger(opCount)
    local ledger = ledger_api.new()
    ledger:setManifestHash('sha256:perf-manifest')
    for i = 1, opCount do
      local tid = string.format('content:%06x:morrowind.esm', i)
      ledger:putRef({
        kind = 'ref',
        id = tid,
        objectId = tid,
        recordId = 'perf_rec',
        origin = {cellKey = 'perf_cell', x = i, y = 0, z = 0},
      })
      ledger:putOp({
        id = 'op:' .. tostring(i),
        semanticId = 'sem:' .. tostring(i),
        actionId = 'act:1',
        family = 'perf_action',
        lifecycle = 'state',
        durability = 'reversible',
        state = 'applied',
        ownerId = 'owner:1',
        targetId = tid,
        targetRecordId = 'perf_rec',
        claims = {'ref.scale'},
        token = {value = 1},
        outputs = {},
      })
    end
    return ledger
  end

  local function outputHeavyLedger(producers, outputsPerProducer)
    local ledger = ledger_api.new()
    ledger:setManifestHash('sha256:perf-output-manifest')
    for p = 1, producers do
      local parentId = string.format('content:%06x:morrowind.esm', p)
      local opId = 'op:' .. tostring(p)
      local outs = {}
      ledger:putRef({kind = 'ref', id = parentId, objectId = parentId, recordId = 'perf_parent'})
      for k = 1, outputsPerProducer do
        local outId = string.format('output:%d:%d', p, k)
        outs[k] = outId
        ledger:putRef({
          kind = 'output',
          id = outId,
          objectId = '@0x' .. tostring(p * 16 + k),
          recordId = 'perf_out',
          producerOpId = opId,
          parentTargetId = parentId,
          slot = tostring(k),
          cellKey = 'perf_cell',
        })
      end
      ledger:putOp({
        id = opId,
        semanticId = 'sem:' .. tostring(p),
        actionId = 'act:place',
        family = 'place_ref',
        lifecycle = 'state',
        durability = 'reversible',
        state = 'applied',
        ownerId = 'owner:1',
        targetId = parentId,
        claims = {'output.existence'},
        outputs = outs,
      })
    end
    return ledger
  end

  define('ledger_roundtrip_10k', {
    version = 5,
    category = 'persistence',
    operations = 1,
    minimumSampleSeconds = 0.001,
    gcPolicy = 'inclusive',
    semantics = 'cold_start',
    modes = {standalone = true},
    detail = {operations = 10000, schemaVersion = 1},
  }, function(measure)
    local ledger = populatedLedger(10000)
    return measure(function()
      local saved = ledger:save()
      local loaded, info = ledger_api.decode(saved)
      assert(loaded ~= nil and info.status == 'loaded' and loaded:opCount() == 10000)
      return 'ops=10000'
    end)
  end)

  define('ledger_compact_10k', {
    version = 1,
    category = 'persistence',
    operations = 1,
    minimumSampleSeconds = 0.001,
    gcPolicy = 'inclusive',
    semantics = 'cold_start',
    modes = {standalone = true},
    detail = {staleScans = 10000},
  }, function(measure)
    return measure(function()
      local ledger = ledger_api.new()
      ledger:setManifestHash('sha256:current')
      for i = 1, 10000 do
        ledger:setStaticScan('cell_' .. tostring(i), {manifestHash = 'sha256:stale'})
      end
      ledger:setStaticScan('cell_live', {manifestHash = 'sha256:current'})
      local stats = compactor.compact(ledger)
      assert(stats.removedScans == 10000)
      return 'removed=' .. tostring(stats.removedScans)
    end)
  end)

  define('ledger_output_roundtrip_2k', {
    version = 3,
    category = 'persistence',
    operations = 5,
    minimumSampleSeconds = 0.001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    modes = {standalone = true, embedded = true},
    detail = {producers = 256, outputsPerProducer = 8},
  }, function(measure)
    local ledger = outputHeavyLedger(256, 8)
    return measure(function()
      local loaded
      for _ = 1, 5 do
        local saved = ledger:save()
        loaded = assert(ledger_api.decode(saved))
      end
      assert(loaded:opCount() == 256)
      return 'outputs=2048;operations=256'
    end)
  end)

  define('save_encode', {
    version = 2,
    category = 'persistence',
    operations = 20,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {operations = 2000},
  }, function(measure)
    local ledger = populatedLedger(2000)
    return measure(function()
      local saved
      for _ = 1, 20 do saved = ledger:save() end
      return 'schema=' .. tostring(saved.schemaVersion)
    end)
  end)

  define('save_load', {
    version = 2,
    category = 'persistence',
    operations = 20,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {operations = 2000},
  }, function(measure)
    local saved = populatedLedger(2000):save()
    return measure(function()
      local decoded
      for _ = 1, 20 do decoded = assert(ledger_api.decode(saved)) end
      return 'ops=' .. tostring(decoded:opCount())
    end)
  end)

  define('runtime_save', {
    version = 2,
    category = 'persistence',
    operations = 20,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {operations = 2000},
  }, function(measure)
    local rt = newRuntime(stateManifest(0, 1), populatedLedger(2000))
    return measure(function()
      local snapshot
      for _ = 1, 20 do snapshot = assert(coordinator_api.saveSnapshot(rt)) end
      return 'schema=' .. tostring(snapshot.schemaVersion)
    end)
  end)

  define('operation_journal_cycle', {
    version = 5,
    category = 'ledger',
    operations = 128,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {cycles = 128, lifecycle = 'capture/apply/revert'},
  }, function(measure)
    local ledger = ledger_api.new()
    local broker = local_broker_api.new()
    local mod = support.actionCatalog().actions.byId.perf_action.module
    local targets, byId = {}, {}
    for i = 1, 128 do
      local id = string.format('content:%06x:morrowind.esm', i)
      targets[i] = {id = id, recordId = 'perf_rec', value = 0}
      byId[id] = targets[i]
    end
    local session = {
      world = {
        resolveTarget = function(id) return byId[id] end,
        describeRef = function(ref) return {id = ref.id, recordId = ref.recordId} end,
        isValid = function(r) return r ~= nil end,
      },
    }
    local exec = executor_api.new({
      ledger = ledger,
      session = session,
      localBroker = broker,
      actionModules = {perf_action = mod},
      manifest = {actionsById = {}},
    })
    local action = {
      id = 'act:1', family = 'perf_action', lifecycle = 'state', ownerId = 'owner:1',
      reversible = true, claims = {keys = {'ref.scale'}}, program = {value = 2},
    }
    return measure(function()
      for i = 1, 128 do
        local t = targets[i]
        local res = exec.apply({
          semanticId = 'sem:' .. tostring(i),
          targetId = t.id,
          cellKey = 'perf_cell',
          action = action,
        }, t, {id = t.id, recordId = t.recordId}, i)
        assert(res.status == 'applied' and t.value == 2)
        local rev = exec.revert(res.op, i)
        assert(rev.status == 'applied' and t.value == 0)
      end
      assert(ledger:opCount() == 0)
      return 'cycles=128'
    end)
  end)
end
