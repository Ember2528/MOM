local protocol = require('scripts.mom_test_orchestrator.performance.protocol')
local runner = require('scripts.mom_test_orchestrator.performance.runner')
local allocation_probe = require(
  'scripts.mom_test_orchestrator.performance.allocation_probe'
)
local unsafe_runtime = require(
  'scripts.mom_test_orchestrator.performance.unsafe_runtime'
)

local M = {}

local test_support = require('pure.test_support')
local expect = test_support.expect

local function runtime(elapsed)
  local collects = 0
  local snapshots = 0
  local collectorRunning = true
  local stops = 0
  local restarts = 0
  return {
    mode = 'standalone',
    clockKind = 'process_cpu',
    collect = function() collects = collects + 1 end,
    stopCollector = function()
      collectorRunning = false
      stops = stops + 1
    end,
    restartCollector = function()
      collectorRunning = true
      restarts = restarts + 1
    end,
    gcSnapshot = function()
      snapshots = snapshots + 1
      return {memoryKb = snapshots, running = collectorRunning}
    end,
    startTimer = function() return {} end,
    stopTimer = function()
      return {elapsedSeconds = elapsed or 0.01}
    end,
    traceback = function(_, message) return tostring(message) end,
    prepareJit = function() end,
    capturedAtUtc = function() return '2026-01-01T00:00:00Z' end,
    describe = function() return {lua = 'fake'} end,
    collects = function() return collects end,
    snapshots = function() return snapshots end,
    collectorRunning = function() return collectorRunning end,
    stops = function() return stops end,
    restarts = function() return restarts end,
  }
end

local function caseDefinition(id, execute, minimum)
  return {
    id = id,
    version = 1,
    category = 'test',
    unit = 'microseconds_per_operation',
    modes = {standalone = true},
    operations = 2,
    minimumSampleSeconds = minimum or 0.001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    execute = execute,
  }
end

local function sampleLifecycleContract()
  local executions = 0
  local fake = runtime()
  local session = runner.new({
    runtime = fake,
    cases = {caseDefinition('stable', function(measure)
      executions = executions + 1
      return measure(function() return 'stable-checksum' end)
    end)},
    warmups = 1,
    samples = 2,
    memoryEvidence = true,
  })
  local report = session:runAll()
  local result = report.results[1]
  expect(report.status == 'passed' and result.status == 'passed',
    'valid samples did not pass')
  expect(executions == 3 and #result.samples == 2,
    'warmup or measured sample count drifted')
  expect(report.memoryEvidence == true
      and result.checksum == 'stable-checksum'
      and fake.collects() == 8
      and fake.snapshots() == 10
      and result.samples[1].gcCaseBefore.memoryKb == 1
      and result.samples[1].gcSetupBefore.memoryKb == 3
      and result.samples[1].gcBefore.memoryKb == 4
      and result.samples[2].gcCaseBefore.memoryKb == 1
      and result.samples[2].gcSetupBefore.memoryKb == 7
      and result.samples[2].gcBefore.memoryKb == 8,
    'checksum or pre/post collection contract drifted')
end

local function timingOnlySkipsMemoryInstrumentation()
  local fake = runtime()
  local session = runner.new({
    runtime = fake,
    cases = {caseDefinition('timing-only', function(measure)
      return measure(function() return 'timing-only' end)
    end)},
    warmups = 1,
    samples = 2,
  })
  local report = session:runAll()
  local sample = report.results[1].samples[1]
  expect(report.memoryEvidence == false
      and fake.collects() == 0
      and fake.snapshots() == 0
      and sample.gcCaseBefore == nil
      and sample.gcSetupBefore == nil
      and sample.gcBefore == nil
      and sample.gcAfter == nil
      and sample.gcRetained == nil,
    'timing-only run performed memory instrumentation')
end

