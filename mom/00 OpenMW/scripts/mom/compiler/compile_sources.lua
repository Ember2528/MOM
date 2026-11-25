-- Atomic startup compiler. Every discovered source belongs to one candidate:
-- the complete current source set either produces one manifest or no authority
-- is installed.
local M = {}

local compile_context = require('scripts.mom.compiler.compile_context')
local compile_result = require('scripts.mom.contracts.compiler_result')
local compile_diagnostics = require('scripts.mom.diagnostics.compile_diagnostics')
local diagnostic_emit = require('scripts.mom.compiler.diagnostic_emit')
local extension_catalog_contract =
  require('scripts.mom.contracts.extension_catalog')
local log = require('scripts.mom.diagnostics.log')
local source_lowering = require('scripts.mom.compiler.source_lowering')
local compile_manifest =
  require('scripts.mom.compiler.compile_manifest')

local bounds = require('scripts.mom.diagnostics.bounds')
local boundedText = bounds.text

local function failure(code, label, errors)
  local details, truncated, errorCount = bounds.sample(errors, nil, boundedText)
  return {
    code = code,
    message = boundedText(label or 'compile failed'),
    errors = details,
    errorCount = errorCount,
    errorsTruncated = truncated,
  }
end

local function appendCompileFailure(collector, message, sourcePath, code)
  local category = 'compiler-contract'
  local text = tostring(message)
  if text:find('%.program', 1, false) then
    category = 'program-invalid'
  elseif text:find('select', 1, true)
      and text:find('unresolved', 1, true) then
    category = 'selector-unresolved'
  end
  diagnostic_emit.append(collector, {
    category = category,
    severity = 'error',
    phase = 'compile',
    sourcePath = sourcePath,
    code = code or category:gsub('-', '_'),
    message = text,
  })
end

local function appendSourceFailure(collector, attempt, failure)
  local status = attempt.error and attempt.error.status
  local category, phase = 'config-invalid', 'compile'
  if status == 'load_error' then
    category, phase = 'source-load-failed', 'load'
  elseif status == 'translate_error' then
    phase = 'import'
  end
  diagnostic_emit.append(collector, {
    category = category,
    severity = 'error',
    phase = phase,
    sourcePath = attempt.sourcePath,
    code = failure.code,
    message = failure.message,
  })
end

local function emptyQueries()
  return {
    recordIds = {},
    meshPathTypes = {},
  }
end

local function mergeBooleanSet(target, source)
  for key, value in pairs(source or {}) do
    if value == true then target[key] = true end
  end
end

local function mergeMeshTypeSets(target, source)
  for meshPath, sourceTypes in pairs(source or {}) do
    local targetTypes = target[meshPath]
    if targetTypes ~= true then
      if sourceTypes == true then
        target[meshPath] = true
      elseif type(sourceTypes) == 'table' then
        if type(targetTypes) ~= 'table' then
          targetTypes = {}
          target[meshPath] = targetTypes
        end
        mergeBooleanSet(targetTypes, sourceTypes)
      end
    end
  end
end

local function mergeQueries(target, source)
  source = source or {}
  mergeBooleanSet(target.recordIds, source.recordIds)
  mergeMeshTypeSets(target.meshPathTypes, source.meshPathTypes)
end

local function normalizeAttemptFailure(attempt, code, errors)
  local details, truncated, errorCount = bounds.sample(errors, nil, boundedText)
  local message = #details > 0 and table.concat(details, ' | ') or tostring(code)
  return {
    code = tostring(code),
    message = boundedText(message),
    errors = details,
    errorCount = errorCount,
    errorsTruncated = truncated,
    sourcePath = attempt and attempt.sourcePath or nil,
  }
end

local function failureFromAttempt(attempt)
  local sourceError = attempt and attempt.error or {}
  return normalizeAttemptFailure(
    attempt,
    sourceError.kind or sourceError.status or 'source_failed',
    {
      sourceError.message
        or sourceError.kind
        or sourceError.status
        or 'source failed',
    }
  )
end

local function rejected(cfg, collector, fatal, states, context)
  return compile_result.rejected({
    diagnostics = compile_diagnostics.forCompile(collector, {
      sourceAttempts = type(cfg) == 'table' and cfg.sourceAttempts or nil,
      sourceStates = states,
      compileContext = compile_context.metrics(context),
    }),
    fatal = fatal,
  })
