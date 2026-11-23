local protocol = require('scripts.mom_test_orchestrator.performance.protocol')

local M = {}

local function copy(value)
  if type(value) ~= 'table' then return value end
  local out = {}
  for key, child in pairs(value) do out[key] = copy(child) end
  return out
end

local function validateCases(cases)
  assert(type(cases) == 'table', 'performance cases are required')
  local byId = {}
  for i = 1, #cases do
    local case = cases[i]
    assert(type(case) == 'table', 'performance case must be a table')
    assert(type(case.id) == 'string' and case.id ~= '', 'performance case id is required')
    assert(byId[case.id] == nil, 'duplicate performance case: ' .. case.id)
    assert(type(case.version) == 'number' and case.version >= 1,
      'performance case version is required: ' .. case.id)
    assert(type(case.operations) == 'number' and case.operations >= 1,
      'performance case operations are required: ' .. case.id)
    assert(type(case.execute) == 'function', 'performance case execute is required: ' .. case.id)
    assert(type(case.modes) == 'table', 'performance case modes are required: ' .. case.id)
    assert(case.requiresFreshProcess == nil
        or type(case.requiresFreshProcess) == 'boolean',
      'performance case requiresFreshProcess must be boolean: ' .. case.id)
    byId[case.id] = case
  end
  return byId
end

