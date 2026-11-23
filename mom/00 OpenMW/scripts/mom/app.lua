-- Owns MOM lifecycle: save decode, startup bootstrap, engine callbacks, and
-- bounded diagnostics. OpenMW entrypoint forwards all handlers into this object.
local M = {}

local app_diagnostics = require('scripts.mom.runtime.app_diagnostics')
local compile_result = require('scripts.mom.contracts.compiler_result')
local error_message = require('scripts.mom.diagnostics.error_message')
local ledger_api = require('scripts.mom.ledger.ledger')
local plain_data = require('scripts.mom.contracts.plain_data')
local runtime_api = require('scripts.mom.runtime.coordinator')
local strings = require('scripts.mom.common.strings')

local nonEmpty = strings.isNonEmpty
local lower = strings.lowerString

local function failure(code, message, errors)
  return {
    code = code,
    message = tostring(message or code),
    errors = errors or {},
  }
end

local function normalizeFailure(label, value)
  if type(value) == 'table' and (value.code ~= nil or value.message ~= nil) then
    return value
  end
  local details = {}
  if value ~= nil then
    details[1] = error_message.message(value, label .. ' failed')
  end
  return failure(label .. '_failed', label .. ' failed', details)
end

local function rememberCandidateRejection(app, value)
  local retained, retainErrors = app_diagnostics.retainRejectedCandidate(value)
  if retained == nil then
    return nil, failure('candidate_rejection_invalid',
      'rejected candidate diagnostics are invalid', retainErrors)
  end
  local detached, errors = plain_data.detach({
    status = 'rejected',
    diagnostics = retained.diagnostics,
    fatal = retained.fatal,
    diagnosticsTruncated = retained.diagnosticsTruncated,
  }, {path = 'lastRejectedCandidate'})
  if detached == nil then
    return nil, failure('candidate_rejection_invalid',
      'rejected candidate diagnostics are not plain data', errors)
  end
  app.lastRejectedCandidate = detached
  return detached, nil
end

local function validateCandidate(value)
  if not compile_result.isAccepted(value) then
    return nil, failure('candidate_invalid', 'startup candidate was not accepted')
  end
  if type(value.manifest) ~= 'table' or not nonEmpty(value.manifest.contentHash) then
    return nil, failure('candidate_invalid', 'startup candidate omitted valid manifest')
  end
  local catalog = value.extensionCatalog
  if type(catalog) ~= 'table' or catalog.kind ~= 'mom-extension-catalog'
      or type(catalog.actions) ~= 'table' or type(catalog.guards) ~= 'table' then
    return nil, failure('candidate_invalid', 'startup candidate omitted extension catalog')
  end
  return value, nil
end

local function resetRuntime(app)
  if app.runtime ~= nil then
    pcall(runtime_api.clear, app.runtime)
  elseif app.engineSession ~= nil and type(app.engineSession.clear) == 'function' then
    pcall(app.engineSession.clear, app.engineSession)
  end
  app.runtime = nil
  app.engineSession = nil
  app.activeDiagnostics = nil
  app.activeManifestHash = nil
  return true, nil
end

function M.new(opts)
  opts = opts or {}
  if type(opts.engineSessionFactory) ~= 'table'
      or type(opts.engineSessionFactory.open) ~= 'function' then
    return nil, {'Engine session factory with open() is required'}
  end
  return {
    engineSessionFactory = opts.engineSessionFactory,
    unknownRetryDelay = opts.unknownRetryDelay,
    frame = math.max(0, math.floor(tonumber(opts.currentFrame) or 0)),
    loadedLedger = ledger_api.new(),
    loadMetadata = nil,
    preservedPayload = nil,
    runtime = nil,
    engineSession = nil,
    activeDiagnostics = nil,
    activeManifestHash = nil,
    lastRejectedCandidate = nil,
    startupReport = nil,
    status = 'new',
    lastError = nil,
    pendingQuestStages = {},
    questSnapshotReady = false,
  }, nil
end