end

local function sourceIdentity(attempt)
  local adapterId = type(attempt) == 'table' and attempt.adapterId or nil
  local path = type(attempt) == 'table'
      and (attempt.path or attempt.sourcePath) or nil
  if type(adapterId) ~= 'string' or adapterId == ''
      or type(path) ~= 'string' or path == '' then
    return nil
  end
  return adapterId .. '\0' .. path:gsub('\\', '/'):lower()
end

local function appendCompatSkipWarning(collector, sourcePath, message)
  diagnostic_emit.append(collector, {
    category = 'import-warning',
    severity = 'warn',
    phase = 'compile',
    sourcePath = sourcePath,
    code = 'compat_source_skipped',
    message = tostring(message),
  })
  log.warn('compat', '%s: %s; skipped by compatErrorPolicy=skip',
    tostring(sourcePath or '<compat>'), tostring(message))
end

local function prepareSources(cfg, catalog, collector)
  local states = {}
  local queries = emptyQueries()
  local seen = {}
  local failures = {}
  local sourceKeys = {}
  local skipCompat = cfg.compatErrorPolicy == 'skip'
  for i = 1, #(cfg.sourceAttempts or {}) do
    local attempt = cfg.sourceAttempts[i]
    local state = {attempt = type(attempt) == 'table' and attempt or {}}
    states[i] = state
    if type(attempt) ~= 'table' then
      state.failure = normalizeAttemptFailure(state.attempt, 'source_attempt_invalid', {
        'source attempt must be an object',
      })
    else
      local identity = sourceIdentity(attempt)
      if identity == nil then
        state.failure = normalizeAttemptFailure(attempt, 'source_identity_invalid', {
          'source attempt requires adapterId and path',
        })
      elseif seen[identity] then
        state.failure = normalizeAttemptFailure(attempt, 'source_identity_duplicate', {
          'duplicate current source ' .. tostring(attempt.path or attempt.sourcePath),
        })
      else
        seen[identity] = true
        if attempt.status ~= 'resolved' then
          state.failure = failureFromAttempt(attempt)
        else
          state.actionCount = type(attempt.actions) == 'table'
            and #attempt.actions or 0
          local attemptKeys = {}
          for k, v in pairs(sourceKeys) do attemptKeys[k] = v end
          local prepared, sourceQueries, prepareErrors =
            source_lowering.prepareActions(attempt.actions, catalog, {sourceKeys = attemptKeys})
          attempt.actions = nil
          if prepared == nil then
            state.failure = normalizeAttemptFailure(
              attempt,
              'source_prepare_failed',
              prepareErrors
            )
          else
            sourceKeys = attemptKeys
            state.prepared = prepared
            state.actionCount = #prepared
            mergeQueries(queries, sourceQueries)
          end
        end
      end
    end
    if state.failure ~= nil then
      if skipCompat and state.attempt.kind == 'compat' then
        appendCompatSkipWarning(collector, state.attempt.sourcePath or state.attempt.path, state.failure.message)
        state.failure = nil
        state.prepared = {}
        state.actionCount = 0
        state.disposition = 'skipped'
      else
        state.disposition = 'failed'
        failures[#failures + 1] = state.failure.message
        if state.attempt.status == 'failed' and state.attempt.error ~= nil then
          appendSourceFailure(collector, state.attempt, state.failure)
        else
          appendCompileFailure(
            collector,
            state.failure.message,
            state.attempt.sourcePath,
            state.failure.code
          )
        end
      end
    else
      state.disposition = 'prepared'
    end
  end
  if #failures > 0 then return nil, states, failures end
  return queries, states, nil
end

local function compileCurrentSources(cfg, catalog, collector)
  local queries, states, prepareErrors = prepareSources(cfg, catalog, collector)
  if queries == nil then
    return rejected(
      cfg,
      collector,
      failure(
        'source_set_rejected',
        'one or more current sources were rejected',
        prepareErrors
      ),
      states
    )
  end

  -- Context construction is total: every expensive host view remains lazy and
  -- reports through its accessor when a family requests it.
  local context = compile_context.build(queries, {
    diagnosticCollector = collector,
  })

  local actions = {}
  local lowerFailures = {}
  local skipCompat = cfg.compatErrorPolicy == 'skip'
  for i = 1, #states do
    local state = states[i]
    if state.disposition == 'skipped' then
      state.prepared = nil
    else
      local normalized, lowerErrors = source_lowering.lowerActions(
        state.prepared,
        context,
        catalog
      )
      state.prepared = nil
      if normalized == nil then
        local lowerFailure = normalizeAttemptFailure(
          state.attempt,
          'source_lowering_failed',
          lowerErrors
        )
        if skipCompat and state.attempt.kind == 'compat' then
          appendCompatSkipWarning(collector, state.attempt.sourcePath or state.attempt.path, lowerFailure.message)
          state.disposition = 'skipped'
          state.actionCount = 0
        else
          state.failure = lowerFailure
          state.disposition = 'failed'
          appendCompileFailure(
            collector,
            state.failure.message,
            state.attempt.sourcePath,
            state.failure.code
          )
          lowerFailures[#lowerFailures + 1] = state.failure.message
        end
      else
        state.disposition = 'accepted'
        state.actionCount = #normalized.actions
        for j = 1, #normalized.actions do
          actions[#actions + 1] = normalized.actions[j]
        end
      end
    end
  end
  if #lowerFailures > 0 then
    return rejected(
      cfg,
      collector,
      failure(
        'source_set_rejected',
        'one or more current sources were rejected',
        lowerFailures
      ),
      states,
      context
    )
  end

  local manifest, manifestErrors = compile_manifest.compileOwned(
    {actions = actions},
    context,
    catalog
  )
  if manifest == nil then
    for i = 1, #(manifestErrors or {}) do
      appendCompileFailure(collector, manifestErrors[i])
    end
    return rejected(
      cfg,
      collector,
      failure(
        'manifest_rejected',
        'aggregate manifest validation failed',
        manifestErrors
      ),
      states,
      context
    )
  end

  local diagnostics = compile_diagnostics.forCompile(collector, {
    manifest = manifest,
    sourceAttempts = cfg.sourceAttempts,
    sourceStates = states,
    compileContext = compile_context.metrics(context),
  })
  log.debug(
    'compile',
    'Compiled atomic manifest sources=%d actions=%d owners=%d',
    #states,
    #manifest.actionIds,
    #manifest.ownerIds
  )
  return compile_result.accepted({
    manifest = manifest,
    diagnostics = diagnostics,
  })
end

local function compile(cfg, catalog)
  local collector = type(cfg) == 'table' and cfg.diagnosticCollector
    or compile_diagnostics.new()
  if type(cfg) ~= 'table' or type(cfg.sourceAttempts) ~= 'table' then
    local errors = {
      'compiler input must contain the current sourceAttempts array',
    }
    appendCompileFailure(collector, errors[1])
    return rejected(
      cfg,
      collector,
      failure(
        'source_attempts_required',
        'current source input is required',
        errors
      ),
      {}
    )
  end
  local catalogOk, catalogErrors = extension_catalog_contract.validate(catalog)
  if not catalogOk then
    for i = 1, #(catalogErrors or {}) do
      appendCompileFailure(collector, catalogErrors[i])
    end
    return rejected(
      cfg,
      collector,
      failure(
        'extension_catalog_invalid',
        'extension catalog is invalid',
        catalogErrors
      ),
      {}
    )
  end
  for _, registryName in ipairs({'actions', 'guards', 'compat'}) do
    local registry = catalog[registryName]
    for i = 1, #((registry and registry.quarantineDiagnostics) or {}) do
      local item = registry.quarantineDiagnostics[i]
      diagnostic_emit.append(collector, {
        category = 'support-warning',
        severity = 'warn',
        phase = 'support',
        sourcePath = item.path,
        family = item.id,
        path = item.path,
        code = item.code or 'extension_quarantined',
        message = string.format(
          '%s extension quarantined: %s',
          tostring(registryName),
          tostring(item.message or item.code or 'invalid extension')
        ),
      })
    end
  end
  return compileCurrentSources(cfg, catalog, collector)
end

M.compile = compile

return M