local function selectionContract()
  local case = caseDefinition('known', function(measure)
    return measure(function() return 'known' end)
  end)
  local ok, err = pcall(runner.new, {
    runtime = runtime(),
    cases = {case},
    selectedIds = {'missing'},
  })
  expect(not ok and tostring(err):find('unknown performance case', 1, true),
    'unknown workload selection was accepted')

  ok, err = pcall(runner.new, {
    runtime = runtime(),
    cases = {case},
    selectedIds = {'known', 'known'},
  })
  expect(not ok and tostring(err):find('duplicate selected', 1, true),
    'duplicate workload selection was accepted')
end

local function invalidTimingContract()
  local session = runner.new({
    runtime = runtime(0.0001),
    cases = {caseDefinition('short', function(measure)
      return measure(function() return 'short' end)
    end, 0.001)},
    warmups = 0,
    samples = 1,
  })
  local report = session:runAll()
  expect(report.status == 'invalid'
      and report.results[1].samples[1].invalidReason == 'below_timing_floor',
    'sub-floor sample was treated as valid')
end

local function sampleEvidenceContract()
  local evidence = {
    phases = {discover = 3},
    queueHighWater = 2,
    durableCommitCount = 4,
  }
  local session = runner.new({
    runtime = runtime(),
    cases = {caseDefinition('evidence', function(measure)
      return measure(function() return 'evidence', evidence end)
    end)},
    warmups = 0,
    samples = 1,
  })
  local report = session:runAll()
  local saved = report.results[1].samples[1].evidence
  evidence.phases.discover = 99
  expect(saved.queueHighWater == 2
      and saved.phases.discover == 3
      and saved.elapsedMicrosPerDurableCommit == 2500,
    'sample evidence was not captured as a detached plain table')

  local invalid = runner.new({
    runtime = runtime(),
    cases = {caseDefinition('bad-evidence', function(measure)
      return measure(function() return 'bad-evidence', 'not-a-table' end)
    end)},
    warmups = 0,
    samples = 1,
  }):runAll()
  expect(invalid.status == 'failed'
      and invalid.results[1].error:find('non%-table sample evidence') ~= nil,
    'non-table sample evidence was accepted')

  local invalidCommitEvidence = runner.new({
    runtime = runtime(),
    cases = {caseDefinition('bad-commit-evidence', function(measure)
      return measure(function()
        return 'bad-commit-evidence', {durableCommitCount = 0}
      end)
    end)},
    warmups = 0,
    samples = 1,
  }):runAll()
  expect(invalidCommitEvidence.status == 'failed'
      and invalidCommitEvidence.results[1].error:find(
        'durable commit evidence is invalid',
        1,
        true
      ) ~= nil,
    'invalid durable commit evidence was accepted')
end

local function failureContinuationContract()
  local session = runner.new({
    runtime = runtime(),
    cases = {
      caseDefinition('broken', function(measure)
        return measure(function() error('synthetic failure') end)
      end),
      caseDefinition('after', function(measure)
        return measure(function() return 'after' end)
      end),
    },
    warmups = 0,
    samples = 1,
  })
  local report = session:runAll()
  expect(report.status == 'failed'
      and report.results[1].status == 'failed'
      and report.results[1].error:find('synthetic failure', 1, true)
      and report.results[2].status == 'passed',
    'semantic failure did not remain visible or runner did not continue')
end

local function allocationProbeContract()
  local executions = 0
  local fake = runtime()
  local report = allocation_probe.run({
    runtime = fake,
    cases = {caseDefinition('allocation', function(measure)
      executions = executions + 1
      return measure(function() return 'allocation-checksum' end)
    end)},
    id = 'allocation',
  })
  local sample = report.result.samples[1]
  expect(report.schemaVersion == 1
      and report.kind == 'mom.performance.allocation'
      and report.status == 'passed'
      and executions == 2
      and report.warmupsPerCase == 1
      and report.samplesPerCase == 1
      and sample.checksum == 'allocation-checksum'
      and sample.gcBefore.running == true
      and sample.gcStoppedAfter.running == false
      and sample.gcRetained.running == true
      and fake.stops() == 1
      and fake.restarts() == 1
      and fake.collectorRunning(),
    'allocation probe did not isolate one warmed stopped-GC sample')
