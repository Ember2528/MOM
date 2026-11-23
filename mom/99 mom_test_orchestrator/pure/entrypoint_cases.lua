local constants = require('scripts.mom.constants')
local entrypoint = require('scripts.mom.entrypoint')

local M = {}

local test_support = require('pure.test_support')
local expect = test_support.expect

local function expectExactKeys(value, expected, label)
  for key in pairs(value or {}) do
    expect(expected[key] == true, tostring(label) .. ' exposed unexpected key ' .. tostring(key))
  end
  for key in pairs(expected) do
    expect(value[key] ~= nil, tostring(label) .. ' omitted key ' .. tostring(key))
  end
end

local function acceptedCandidate()
  return {
    status = 'accepted',
    manifest = {contentHash = 'sha256:fixture'},
    diagnostics = {summary = {
      total = 2,
      byClassification = {static = 1, state = 1},
      state = {owners = 1},
    }},
  }
end

local function fixture(opts)
  opts = opts or {}
  local calls = {}
  local app = {
    status = 'new',
  }
  local api = {}
  local function record(name, ...)
    calls[#calls + 1] = {name = name, values = {...}}
  end
  function api.load(target, payload)
    record('load', payload)
    if opts.loadFailure then
      target.status = opts.loadStatus or 'load-failed'
      return nil, {
        code = target.status == 'loaded-quarantined'
          and 'unsupported-save' or 'invalid-save',
      }
    end
    target.loadedLedger = payload or {schemaVersion = 0}
    target.status = 'loaded'
    return {status = payload == nil and 'new' or 'loaded'}
  end
  function api.bootstrap(target, candidate)
    record('bootstrap', candidate)
    if opts.bootstrapFailure
        or type(candidate) ~= 'table'
        or candidate.status == 'rejected' then
      target.status = 'bootstrap-failed'
      if type(candidate) == 'table' and candidate.status == 'rejected' then
        target.lastRejectedCandidate = candidate
      end
      return nil, type(candidate) == 'table' and candidate.fatal
        or {code = 'compile-failed'}
    end
    target.runtime = {}
    target.loadedLedger = nil
    target.status = 'running'
    target.activeDiagnostics = candidate.diagnostics
    target.activeManifestHash = candidate.manifest.contentHash
    return {status = 'running', manifestHash = 'sha256:fixture'}
  end
  function api.tick()
    record('tick')
    if opts.tickFailure ~= nil then return nil, opts.tickFailure end
    return {frame = 1}
  end
  function api.save(target)
    record('save')
    return opts.savedPayload or {
      schemaVersion = 0,
    }
  end
  function api.observeObject(_, object)
    record('object', object)
    return true
  end
  function api.observeCell(_, cell)
    record('cell', cell)
    return true
  end
  function api.enqueueEvent(_, name)
    record('event', name)
    return true
  end
  function api.acknowledgeLocal(_, payload)
    record('ack', payload)
    return {status = 'acknowledged'}
  end
  function api.updateQuestStage(_, questId, stage)
    record('quest', questId, stage)
    return true
  end
  function api.replaceQuestSnapshot(_, quests)
    record('snapshot', quests)
    return true
  end
  function api.selfcheck(target, options)
    record('selfcheck', options)
    return {ok = target.runtime ~= nil, status = target.status, frame = 1,
      ledger = {ok = true}, manifest = {ok = true}}
  end
  function api.compileReport(target)
    return {status = target.status, activeManifestHash = 'sha256:fixture',
      summary = target.activeDiagnostics and target.activeDiagnostics.summary or nil,
      lastRejected = target.lastRejectedCandidate and {
        status = 'rejected',
        summary = target.lastRejectedCandidate.diagnostics.summary,
        fatal = target.lastRejectedCandidate.fatal,
      } or nil}
  end
  local logged = {}
  local log = {
    info = function(...) logged[#logged + 1] = {'info', ...} end,
    warn = function(...) logged[#logged + 1] = {'warn', ...} end,
    error = function(...) logged[#logged + 1] = {'error', ...} end,
    setLevel = function(level) return level, true, 'debug|info|warn|error' end,
  }
  local diagnostics = {
    error = function(...) logged[#logged + 1] = {'diagnostic-error', ...} end,
    warn = function(...) logged[#logged + 1] = {'diagnostic-warn', ...} end,
  }
  local function compileCandidate(sourceOptions)
    record('compile', sourceOptions)
    if opts.compileFailure then return nil, {code = 'compile-failed'} end
    if opts.compileRejection then
      return {
        status = 'rejected',
        diagnostics = {summary = {
          total = 0,
          diagnostics = {
            total = 1,
            bySeverity = {error = 1},
            samples = {{code = 'fixture_invalid', message = 'fixture rejection'}},
          },
          sources = {count = 1, failed = 1, rows = {}},
        }},
        fatal = {
          code = 'candidate_source_set_incomplete',
          message = 'fixture candidate was rejected',
          errors = {'fixture rejection'},
        },
      }
    end
    if type(opts.compileCandidate) == 'function' then
      return opts.compileCandidate(sourceOptions)
    end
    return acceptedCandidate()
  end
  local script = assert(entrypoint.new({
    app = app,
    appApi = api,
    constants = constants,
    log = log,
    diagnostics = diagnostics,
    candidateCompiler = compileCandidate,
    sourceOptions = {configDir = 'fixture/config'},
  }))
  local function named(name)
    local out = {}
    for i = 1, #calls do if calls[i].name == name then out[#out + 1] = calls[i] end end
    return out
  end
  return {app = app, api = api, script = script, calls = calls, named = named, logged = logged}
end

local function savedStateDoesNotAffectCompilerInputs()
  local observed = nil
  local payload = {schemaVersion = 0, durableState = 'fixture'}
  local f = fixture({
    compileCandidate = function(options)
      observed = options
      return acceptedCandidate()
    end,
  })
  expect(f.script.engineHandlers.onLoad(payload) == true
      and observed.configDir == 'fixture/config'
      and observed.previousSourceCapsules == nil,
    'saved state leaked into current-source compilation')
end

local function structuredCompileRejectionReachesSupportSurface()
  local f = fixture({compileRejection = true})
  local started, startupError = f.script.engineHandlers.onInit()
  expect(started == false
      and startupError.code == 'candidate_source_set_incomplete'
      and f.app.runtime == nil,
    'structured compiler rejection started a runtime or lost its fatal error')
  local bootstrap = f.named('bootstrap')[1]
  expect(bootstrap.values[1].status == 'rejected'
      and bootstrap.values[1].diagnostics.summary.diagnostics.samples[1].code
        == 'fixture_invalid',
    'entrypoint did not pass rejected candidate diagnostics to the App')
  local report = f.script.interface.compileReport({log = false})
  expect(report.lastRejected.status == 'rejected'
      and report.lastRejected.fatal.code == 'candidate_source_set_incomplete'
      and report.lastRejected.summary.diagnostics.total == 1,
    'entrypoint status API omitted the last rejected candidate')
end

local function soleOwnerLifecycle()
  local f = fixture()
  expect(f.script.interfaceName == constants.interfaceName
      and f.script.interface.version == constants.interfaceVersion,
    'entrypoint changed the public interface identity')
  expect(f.script.engineHandlers.onInit() == true and f.app.runtime ~= nil,
    'new-game callback did not install one App runtime')
  expect(#f.named('load') == 1 and #f.named('bootstrap') == 1
      and #f.named('compile') == 1
      and f.named('compile')[1].values[1].configDir == 'fixture/config'
      and f.named('bootstrap')[1].values[1].sourceOptions == nil,
    'entrypoint did not compile source options before App bootstrap')
  f.script.engineHandlers.onUpdate()
  f.script.engineHandlers.onObjectActive({id = 'object'})
  f.script.engineHandlers.onNewExterior({id = 'cell'})
  expect(#f.named('tick') == 1 and #f.named('object') == 1 and #f.named('cell') == 1,
    'engine observations did not flow through the App')
  expect(f.script.engineHandlers.onSave().schemaVersion == 0 and #f.named('save') == 1,
    'save callback bypassed the direct App ledger codec')
end

local function eventsAreWakeupsAndAcknowledgements()
  local f = fixture()
  assert(f.script.engineHandlers.onInit())
  local external = 'external:harness:toggle_changed:key'
  f.script.eventHandlers[constants.events.guardEvent]({
    event = external,
    payload = {value = true},
  })
  f.script.eventHandlers[constants.events.guardEvent]({event = 'invalid'})
  local wakeups = f.named('event')
  expect(#wakeups == 1 and wakeups[1].values[1] == external
      and wakeups[1].values[2] == nil,
    'external guard payload became runtime truth or invalid event was queued')

  f.script.eventHandlers[constants.events.equipDone]({commandId = 'equip'})
  f.script.eventHandlers[constants.events.killDone]({commandId = 'kill'})
  expect(#f.named('ack') == 2, 'local command completion bypassed the App broker')
  f.script.eventHandlers[constants.events.questStageChanged]({questId = 'quest', newStage = 20})
  f.script.eventHandlers[constants.events.questStageSnapshot]({questId = 'quest', stage = 10})
  f.script.eventHandlers[constants.events.questStageSnapshotChunk]({quests = {quest = 30}})
  expect(#f.named('quest') == 2 and #f.named('snapshot') == 1,
    'quest watcher events did not update authoritative App observations')
end

local function supportSurfaceUsesAppAuthority()
  local f = fixture()
  assert(f.script.engineHandlers.onInit())
  expect(f.script.interface.selfcheck().ok == true,
    'selfcheck did not validate App authority')
  local operationFilter = {
    operation = {
      family = 'kill_actor',
      targetKind = 'output',
      targetRecordId = 'rat',
    },
  }
  expect(f.script.interface.selfcheck(operationFilter).ok == true
      and f.named('selfcheck')[2].values[1] == operationFilter,
    'selfcheck did not forward its bounded operation filter to the App')
  local compile = f.script.interface.compileReport({log = false})
  expect(compile.summary.total == 2, 'compileReport omitted active schema-0 diagnostics')
  expectExactKeys(f.script.interface, {
    version = true,
    selfcheck = true,
    compileReport = true,
    logLevel = true,
  }, 'public interface')
end

local function callbackDiagnosticsRenderArrayErrors()
  local f = fixture({
    tickFailure = {
      'store_edit_changes_invalid',
      'editor did not return change metadata',
    },
  })
  assert(f.script.engineHandlers.onInit())
  f.script.engineHandlers.onUpdate()
  local message = nil
  for i = 1, #f.logged do
    local row = f.logged[i]
    if row[1] == 'diagnostic-error'
        and row[3] == 'runtime_tick_failed' then
      expect(row[2] == 'runtime-failed',
        'runtime callback used an unrelated diagnostic category')
      message = row[6]
      break
    end
  end
  expect(type(message) == 'string'
      and message:find('store_edit_changes_invalid', 1, true) ~= nil
      and message:find('editor did not return change metadata', 1, true) ~= nil,
    'entrypoint collapsed an array-shaped callback error to unknown error')
end

local function invalidLoadIsNotMisreportedAsQuarantine()
  local payload = {schemaVersion = 99, evidence = 'keep'}
  local f = fixture({loadFailure = true, savedPayload = payload})
  local loaded = f.script.engineHandlers.onLoad(payload)
  expect(loaded == false and f.app.runtime == nil and #f.named('bootstrap') == 0,
    'unsupported save started a mutating runtime')
  f.script.engineHandlers.onUpdate()
  expect(#f.named('tick') == 0, 'failed entrypoint ticked runtime work')
  expect(f.script.engineHandlers.onSave() == payload,
    'failed entrypoint did not preserve recovery evidence')
  local diagnostic = nil
  for i = 1, #f.logged do
    local row = f.logged[i]
    if row[1] == 'diagnostic-error' and row[3] == 'load_failed' then
      diagnostic = row
      break
    end
  end
  expect(diagnostic ~= nil
      and diagnostic[2] == 'saved-state-invalid'
      and tostring(diagnostic[6]):find('could not be loaded', 1, true),
    'invalid saved state was mislabeled as diagnostics-only quarantine')
end

local function unsupportedLoadReportsActualQuarantine()
  local payload = {schemaVersion = 99, evidence = 'keep'}
  local f = fixture({
    loadFailure = true,
    loadStatus = 'loaded-quarantined',
    savedPayload = payload,
  })
  expect(f.script.engineHandlers.onLoad(payload) == false,
    'unsupported saved state unexpectedly started a runtime')
  local diagnostic = nil
  for i = 1, #f.logged do
    local row = f.logged[i]
    if row[1] == 'diagnostic-error' and row[3] == 'load_quarantined' then
      diagnostic = row
      break
    end
  end
  expect(diagnostic ~= nil
      and diagnostic[2] == 'saved-state-invalid'
      and tostring(diagnostic[6]):find('diagnostics-only quarantine', 1, true),
    'unsupported saved state lost its quarantine diagnostic')
end

local CASES = {
  {'sole-owner lifecycle', soleOwnerLifecycle},
  {'payload-free events', eventsAreWakeupsAndAcknowledgements},
  {'status API', supportSurfaceUsesAppAuthority},
  {'array callback diagnostics', callbackDiagnosticsRenderArrayErrors},
  {'structured compiler rejection', structuredCompileRejectionReachesSupportSurface},
  {'saved state is not compiler input', savedStateDoesNotAffectCompilerInputs},
  {'invalid load diagnostic', invalidLoadIsNotMisreportedAsQuarantine},
  {'unsupported load quarantine', unsupportedLoadReportsActualQuarantine},
}

function M.run()
  return test_support.runCases('pure entrypoint', CASES)
end

return M
