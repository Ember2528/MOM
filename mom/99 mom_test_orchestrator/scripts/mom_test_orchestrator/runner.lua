-- Coroutine scenario runner with continue-on-failure semantics.

local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local catalog = require('scripts.mom_test_orchestrator.scenario_catalog')
local core = require('openmw.core')

local optionsOk, runOptions = pcall(require, 'scripts.mom_test_orchestrator.run_options')
if not optionsOk or type(runOptions) ~= 'table' then
  runOptions = {}
end

local M = {}

local state = {
  phase = 'idle',
  frame = 0,
  autoStartPending = false,
  runCounter = 0,
  currentScenario = nil,
  failure = nil,
  results = {},
  lastReport = nil,
  runner = nil,
}

-- Logging

local function log(level, message)
  print(string.format('[MOMTestOrchestrator][%s] %s', tostring(level):upper(), tostring(message)))
end

local JSON_ESCAPES = {
  ['"'] = '\\"',
  ['\\'] = '\\\\',
  ['\b'] = '\\b',
  ['\f'] = '\\f',
  ['\n'] = '\\n',
  ['\r'] = '\\r',
  ['\t'] = '\\t',
}

local function escapeJsonChar(char)
  return JSON_ESCAPES[char] or string.format('\\u%04x', string.byte(char))
end

local function jsonString(value)
  return '"' .. tostring(value):gsub('[%c\\"]', escapeJsonChar) .. '"'
end

