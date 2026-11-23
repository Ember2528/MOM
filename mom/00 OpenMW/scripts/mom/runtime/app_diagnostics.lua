-- Builds bounded selfcheck and compileReport projections for App.
local M = {}

local bounds = require('scripts.mom.diagnostics.bounds')
local compile_diagnostics = require('scripts.mom.diagnostics.compile_diagnostics')
local manifest_contract = require('scripts.mom.contracts.manifest_contract')
local plain_data = require('scripts.mom.contracts.plain_data')
local runtime_api = require('scripts.mom.runtime.coordinator')

local STATUS_LIMIT = bounds.SAMPLE_LIMIT
local STATUS_MESSAGE_LIMIT = bounds.TEXT_LIMIT
local boundedArray = bounds.sample

local function boundedText(value)
  if value ~= nil then return bounds.text(value) end
  return nil
end

local function failure(code, message, errors)
  return {
    code = code,
    message = tostring(message or code),
    errors = errors or {},
  }
end

function M.startupReport(value)
  if type(value) ~= 'table' then return nil end
  local content = type(value.content) == 'table' and value.content or {}
  local out = {
    version = value.version,
    status = value.status,
    sourceHash = value.sourceHash,
    message = tostring(value.message or ''):sub(1, STATUS_MESSAGE_LIMIT),
    content = {
      status = content.status,
      contentHash = content.contentHash,
    },
  }
  for _, key in ipairs({'changedCount', 'noopCount', 'createdCount', 'attemptedWrites'}) do
    if type(content[key]) == 'number' then out.content[key] = content[key] end
  end
  return out
end

local function boundedFailure(value)
  if type(value) ~= 'table' then return value end
  local issues, issuesTruncated = boundedArray(value.issues, STATUS_LIMIT)
  local errors, errorsTruncated = boundedArray(value.errors, STATUS_LIMIT)
  errorsTruncated = errorsTruncated or value.errorsTruncated == true
  return {
    code = value.code,
    status = value.status,
    message = boundedText(value.message),
    errors = errors,
    errorCount = value.errorCount or #(value.errors or {}),
    issues = issues,
    issueCount = value.blockingIssueCount or #(value.issues or {}),
    retainedIssueCount = value.retainedIssueCount or #(value.retainedIssues or {}),
    truncated = issuesTruncated or errorsTruncated or value.issuesTruncated == true
      or value.truncated == true,
  }
end

local function boundedRejectedCandidate(value, limit)
  if type(value) ~= 'table' then return nil, false, nil end
  local diagnostics, diagnosticsTruncated, errors = compile_diagnostics.forStatus(value.diagnostics, limit)
  if errors ~= nil then return nil, false, errors end
  local fatal, fatalErrors = plain_data.detach(boundedFailure(value.fatal), {
    path = 'compileReport.lastRejected.fatal',
  })
  if fatalErrors ~= nil then return nil, false, fatalErrors end
  local report = diagnostics or {}
  report.status = 'rejected'
  report.fatal = fatal
  return report, diagnosticsTruncated or (fatal and fatal.truncated == true) or false, nil
end

function M.retainRejectedCandidate(value)
  if type(value) ~= 'table' then return nil, false end
  local diagnostics, diagnosticsTruncated, errors = compile_diagnostics.forStatus(value.diagnostics, STATUS_LIMIT)
  if errors ~= nil then return nil, errors end
  local fatal = boundedFailure(value.fatal)
  return {
    status = 'rejected',
    diagnostics = diagnostics,
    fatal = fatal,
    diagnosticsTruncated = diagnosticsTruncated or (fatal and fatal.truncated == true) or false,
  }, nil
end

local function boundedLoad(value)
  if type(value) ~= 'table' then return value end
  return {
    status = value.status,
    code = value.code,
    message = value.message,
    installation = boundedFailure(value.installation),
  }
end

local function auditLedger(app)
  if app.runtime ~= nil then
    return runtime_api.audit(app.runtime)
  end
  if app.loadedLedger ~= nil then
    return app.loadedLedger:audit()
  end
  return nil, {app.lastError or failure('ledger_unavailable', 'App ledger is unavailable')}
end