local function selectCases(cases, byId, mode, selectedIds)
  local selected = {}
  if selectedIds == nil or #selectedIds == 0 then
    for i = 1, #cases do
      if cases[i].modes[mode] == true then selected[#selected + 1] = cases[i] end
    end
    return selected
  end

  local seen = {}
  for i = 1, #selectedIds do
    local id = selectedIds[i]
    assert(not seen[id], 'duplicate selected performance case: ' .. tostring(id))
    seen[id] = true
    local case = assert(byId[id], 'unknown performance case: ' .. tostring(id))
    assert(case.modes[mode] == true,
      string.format('performance case %s does not support %s mode', id, mode))
    selected[#selected + 1] = case
  end
  return selected
end

local function caseResult(case)
  return {
    id = case.id,
    version = case.version,
    category = case.category,
    unit = case.unit,
    operations = case.operations,
    minimumSampleSeconds = case.minimumSampleSeconds,
    gcPolicy = case.gcPolicy,
    semantics = case.semantics,
    detail = protocol.object(copy(case.detail)),
    status = 'pending',
    samples = protocol.array(),
  }
end

local function scalarChecksum(value, id)
  local kind = type(value)
  assert(kind == 'string' or kind == 'number' or kind == 'boolean',
    'performance case returned a non-scalar checksum: ' .. id)
  if kind == 'number' then
    assert(value == value and value ~= math.huge and value ~= -math.huge,
      'performance case returned a non-finite checksum: ' .. id)
  end
  return tostring(value)
end

local function invoke(session, case, measured)
  local measurementCount = 0
  local sample = nil
  local setupBefore = nil
  if session.memoryEvidence and measured then
    -- Keep the invocation boundary as separate raw evidence. The case-lifetime
    -- baseline remains the summary reference, while this snapshot makes
    -- per-sample fixture/setup allocation directly diagnosable.
    session.runtime:collect()
    setupBefore = session.runtime:gcSnapshot()
  end
  local function measure(run)
    assert(type(run) == 'function', 'performance measurement body is required: ' .. case.id)
    measurementCount = measurementCount + 1
    assert(measurementCount == 1, 'performance case measured more than once: ' .. case.id)
    local before = nil
    if session.memoryEvidence then
      session.runtime:collect()
      before = session.runtime:gcSnapshot()
    end
    if not measured then return run() end

    local started = session.runtime:startTimer()
    local ok, checksumOrError, evidence = pcall(run)
    local timing = session.runtime:stopTimer(started)
    local after, retained = nil, nil
    if session.memoryEvidence then
      after = session.runtime:gcSnapshot()
      session.runtime:collect()
      retained = session.runtime:gcSnapshot()
    end
    if not ok then error(checksumOrError, 0) end
    local checksum = scalarChecksum(checksumOrError, case.id)
    sample = {
      elapsedSeconds = timing.elapsedSeconds,
      processCpuSeconds = timing.processCpuSeconds,
      operations = case.operations,
      checksum = checksum,
      valid = timing.elapsedSeconds >= (case.minimumSampleSeconds or 0),
    }
    if session.memoryEvidence then
      sample.gcCaseBefore = session.caseBefore
      sample.gcSetupBefore = setupBefore
      sample.gcBefore = before
      sample.gcAfter = after
      sample.gcRetained = retained
    end
    if evidence ~= nil then
      assert(type(evidence) == 'table',
        'performance case returned non-table sample evidence: ' .. case.id)
      -- Keep the case-owned table until execute() returns. Memory workloads
      -- may append untimed post-measurement attribution without changing the
      -- timed body or the runner-owned retained-heap snapshot.
      sample.evidence = evidence
    end
    if not sample.valid then sample.invalidReason = 'below_timing_floor' end
    return checksumOrError
  end

  local ok, checksumOrError = xpcall(function()
    local result = case.execute(measure, {
      memoryEvidence = session.memoryEvidence and measured,
    })
    if measured and sample ~= nil and sample.evidence ~= nil then
      sample.evidence = copy(sample.evidence)
      local durableCommitCount = sample.evidence.durableCommitCount
      if durableCommitCount ~= nil then
        assert(type(durableCommitCount) == 'number'
            and durableCommitCount >= 1
            and durableCommitCount % 1 == 0,
          'performance durable commit evidence is invalid: ' .. case.id)
        sample.evidence.elapsedMicrosPerDurableCommit =
          sample.elapsedSeconds * 1000000 / durableCommitCount
        if type(sample.processCpuSeconds) == 'number' then
          sample.evidence.processCpuMicrosPerDurableCommit =
            sample.processCpuSeconds * 1000000 / durableCommitCount
        end
      end
    end
    return result
  end, function(message)
    return session.runtime:traceback(message)
  end)
  assert(measurementCount == 1 or not ok,
    'performance case did not measure exactly once: ' .. case.id)
  if not ok then return nil, checksumOrError end
  local checksum = scalarChecksum(checksumOrError, case.id)
  if measured then
    assert(sample ~= nil, 'performance sample was not captured: ' .. case.id)
    assert(sample.checksum == checksum,
      'performance case changed its checksum outside the timed body: ' .. case.id)
  end
  return sample or checksum
end

local Session = {}
Session.__index = Session

function Session:_finishCase()
  local result = self.currentResult
  local expected = nil
  local valid = true
  for i = 1, #result.samples do
    local sample = result.samples[i]
    expected = expected or sample.checksum
    if sample.checksum ~= expected then
      result.status = 'failed'
      result.error = 'sample checksum mismatch'
      return
    end
    if not sample.valid then valid = false end
  end
  result.checksum = expected
  result.status = valid and 'passed' or 'invalid'
end

function Session:_startCase(case)
  self.currentCase = case
  self.currentResult = caseResult(case)
  self.results[#self.results + 1] = self.currentResult
  self.warmupIndex = 0
  self.sampleIndex = 0
  self.runtime:prepareJit()
  self.caseBefore = nil
  if self.memoryEvidence then
    -- One case-lifetime baseline intentionally precedes warmups and all
    -- case-owned fixture/setup work. Reusing it for every measured sample
    -- preserves caches and other retained growth accumulated across the case.
    -- `gcBefore` remains the per-sample timed-body boundary.
    self.runtime:collect()
    self.caseBefore = self.runtime:gcSnapshot()
  end
end

function Session:step()
  if self.complete then return true end
  if self.currentCase == nil then
    self.caseIndex = self.caseIndex + 1
    local case = self.cases[self.caseIndex]
    if case == nil then
      self.complete = true
      return true
    end
    self:_startCase(case)
  end

  if self.warmupIndex < self.warmups then
    self.warmupIndex = self.warmupIndex + 1
    local _, err = invoke(self, self.currentCase, false)
    if err then
      self.currentResult.status = 'failed'
      self.currentResult.error = err
      self.currentCase = nil
    end
    return false
  end

  self.sampleIndex = self.sampleIndex + 1
  local sample, err = invoke(self, self.currentCase, true)
  if err then
    self.currentResult.status = 'failed'
    self.currentResult.error = err
    self.currentCase = nil
    return false
  end
  self.currentResult.samples[#self.currentResult.samples + 1] = sample
  if self.sampleIndex >= self.samples then
    self:_finishCase()
    self.currentCase = nil
  end
  return false
end

function Session:runAll()
  while not self:step() do end
  return self:report()
end

function Session:report()
  assert(self.complete, 'performance session is not complete')
  local status = 'passed'
  for i = 1, #self.results do
    if self.results[i].status == 'failed' then
      status = 'failed'
      break
    elseif self.results[i].status == 'invalid' then
      status = 'invalid'
    end
  end
  return {
    schemaVersion = 5,
    kind = 'mom.performance.raw',
    status = status,
    mode = self.mode,
    clock = self.runtime.clockKind,
    memoryEvidence = self.memoryEvidence,
    capturedAtUtc = self.runtime:capturedAtUtc(),
    runtime = self.runtime:describe(),
    warmupsPerCase = self.warmups,
    samplesPerCase = self.samples,
    results = self.results,
  }
end

function M.new(options)
  assert(type(options) == 'table', 'performance runner options are required')
  local cases = assert(options.cases, 'performance runner cases are required')
  local byId = validateCases(cases)
  local runtime = assert(options.runtime, 'performance runtime is required')
  local mode = options.mode or runtime.mode
  local samples = options.samples or 1
  local warmups = options.warmups or 1
  local memoryEvidence = options.memoryEvidence == true
  assert(type(samples) == 'number' and samples >= 1 and samples % 1 == 0,
    'performance sample count must be a positive integer')
  assert(type(warmups) == 'number' and warmups >= 0 and warmups % 1 == 0,
    'performance warmup count must be a non-negative integer')
  return setmetatable({
    runtime = runtime,
    mode = mode,
    cases = selectCases(cases, byId, mode, options.selectedIds),
    samples = samples,
    warmups = warmups,
    memoryEvidence = memoryEvidence,
    caseIndex = 0,
    results = protocol.array(),
    complete = false,
  }, Session)
end

return M