function M.load(app, payload)
  if type(app) ~= 'table' then return nil, failure('app_invalid', 'App is invalid') end
  resetRuntime(app)
  app.frame = 0
  app.lastError = nil
  app.preservedPayload = nil
  app.lastRejectedCandidate = nil
  app.pendingQuestStages = {}
  app.questSnapshotReady = false

  local ledger, metadata = ledger_api.decode(payload)
  if ledger == nil then
    app.loadedLedger = nil
    app.loadMetadata = metadata
    app.preservedPayload = metadata and metadata.raw or payload
    app.lastError = metadata
    app.status = 'loaded-quarantined'
    return nil, metadata
  end
  app.loadedLedger = ledger
  app.frame = ledger:frame()
  app.loadMetadata = metadata
  app.status = 'loaded'
  return metadata, nil
end

function M.bootstrap(app, candidateValue)
  if type(app) ~= 'table' then return nil, failure('app_invalid', 'App is invalid') end
  if app.runtime ~= nil then
    return nil, failure('runtime_active', 'MOM already installed its startup plan')
  end
  if app.loadedLedger == nil or app.status == 'loaded-quarantined' then
    return nil, app.lastError or failure('saved_state_unsupported',
      'Saved MOM state is in diagnostics-only quarantine')
  end
  app.startupReport = app_diagnostics.startupReport(
    type(candidateValue) == 'table' and candidateValue.startup or nil)

  if compile_result.isRejected(candidateValue) then
    local remembered, rememberError = rememberCandidateRejection(app, candidateValue)
    if remembered == nil then
      app.lastError = rememberError
      app.status = 'bootstrap-failed'
      return nil, rememberError
    end
    app.lastError = normalizeFailure('candidate_compile', candidateValue.fatal)
    app.status = 'bootstrap-failed'
    return nil, app.lastError
  end

  local value, candidateErr = validateCandidate(candidateValue)
  if value == nil then
    app.lastError = candidateErr
    app.status = 'bootstrap-failed'
    return nil, candidateErr
  end

  local activationBundle, prepErr = runtime_api.prepareActivation({
    manifest = value.manifest,
    extensionCatalog = value.extensionCatalog,
    unknownRetryDelay = app.unknownRetryDelay,
  })
  if activationBundle == nil then
    app.lastError = failure('activation_prepare_failed',
      table.concat(prepErr or {'activation preparation failed'}, ' | '), prepErr)
    app.status = 'bootstrap-failed'
    return nil, app.lastError
  end

  local okOpen, session, sessionErr = pcall(app.engineSessionFactory.open, app.engineSessionFactory, {
    manifest = value.manifest,
    guardProviderInterfaces = activationBundle.guardProviderInterfaces,
    currentFrame = app.frame,
  })
  if not okOpen or session == nil then
    app.lastError = normalizeFailure('engine_session_open', okOpen and sessionErr or session)
    app.status = 'bootstrap-failed'
    return nil, app.lastError
  end

  local previsitCells = session.previsitCells and session:previsitCells(value.manifest, app.frame) or {}
  if app.questSnapshotReady and session.replaceQuestSnapshot then
    session:replaceQuestSnapshot(app.pendingQuestStages)
  end

  local runtime, runtimeErr = runtime_api.new({
    activationBundle = activationBundle,
    ledger = app.loadedLedger,
    session = session,
    previsitCells = previsitCells,
    currentFrame = app.frame,
  })
  if runtime == nil then
    if session.clear then pcall(session.clear, session) end
    app.lastError = normalizeFailure('runtime_create', runtimeErr)
    app.status = 'bootstrap-failed'
    return nil, app.lastError
  end

  app.runtime = runtime
  app.engineSession = session
  app.preservedPayload = nil
  app.activeDiagnostics = value.diagnostics
  app.activeManifestHash = value.manifest.contentHash
  app.status = 'running'
  app.lastError = nil
  return {
    status = app.status,
    manifestHash = value.manifest.contentHash,
  }, nil
end

function M.noteStartup(app, status)
  app.startupReport = app_diagnostics.startupReport(status)
