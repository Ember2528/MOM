local optionsOk, runOptions = pcall(require, 'scripts.mom_test_orchestrator.run_options')
if not optionsOk or type(runOptions) ~= 'table' or runOptions.mode ~= 'performance' then
  return {}
end

local core = require('openmw.core')
local protocol = require('scripts.mom_test_orchestrator.performance.protocol')
local runner = require('scripts.mom_test_orchestrator.performance.runner')
local unsafe_runtime = require('scripts.mom_test_orchestrator.performance.unsafe_runtime')

local performance = assert(runOptions.performance, 'performance run options are required')
local lane = performance.lane or 'embedded'
local cases = require(lane == 'integration'
  and 'scripts.mom_test_orchestrator.performance.cases.integration'
  or 'scripts.mom_test_orchestrator.performance.cases.algorithmic')
local resultFile = assert(performance.resultFile, 'performance result file is required')
local session = nil
local runtime = nil
local delayFrames = performance.startDelayFrames or 5
local finished = false

local function log(level, message)
  print(string.format('[MOMPerformance][%s] %s', level, tostring(message)))
end

local function quit()
  if type(core.quit) == 'function' then core.quit() end
end

local function traceback(message)
  if runtime then return runtime:traceback(message) end
  return tostring(message)
end

local function failureReport(message)
  return {
    schemaVersion = 5,
    kind = 'mom.performance.raw',
    status = 'failed',
    mode = lane,
    clock = runtime and runtime.clockKind or 'monotonic_wall',
    memoryEvidence = performance.memoryEvidence == true,
    capturedAtUtc = runtime and runtime:capturedAtUtc() or nil,
    runtime = runtime and runtime:describe() or nil,
    warmupsPerCase = performance.warmups or 1,
    samplesPerCase = performance.samples or 1,
    error = tostring(message),
    results = protocol.array(),
  }
end

local function fail(message)
  finished = true
  log('ERROR', message)
  if runtime then
    local wrote, writeError = pcall(protocol.write, runtime, resultFile, failureReport(message))
    if not wrote then log('ERROR', 'Could not write failure result: ' .. tostring(writeError)) end
  end
  quit()
end

local function initialize()
  runtime = unsafe_runtime.embedded(core)
  session = runner.new({
    runtime = runtime,
    cases = cases,
    mode = lane,
    selectedIds = performance.workloads,
    samples = performance.samples or 1,
    warmups = performance.warmups or 1,
    memoryEvidence = performance.memoryEvidence == true,
  })
  log('INFO', string.format('Started: workloads=%d samples=%d warmups=%d',
    #session.cases, session.samples, session.warmups))
end

local function onInit()
  delayFrames = performance.startDelayFrames or 5
end

local function onUpdate()
  if finished then return end
  if delayFrames > 0 then
    delayFrames = delayFrames - 1
    return
  end
  if lane == 'integration' and type(cases.ready) == 'function' and not cases.ready() then
    return
  end
  if session == nil then
    local ok, err = xpcall(initialize, traceback)
    if not ok then
      fail(err)
      return
    end
  end

  local ok, completeOrError = xpcall(function() return session:step() end, traceback)
  if not ok then
    fail(completeOrError)
    return
  end
  if not completeOrError then return end

  local report = session:report()
  local wrote, writeError = pcall(protocol.write, runtime, resultFile, report)
  if not wrote then
    fail(writeError)
    return
  end
  finished = true
  log('INFO', string.format('RESULT status=%s cases=%d path=%s',
    report.status, #report.results, resultFile))
  quit()
end

return {
  engineHandlers = {
    onInit = onInit,
    onUpdate = onUpdate,
  },
}
