local protocol = require('scripts.mom_test_orchestrator.performance.protocol')

local M = {}

local function copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, child in pairs(value) do out[key] = copy(child) end
  return out
end

local function scalarChecksum(value, id)
  local kind = type(value)
  assert(kind == 'string' or kind == 'number' or kind == 'boolean',
    'allocation probe returned a non-scalar checksum: ' .. id)
  if kind == 'number' then
    assert(value == value and value ~= math.huge and value ~= -math.huge,
      'allocation probe returned a non-finite checksum: ' .. id)
  end
  return tostring(value)
end

local function caseResult(case)
  return {
    id = case.id,
    version = case.version,
    category = case.category,
    unit = 'kilobytes_per_timed_body',
    operations = case.operations,
    gcPolicy = case.gcPolicy,
    semantics = case.semantics,
    detail = protocol.object(copy(case.detail or {})),
    status = 'pending',
    samples = protocol.array(),
  }
end

local function selectCase(cases, id)
  assert(type(cases) == 'table', 'allocation probe cases are required')
  assert(type(id) == 'string' and id ~= '',
    'allocation probe workload id is required')
  local selected = nil
  for i = 1, #cases do
    local case = cases[i]
    assert(type(case) == 'table'
        and type(case.id) == 'string'
        and type(case.execute) == 'function',
      'allocation probe case is invalid')
    if case.id == id then
      assert(selected == nil, 'duplicate allocation probe case: ' .. id)
      selected = case
    end
  end
  assert(selected ~= nil, 'unknown allocation probe case: ' .. id)
  assert(type(selected.modes) == 'table'
      and selected.modes.standalone == true,
    'allocation probe case does not support standalone mode: ' .. id)
  assert(selected.gcPolicy == 'inclusive',
    'allocation probe requires inclusive GC policy: ' .. id)
  return selected
end

local function execute(case, runtime, measure)
  local measurementCount = 0
  local ok, checksumOrError = xpcall(function()
    local checksum = case.execute(function(run)
      assert(type(run) == 'function',
        'allocation probe measurement body is required: ' .. case.id)
      measurementCount = measurementCount + 1
      assert(measurementCount == 1,
        'allocation probe case measured more than once: ' .. case.id)
      return measure(run)
    end)
    assert(measurementCount == 1,
      'allocation probe case did not measure exactly once: ' .. case.id)
    return scalarChecksum(checksum, case.id)
  end, function(message)
    return runtime:traceback(message)
  end)
  if not ok then return nil, checksumOrError end
  return checksumOrError, nil
end

local function warmup(case, runtime)
  return execute(case, runtime, function(run)
    local checksum = run()
    return checksum
  end)
end

local function measured(case, runtime)
  local sample = nil
  local checksum, executeError = execute(case, runtime, function(run)
    local stopped = false
    local function runStopped()
      runtime:stopCollector()
      stopped = true
      local bodyResult = run()
      local after = runtime:gcSnapshot()
      assert(after.running == false,
        'allocation probe collector restarted inside the timed body')
      return bodyResult, after
    end
    local function trace(message)
      return runtime:traceback(message)
    end
    local function restart()
      -- Restart is idempotent for the standalone Lua collector. Call it even
      -- if stopping or snapshotting failed so an error cannot poison the
      -- remainder of the process.
      runtime:restartCollector()
      stopped = false
    end

    runtime:collect()
    local before = runtime:gcSnapshot()
    assert(before.running == true,
      'allocation probe collector was not running before the timed body')

    local ran, bodyResult, after = xpcall(runStopped, trace)
    local restarted, restartError = pcall(restart)
    if not restarted then
      error(
        'allocation probe could not restart the collector: '
          .. tostring(restartError),
        0
      )
    end
    assert(stopped == false)
    runtime:collect()
    local retained = runtime:gcSnapshot()
    assert(retained.running == true,
      'allocation probe collector was not running after cleanup')
    if not ran then error(bodyResult, 0) end
    local bodyChecksum = scalarChecksum(bodyResult, case.id)

    sample = {
      operations = case.operations,
      checksum = bodyChecksum,
      gcBefore = before,
      gcStoppedAfter = after,
      gcRetained = retained,
    }
    return bodyChecksum
  end)
  if not checksum then return nil, executeError end
  assert(sample ~= nil, 'allocation probe sample was not captured: ' .. case.id)
  assert(sample.checksum == checksum,
    'allocation probe checksum changed outside the timed body: ' .. case.id)
  return sample, nil
end

function M.run(options)
  assert(type(options) == 'table',
    'allocation probe options are required')
  local runtime = assert(options.runtime,
    'allocation probe runtime is required')
  assert(runtime.mode == 'standalone',
    'allocation probes require the standalone runtime')
  local case = selectCase(options.cases, options.id)
  runtime:prepareJit()
  runtime:collect()

  local result = caseResult(case)
  local warmupChecksum, warmupError = warmup(case, runtime)
  if warmupChecksum == nil then
    result.status = 'failed'
    result.error = warmupError
  else
    local sample, sampleError = measured(case, runtime)
    if sample == nil then
      result.status = 'failed'
      result.error = sampleError
    else
      result.status = 'passed'
      result.checksum = sample.checksum
      result.samples[1] = sample
    end
  end

  return {
    schemaVersion = 1,
    kind = 'mom.performance.allocation',
    status = result.status,
    mode = 'standalone',
    capturedAtUtc = runtime:capturedAtUtc(),
    runtime = runtime:describe(),
    warmupsPerCase = 1,
    samplesPerCase = 1,
    result = result,
  }
end

return M