local function emitScenarioResult(result)
  local payload = {
    '{"id":',
    jsonString(result.id),
    ',"status":',
    jsonString(result.passed and 'passed' or 'failed'),
    ',"frames":',
    tostring(result.frames or 0),
    ',"elapsedSeconds":',
    string.format('%.6f', result.elapsedSeconds),
  }
  if result.error ~= nil then
    payload[#payload + 1] = ',"error":'
    payload[#payload + 1] = jsonString(result.error)
  end
  payload[#payload + 1] = '}'
  log('info', 'SCENARIO_RESULT ' .. table.concat(payload))
end

local function requestAutoExit()
  if runOptions.autoExit == false then return end
  if type(core.quit) ~= 'function' then
    log('warn', 'Auto-exit requested but openmw.core.quit is unavailable')
    return
  end
  core.quit()
end

-- Scenario execution

local function recordScenarioResult(result)
  state.results[#state.results + 1] = result
end

local function resetScenarioState(phase, scenario)
  H.resetActorObservations()
  local ok, err = pcall(H.resetScenarioState)
  if not ok then
    log('error', string.format(
      'Scenario reset FAILED (%s %s): %s',
      tostring(phase),
      tostring(scenario and scenario.id or 'unknown'),
      tostring(err)
    ))
    return false, err
  end
  return true, nil
end

local function runScenario(scenario)
  local startedAt = state.frame
  local startedSeconds = core.getRealTime()
  state.currentScenario = scenario.id
  log('info', string.format('Scenario start: %s', tostring(scenario.id)))

  local setupOk, setupErr = resetScenarioState('before', scenario)
  local ok, err = false, setupErr
  if setupOk then
    ok, err = pcall(scenario.run)
  end
  local frames = state.frame - startedAt
  local elapsedSeconds = core.getRealTime() - startedSeconds
  local passed = setupOk and ok
  local failure = setupErr or err

  if passed then
    log('info', string.format('Scenario passed: %s (%d frames)', tostring(scenario.id), frames))
    local result = {
      id = scenario.id,
      description = scenario.description,
      passed = true,
      frames = frames,
      elapsedSeconds = elapsedSeconds,
    }
    recordScenarioResult(result)
    emitScenarioResult(result)
  else
    log('error', string.format('Scenario FAILED: %s (%d frames): %s', tostring(scenario.id), frames, tostring(failure)))
    local result = {
      id = scenario.id,
      description = scenario.description,
      passed = false,
      frames = frames,
      elapsedSeconds = elapsedSeconds,
      error = tostring(failure),
    }
    recordScenarioResult(result)
    emitScenarioResult(result)
  end

  return passed
end

local function campaignPhaseSelected()
  local selected = runOptions.scenarios
  return type(selected) == 'table'
    and #selected == 1
    and tostring(selected[1]):match('^campaign_') ~= nil
end

-- Suite main

local function suiteMain()
  H.waitForSuiteReady()
  H.flushJitDiagnostics()
  H.logGcDiagnostics('before suite')
  H.ensureMOMReady()

  local scenarios = catalog.select(runOptions.scenarios)

  local failures = 0
  for i = 1, #scenarios do
    local ok = runScenario(scenarios[i])
    if not ok then
      failures = failures + 1
    end
  end

  state.currentScenario = nil
  return failures
end

-- Report builder

local function buildReport()
  local passed = 0
  for i = 1, #state.results do
    if state.results[i].passed then
      passed = passed + 1
    end
  end

  return {
    phase = state.phase,
    runCounter = state.runCounter,
    currentScenario = state.currentScenario,
    failure = state.failure,
    passed = passed,
    failed = #state.results - passed,
    total = #state.results,
    results = H.copyArray(state.results),
  }
end

local function finishRun(phase, failure)
  state.phase = phase
  state.failure = failure and tostring(failure) or nil
  state.currentScenario = nil
  state.runner = nil
  state.lastReport = buildReport()

  if phase == 'passed' then
    log('info', string.format('Suite passed: %d/%d scenario(s)', state.lastReport.passed, state.lastReport.total))
  else
    log('error', string.format(
      'Suite failed: %d/%d passed, %d failed',
      state.lastReport.passed, state.lastReport.total, state.lastReport.failed
    ))
    if state.failure then
      log('error', 'Last error: ' .. tostring(state.failure))
    end
  end

  log('info', string.format(
    'RESULT status=%s passed=%d failed=%d total=%d',
    tostring(phase),
    state.lastReport.passed,
    state.lastReport.failed,
    state.lastReport.total
  ))

  H.logGcDiagnostics('after suite')
  H.collectGc()
  requestAutoExit()
end

-- Run lifecycle

local function beginRun(source)
  if state.phase == 'running' then
    return false, 'suite already running'
  end

  state.runCounter = state.runCounter + 1
  state.phase = 'running'
  state.failure = nil
  state.currentScenario = nil
  state.results = {}
  state.autoStartPending = false
  state.lastReport = nil
  state.runner = coroutine.create(function()
    log('info', string.format('Starting run #%d (%s)', state.runCounter, tostring(source or 'manual')))
    local failures = suiteMain()
    return failures
  end)
  return true, nil
end

-- Engine handlers

function M.onInit()
  state.phase = 'idle'
  state.frame = 0
  state.failure = nil
  state.currentScenario = nil
  state.results = {}
  state.lastReport = nil
  state.runner = nil
  state.autoStartPending = C.AUTO_START == true
  if state.autoStartPending then
    log('info', 'Auto-start armed; expecting bypass-new-game startup with a default character')
  end
end

function M.onLoad()
  if state.phase == 'idle' and state.runCounter == 0 and campaignPhaseSelected() then
    state.autoStartPending = true
    log('info', 'Campaign load phase armed for auto-start')
    return
  end
  if state.phase == 'idle' and state.runCounter == 0 and state.autoStartPending then
    log('info', 'Load event during initial startup; keeping auto-start armed')
    return
  end

  state.autoStartPending = false
end

function M.onUpdate()
  state.frame = state.frame + 1
  H.updateActorObservations()

  if state.autoStartPending and state.phase == 'idle' then
    beginRun('auto')
  end

  if state.phase ~= 'running' or not state.runner then
    return
  end

  local ok, err = coroutine.resume(state.runner)
  if not ok then
    -- Scenario failures are caught inside suiteMain; a failed coroutine resume
    -- indicates a framework failure.
    finishRun('failed', err)
    return
  end

  if coroutine.status(state.runner) == 'dead' then
    local failCount = 0
    for i = 1, #state.results do
      if not state.results[i].passed then
        failCount = failCount + 1
      end
    end
    if failCount > 0 then
      finishRun('failed', string.format('%d scenario(s) failed', failCount))
    else
      finishRun('passed')
    end
  end
end

function M.onActorActive(actor)
  H.observeActorActive(actor)
end

-- Public interface

function M.run()
  local ok, err = beginRun('manual')
  if not ok then
    return false, err
  end
  return true
end

function M.status()
  return buildReport()
end

function M.report()
  return state.lastReport or buildReport()
end

return M
