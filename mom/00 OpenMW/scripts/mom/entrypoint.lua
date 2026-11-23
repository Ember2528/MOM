-- Thin OpenMW-facing bridge around the one App instance. This module owns
-- startup inputs, callback adaptation, and the public interface.
local M = {}

local default_app_api = require('scripts.mom.app')
local compile_result = require('scripts.mom.contracts.compiler_result')
local default_constants = require('scripts.mom.constants')
local default_diagnostics = require('scripts.mom.diagnostics.sink')
local error_message = require('scripts.mom.diagnostics.error_message')
local default_guard_events = require('scripts.mom.contracts.guard_plugin')
local default_log = require('scripts.mom.diagnostics.log')

local function compileStartupCandidate(opts)
  return require('scripts.mom.compiler.startup_compile').installed(opts)
end

local errorText = error_message.message

local function copy(value)
  local out = {}
  for key, item in pairs(type(value) == 'table' and value or {}) do out[key] = item end
  return out
end

function M.new(opts)
  opts = opts or {}
  local app = opts.app
  local appApi = opts.appApi or default_app_api
  local constants = opts.constants or default_constants
  local diagnostics = opts.diagnostics or default_diagnostics
  local guardEvents = opts.guardEvents or default_guard_events
  local log = opts.log or default_log
  local candidateCompiler = opts.candidateCompiler or compileStartupCandidate
  local sourceOptions = copy(opts.sourceOptions)
  if type(app) ~= 'table' then return nil, 'entrypoint requires one App instance' end
  if type(candidateCompiler) ~= 'function' then
    return nil, 'entrypoint requires a startup candidate compiler'
  end

  local function emit(level, category, code, message)
    local fn = diagnostics and diagnostics[level] or nil
    if type(fn) == 'function' then
      fn(category, code, 'entry', '%s', tostring(message))
      return
    end
    fn = log and log[level] or nil
    if type(fn) == 'function' then fn('entry', '%s', tostring(message)) end
  end

  local function invoke(label, fn, ...)
    if type(fn) ~= 'function' then return nil, label .. ' is unavailable' end
    local ok, value, err = pcall(fn, app, ...)
    if not ok then return nil, tostring(value) end
    if value == nil or value == false then return nil, err or (label .. ' failed') end
    return value, err
  end

  local function bootstrap()
    local compileOptions = copy(sourceOptions)
    local ok, candidate, compileError = pcall(candidateCompiler, compileOptions)
    if not ok then
      candidate = compile_result.rejected({
        fatal = {
          code = 'candidate_compile_failed',
          message = tostring(candidate),
        },
      })
    elseif not compile_result.isAccepted(candidate)
        and not compile_result.isRejected(candidate) then
      candidate = compile_result.rejected({
        fatal = {
          code = 'candidate_compile_invalid',
          message = tostring(compileError or 'candidate compiler returned no result'),
        },
      })
    end
    local report, err = invoke('bootstrap', appApi.bootstrap, candidate)
    if not report then
      emit(
        'error',
        'compiler-contract',
        'bootstrap_failed',
        'MOM bootstrap failed: ' .. errorText(err)
      )
      return false, err
    end
    local compileDiagnostics = app.activeDiagnostics
    local summary = compileDiagnostics and compileDiagnostics.summary or {}
    log.info('bootstrap', 'MOM runtime active: manifest=%s actions=%d owners=%d',
      tostring(report.manifestHash),
      tonumber(summary.total) or 0,
      tonumber(summary.state and summary.state.owners) or 0)
    return true, report
  end

  local function initialize(payload, isLoad)
    if opts.candidateCompiler == nil and type(appApi.noteStartup) == 'function' then
      local status = require('scripts.mom.compiler.load_status').read()
      appApi.noteStartup(app, status)
    end
    local metadata, loadError = invoke('load', appApi.load, isLoad and payload or nil)
    if not metadata then
      local quarantined = app.status == 'loaded-quarantined'
      emit(
        'error',
        'saved-state-invalid',
        quarantined and 'load_quarantined' or 'load_failed',
        quarantined
          and ('Saved MOM state was preserved in diagnostics-only quarantine: '
            .. errorText(loadError))
          or ('Saved MOM state could not be loaded: ' .. errorText(loadError))
      )
      return false, loadError
    end
    return bootstrap()
  end

  local function supportFailure(code, err)
    emit('error', 'public-api-invalid', code, errorText(err))
    return {ok = false, status = app.status, error = err}
  end

  local function selfcheck(options)
    local report, err = invoke('selfcheck', appApi.selfcheck, options)
    if not report then return supportFailure('selfcheck_failed', err) end
    log.info('selfcheck', 'status=%s frame=%d ledger=%s manifest=%s',
      tostring(report.status),
      tonumber(report.frame) or 0,
      tostring(report.ledger and report.ledger.ok == true),
      tostring(report.manifest and report.manifest.ok == true))
    if report.ledger and report.ledger.ok ~= true then
      log.warn('selfcheck', 'ledger errors: %s', table.concat(report.ledger.errors or {}, ' | '))
    end
    return report
  end

  local function compileReport(options)
    local report, err = invoke('compileReport', appApi.compileReport)
    if not report then return supportFailure('compile_report_failed', err) end
    if type(options) ~= 'table' or options.log ~= false then
      local summary = report.summary or {}
      log.info('compile_report', 'status=%s manifest=%s actions=%d static=%d state=%d owners=%d',
        tostring(report.status),
        tostring(report.activeManifestHash),
        tonumber(summary.total) or 0,
        tonumber(summary.byClassification and summary.byClassification.static) or 0,
        tonumber(summary.byClassification and summary.byClassification.state) or 0,
        tonumber(summary.state and summary.state.owners) or 0)
    end
    return report
  end

  local function setLogLevel(level)
    local current, ok, valid = log.setLevel(level)
    if not ok then
      emit('warn', 'public-api-invalid', 'invalid_log_level',
        'Invalid log level ' .. tostring(level) .. '; valid levels: ' .. tostring(valid))
    end
    return current
  end

  local interface = {
    version = constants.interfaceVersion,
    selfcheck = selfcheck,
    compileReport = compileReport,
    logLevel = setLogLevel,
  }

  local function callback(label, fn, ...)
    local value, err = invoke(label, fn, ...)
    if not value then
      emit(
        'error',
        'runtime-failed',
        label .. '_failed',
        label .. ' failed: ' .. errorText(err)
      )
    end
    return value, err
  end

  local function event(name)
    return function(data)
      if app.runtime == nil then return end
      if name == constants.events.guardEvent then
        local eventName = type(data) == 'table' and data.event or nil
        if not guardEvents.isValidExternalEvent(eventName) then
          emit(
            'warn',
            'public-api-invalid',
            'guard_event_invalid',
            'Ignored malformed external guard wakeup'
          )
          return
        end
        callback('guard_event', appApi.enqueueEvent, eventName)
      elseif name == constants.events.equipDone or name == constants.events.killDone then
        callback('local_acknowledgement', appApi.acknowledgeLocal, data)
      elseif name == constants.events.questStageChanged then
        if type(data) == 'table' then
          callback('quest_stage_update', appApi.updateQuestStage, data.questId, data.newStage)
        end
      elseif name == constants.events.questStageSnapshot then
        if type(data) == 'table' then
          callback('quest_stage_snapshot', appApi.updateQuestStage, data.questId, data.stage)
        end
      elseif name == constants.events.questStageSnapshotChunk then
        callback('quest_snapshot_replace', appApi.replaceQuestSnapshot,
          type(data) == 'table' and data.quests or {})
      end
    end
  end

  return {
    interfaceName = constants.interfaceName,
    interface = interface,
    engineHandlers = {
      onInit = function() return initialize(nil, false) end,
      onLoad = function(savedData) return initialize(savedData, true) end,
      onUpdate = function()
        if app.runtime == nil then return end
        callback('runtime_tick', appApi.tick)
      end,
      onSave = function()
        local payload, err = invoke('save', appApi.save)
        if payload == nil then
          emit(
            'error',
            'persistence-failed',
            'save_failed',
            'MOM save failed: ' .. errorText(err)
          )
        end
        return payload
      end,
      onObjectActive = function(object)
        if app.runtime ~= nil then callback('object_observation', appApi.observeObject, object) end
      end,
      onNewExterior = function(cell)
        if app.runtime ~= nil then callback('cell_observation', appApi.observeCell, cell) end
      end,
    },
    eventHandlers = {
      [constants.events.guardEvent] = event(constants.events.guardEvent),
      [constants.events.equipDone] = event(constants.events.equipDone),
      [constants.events.killDone] = event(constants.events.killDone),
      [constants.events.questStageChanged] = event(constants.events.questStageChanged),
      [constants.events.questStageSnapshot] = event(constants.events.questStageSnapshot),
      [constants.events.questStageSnapshotChunk] = event(constants.events.questStageSnapshotChunk),
    },
  }, nil
end

return M