end

function M.tick(app, requestedFrame)
  if type(app) ~= 'table' or app.runtime == nil then
    return nil, failure('runtime_unavailable', 'App runtime is unavailable')
  end
  local frame = requestedFrame == nil and (app.frame + 1) or requestedFrame
  if type(frame) ~= 'number' or frame < app.frame or frame % 1 ~= 0 then
    return nil, failure('frame_invalid', 'App frame must be a monotonic non-negative integer')
  end
  local report, err = runtime_api.tick(app.runtime, {frame = frame})
  if report == nil then
    app.lastError = normalizeFailure('runtime_tick', err)
    return nil, app.lastError
  end
  app.frame = report.frame
  app.lastError = nil
  return report, nil
end

function M.observeObject(app, object)
  if type(app) ~= 'table' or app.runtime == nil then
    return nil, failure('runtime_unavailable', 'App runtime is unavailable')
  end
  return runtime_api.observeObject(app.runtime, object, app.frame)
end

function M.observeCell(app, cell)
  if type(app) ~= 'table' or app.runtime == nil then
    return nil, failure('runtime_unavailable', 'App runtime is unavailable')
  end
  return runtime_api.observeCell(app.runtime, cell, app.frame)
end

function M.enqueueEvent(app, name)
  if type(app) ~= 'table' or app.runtime == nil then
    return nil, failure('runtime_unavailable', 'App runtime is unavailable')
  end
  if not nonEmpty(name) then
    return nil, failure('event_invalid', 'Event name is invalid')
  end
  return runtime_api.enqueueEvent(app.runtime, name)
end

function M.replaceQuestSnapshot(app, quests)
  if type(app) ~= 'table' then return nil, failure('app_invalid', 'App is invalid') end
  local detached, detachErrors = plain_data.detach(quests or {}, {path = 'questSnapshot'})
  if not detached then
    return nil, failure('quest_snapshot_invalid', 'Quest snapshot is not plain data', detachErrors)
  end
  app.pendingQuestStages = detached
  app.questSnapshotReady = true
  if app.engineSession == nil then return true, nil end
  app.engineSession:replaceQuestSnapshot(detached)
  return M.enqueueEvent(app, 'questStageChanged')
end

function M.updateQuestStage(app, questId, stage)
  if type(app) ~= 'table' then return nil, failure('app_invalid', 'App is invalid') end
  local normalizedId, normalizedStage = lower(questId), tonumber(stage)
  if normalizedId == nil or normalizedStage == nil then
    return nil, failure('quest_stage_invalid', 'Quest stage update is invalid')
  end
  app.pendingQuestStages[normalizedId] = normalizedStage
  app.questSnapshotReady = true
  if app.engineSession == nil then return true, nil end
  app.engineSession:updateQuestStage(normalizedId, normalizedStage)
  return M.enqueueEvent(app, 'questStageChanged:' .. normalizedId)
end

function M.acknowledgeLocal(app, payload)
  if type(app) ~= 'table' or app.runtime == nil then
    return nil, failure('runtime_unavailable', 'App runtime is unavailable')
  end
  return runtime_api.acknowledgeLocal(app.runtime, payload)
end

function M.save(app)
  if type(app) ~= 'table' then return nil, failure('app_invalid', 'App is invalid') end
  if app.runtime ~= nil then
    return runtime_api.saveSnapshot(app.runtime)
  end
  if app.preservedPayload ~= nil then
    local preserved, preserveErrors = plain_data.detach(app.preservedPayload, {path = 'preservedSave'})
    if not preserved then
      return nil, failure('preserved_save_invalid', 'Saved payload is not plain data', preserveErrors)
    end
    return preserved, {status = 'preserved'}
  end
  local ledger = app.loadedLedger or ledger_api.new()
  return ledger:save()
end

function M.compileReport(app)
  return app_diagnostics.compileReport(app)
end

function M.selfcheck(app, options)
  return app_diagnostics.selfcheck(app, options)
end

return M