local function buildCompileReport(app)
  if type(app) ~= 'table' then return nil, failure('app_invalid', 'App is invalid') end
  local active, truncated, activeErrors = compile_diagnostics.forStatus(app.activeDiagnostics, STATUS_LIMIT)
  if activeErrors ~= nil then return nil, nil, activeErrors end
  local lastRejected, rejectedTruncated, rejectedErrors = boundedRejectedCandidate(
    app.lastRejectedCandidate, STATUS_LIMIT)
  if rejectedErrors ~= nil then return nil, nil, rejectedErrors end
  local report, errors = plain_data.detach({
    status = app.status,
    activeManifestHash = app.activeManifestHash,
    lastError = boundedFailure(app.lastError),
    diagnosticsTruncated = truncated or rejectedTruncated,
    limit = STATUS_LIMIT,
  }, {path = 'compileReport'})
  if errors ~= nil then return nil, nil, errors end
  report.active = active
  report.summary = active and plain_data.cloneValidated(active.summary) or nil
  report.lastRejected = lastRejected
  report.startup = app.startupReport and plain_data.cloneValidated(app.startupReport) or nil
  return report, nil, nil
end

function M.compileReport(app)
  local report, reportError, projectionErrors = buildCompileReport(app)
  if projectionErrors ~= nil then
    return nil, failure('compile_report_invalid', 'Compile report is invalid', projectionErrors)
  end
  return report, reportError
end

function M.selfcheck(app, options)
  if type(app) ~= 'table' then return nil, failure('app_invalid', 'App is invalid') end
  if options ~= nil and type(options) ~= 'table' then
    return nil, failure('selfcheck_options_invalid', 'Selfcheck options must be a table')
  end
  local runtimeStatus, runtimeError = nil, nil
  if app.runtime ~= nil then
    runtimeStatus = runtime_api.status(app.runtime, options)
  elseif app.dormant == true then
    local scansComplete = 0
    for _ in pairs(app.loadedLedger and app.loadedLedger.doc.staticScans or {}) do
      scansComplete = scansComplete + 1
    end
    runtimeStatus = {
      manifestHash = app.activeManifestHash,
      dormant = true,
      limit = STATUS_LIMIT,
      blockers = {count = 0, samples = {}},
      operationWork = {count = 0, samples = {}},
      counts = {
        liveOperations = 0,
        pendingOperations = 0,
        scheduledOperations = 0,
        activeCommands = 0,
        awaitingCompletions = 0,
        operationTombstones = 0,
        operationLifecycles = {static = 0, state = 0},
        staticFailures = 0,
        staticScans = {complete = scansComplete},
      },
      queues = {
        staticCells = 0,
        state = {pendingOwners = 0},
      },
      errors = {},
    }
  end
  local ledgerOk, ledgerErrors = auditLedger(app)
  local manifestOk, manifestErrors = nil, nil
  local activeManifest = (app.runtime ~= nil and app.runtime.manifest) or app.dormantManifest
  if activeManifest ~= nil then
    manifestOk, manifestErrors = manifest_contract.validate(activeManifest)
  end
  local boundedLedgerErrors, ledgerErrorsTruncated = boundedArray(ledgerErrors or {}, STATUS_LIMIT)
  local boundedManifestErrors, manifestErrorsTruncated = boundedArray(manifestErrors or {}, STATUS_LIMIT)
  local compile, compileError, projectionErrors = buildCompileReport(app)
  if projectionErrors ~= nil then
    return nil, failure('selfcheck_invalid', 'Selfcheck is invalid', projectionErrors)
  end
  if compile == nil then return nil, compileError end
  local report = {
    ok = ledgerOk == true and manifestOk == true and runtimeStatus ~= nil and app.status == 'running',
    status = app.status,
    frame = app.frame,
    activeManifestHash = app.activeManifestHash,
    ledger = {
      ok = ledgerOk == true,
      errors = boundedLedgerErrors,
      errorsTruncated = ledgerErrorsTruncated,
    },
    manifest = {
      ok = manifestOk == true,
      errors = boundedManifestErrors,
      errorsTruncated = manifestErrorsTruncated,
    },
    runtime = runtimeStatus,
    runtimeError = runtimeError,
    load = boundedLoad(app.loadMetadata),
    startup = app.startupReport,
    lastError = boundedFailure(app.lastError),
    limit = STATUS_LIMIT,
  }
  local detached, errors = plain_data.detach(report, {path = 'selfcheck'})
  if detached == nil then
    return nil, failure('selfcheck_invalid', 'Selfcheck is invalid', errors)
  end
  detached.compile = compile
  return detached, nil
end

return M
