local support = require('scripts.mom_test_orchestrator.performance.cases.algorithmic.support')
local coordinator_api = support.coordinator_api
local staticManifest = support.staticManifest
local newRuntime = support.newRuntime
local mockSession = support.mockSession
local makeCell = support.makeCell

return function(define)
  define('static_cell_queue', {
    version = 2,
    category = 'runtime',
    operations = 64,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {queuedCells = 64},
  }, function(measure)
    local session = mockSession()
    local rt = newRuntime(staticManifest(), nil, session)
    local frame = 0
    return measure(function()
      for i = 1, 64 do
        session.pushCell(makeCell(string.format('queued_cell_%03d_%d', i, frame)))
        frame = frame + 1
        coordinator_api.tick(rt, {frame = frame})
      end
      return 'frames=' .. tostring(frame)
    end)
  end)

  define('static_completed_cell_revisit', {
    version = 3,
    category = 'runtime',
    operations = 250,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {completedCells = 1, staticDiscoveriesPerRevisit = 0},
  }, function(measure)
    local ref = {
      id = 'content:000001:morrowind.esm',
      recordId = 'perf_static_target',
      typeName = 'Static',
      cellKey = 'performance_cell',
      value = 0,
    }
    local cellEntry = makeCell('performance_cell', {ref})
    local scanCalls = 0
    local session = mockSession({
      byId = {[ref.id] = ref},
      onCellRefs = function() scanCalls = scanCalls + 1 end,
    })
    local rt = newRuntime(staticManifest(), nil, session)
    session.pushCell(cellEntry)
    coordinator_api.tick(rt, {frame = 1})
    assert(scanCalls == 1 and ref.value == 1, 'initial static scan did not apply')
    scanCalls = 0
    local frame = 1
    return measure(function()
      for _ = 1, 250 do
        session.pushCell(cellEntry)
        frame = frame + 1
        coordinator_api.tick(rt, {frame = frame})
      end
      assert(scanCalls == 0, 'completed static cell rescanned on revisit')
      return 'revisits=250;scans=0'
    end)
  end)

  define('broad_loaded_cell_audit', {
    version = 2,
    category = 'engine_bridge',
    operations = 25,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {refsPerCell = 256},
  }, function(measure)
    local refs, byId = {}, {}
    for i = 1, 256 do
      local ref = {
        id = string.format('content:%06x:morrowind.esm', i),
        recordId = 'perf_static_target',
        typeName = 'Static',
        cellKey = 'dense_cell',
        value = 0,
      }
      refs[i] = ref
      byId[ref.id] = ref
    end
    local frame = 0
    return measure(function()
      for run = 1, 25 do
        local cellKey = 'dense_cell_' .. tostring(run)
        local session = mockSession({byId = byId})
        local rt = newRuntime(staticManifest(), nil, session)
        session.pushCell(makeCell(cellKey, refs))
        frame = frame + 1
        coordinator_api.tick(rt, {frame = frame})
      end
      return 'runs=25;refs=256'
    end)
  end)
end