end

local function allocationProbeRestartsAfterFailure()
  local executions = 0
  local fake = runtime()
  local report = allocation_probe.run({
    runtime = fake,
    cases = {caseDefinition('allocation-failure', function(measure)
      executions = executions + 1
      return measure(function()
        if executions == 2 then error('synthetic allocation failure') end
        return 'warmup'
      end)
    end)},
    id = 'allocation-failure',
  })
  expect(report.status == 'failed'
      and report.result.status == 'failed'
      and report.result.error:find(
        'synthetic allocation failure',
        1,
        true
      ) ~= nil
      and #report.result.samples == 0
      and fake.stops() == 1
      and fake.restarts() == 1
      and fake.collectorRunning(),
    'failed allocation body left the collector stopped or published a sample')
end

local function protocolContract()
  local encoded = protocol.encode(protocol.object({
    z = protocol.array(),
    a = 'line\nquote"',
  }))
  expect(encoded == '{"a":"line\\nquote\\\"","z":[]}',
    'JSON encoding was not deterministic or escaped')
  local cyclic = {}
  cyclic.self = cyclic
  local ok, err = pcall(protocol.encode, cyclic)
  expect(not ok and tostring(err):find('cyclic', 1, true),
    'cyclic JSON value was accepted')
end

local function narrowEmbeddedAuthorityContract()
  local previousSelect = select
  local clock, writes = 10, {}
  local authority = {
    collectgarbage = function(option)
      if option == 'count' then return 1 end
      if option == 'isrunning' then return true end
    end,
    writeAtomic = function(path, bytes)
      writes[#writes + 1] = {path = path, bytes = bytes}
      return true
    end,
  }
  select = function(key, ...)
    if key == 'sandbox.bypass' then return authority end
    return previousSelect(key, ...)
  end
  local ok, failure = pcall(function()
    local embedded = unsafe_runtime.embedded({getRealTime = function() return clock end})
    local started = embedded:startTimer()
    clock = 10.25
    local elapsed = embedded:stopTimer(started)
    expect(elapsed.elapsedSeconds == 0.25 and elapsed.processCpuSeconds == nil
        and embedded:capturedAtUtc() == nil
        and embedded:describe().jit.available == false,
      'narrow embedded authority invented unavailable OS or LuaJIT evidence')
    protocol.write(embedded, 'result.json', {status = 'passed'})
    expect(#writes == 1 and writes[1].path == 'result.json'
        and writes[1].bytes == '{"status":"passed"}\n',
      'embedded result did not use its actual atomic writer authority')
    authority.writeAtomic = function() return false, 'synthetic writer failure' end
    local failedWriter = unsafe_runtime.embedded({getRealTime = function() return clock end})
    local wrote, writeError = pcall(failedWriter.writeAtomic, failedWriter, 'result.json', 'bytes')
    expect(not wrote and tostring(writeError):find('synthetic writer failure', 1, true),
      'failed atomic writer authority was treated as a published result')
  end)
  select = previousSelect
  if not ok then error(failure, 0) end
end

local CASES = {
  {'sample lifecycle', sampleLifecycleContract},
  {'timing-only skips memory instrumentation',
    timingOnlySkipsMemoryInstrumentation},
  {'selection', selectionContract},
  {'timing floor', invalidTimingContract},
  {'sample evidence', sampleEvidenceContract},
  {'failure continuation', failureContinuationContract},
  {'allocation probe', allocationProbeContract},
  {'allocation probe failure cleanup',
    allocationProbeRestartsAfterFailure},
  {'result protocol', protocolContract},
  {'narrow embedded authority', narrowEmbeddedAuthorityContract},
}

function M.run()
  return test_support.runCases('pure performance runner', CASES)
end

return M
