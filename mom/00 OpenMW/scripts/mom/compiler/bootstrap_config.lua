local M = {}
local config_sources = require('scripts.mom.compiler.config_sources')
local compile_diagnostics = require('scripts.mom.diagnostics.compile_diagnostics')
local constants = require('scripts.mom.constants')
local plain_data = require('scripts.mom.contracts.plain_data')
local variant_resolver = require('scripts.mom.compiler.variant_resolver')
local log = require('scripts.mom.diagnostics.log')
local function normalizedDirList(primaryDir, extraDirs)
  local ordered = {}
  local seen = {}
  local function addDir(dir)
    if type(dir) ~= 'string' or dir == '' then
      return
    end
    local normalized = dir:gsub('\\', '/')
    local key = normalized:lower()
    if seen[key] then
      return
    end
    seen[key] = true
    ordered[#ordered + 1] = normalized
  end
  addDir(primaryDir)
  for _, dir in ipairs(extraDirs or {}) do
    addDir(dir)
  end
  return ordered
end
function M.resolveInputs(opts, catalog)
  opts = opts or {}
  local compatRegistry = catalog and catalog.compat or nil
  local configDir = opts.configDir or constants.configDir
  local compatConfigDirs = opts.compatConfigDirs or config_sources.configDirs(compatRegistry)
  local additionalConfigDirs = opts.configDirs or compatConfigDirs
  local configDirs = normalizedDirList(configDir, additionalConfigDirs)
  local configSources
  local usingExplicitList = false
  if type(opts.configPaths) == 'table' and #opts.configPaths > 0 then
    configSources = config_sources.fromPaths(opts.configPaths, compatRegistry)
    usingExplicitList = true
  elseif type(opts.configPath) == 'string' and opts.configPath ~= '' then
    configSources = config_sources.fromPaths({opts.configPath}, compatRegistry)
    usingExplicitList = true
  else
    configSources = config_sources.discover(configDirs, compatRegistry)
  end
  return {
    configDirs = configDirs,
    configSources = configSources,
    usingExplicitList = usingExplicitList,
  }
end
local function sourceKind(source, translatedByCompat)
  if translatedByCompat == true then
    return 'compat'
  end
  if source and source.native == true then
    return 'native'
  end
  if source and source.compat == true then
    return 'compat'
  end
  return 'unknown'
end
local function sourceAttempt(source, translatedByCompat)
  return {
    kind = sourceKind(source, translatedByCompat),
  }
end
local function sourcePath(source)
  local value = source and source.path or nil
  if type(value) ~= 'string' or value == '' then
    return nil, {
      kind = 'source-identity-invalid',
      message = 'source path must be a non-empty relative VFS path',
    }
  end
  local normalized = value:gsub('\\', '/')
  if normalized:sub(1, 1) == '/' or normalized:match('^%a:/') then
    return nil, {
      kind = 'source-identity-invalid',
      message = 'source path must be relative to the VFS root',
    }
  end
  local segments = {}
  for segment in normalized:gmatch('[^/]+') do
    if segment == '..' then
      return nil, {
        kind = 'source-identity-invalid',
        message = 'source path must not contain parent segments',
      }
    end
    if segment ~= '.' and segment ~= '' then
      segments[#segments + 1] = segment
    end
  end
  if #segments == 0 then
    return nil, {
      kind = 'source-identity-invalid',
      message = 'source path must not be empty',
    }
  end
  return table.concat(segments, '/'), nil
end

local function appendFailedAttempt(
    aggregated,
    source,
    status,
    err,
    adapterId,
    translatedByCompat)
  adapterId = adapterId or 'unknown'
  local normalizedPath, identityError = sourcePath(source)
  if identityError ~= nil then
    status = 'resolve_error'
    err = identityError
  end
  local attempt = sourceAttempt(source, translatedByCompat)
  attempt.adapterId = adapterId
  attempt.path = normalizedPath or (source and source.path or nil)
  attempt.sourcePath = source and source.path or nil
  attempt.status = 'failed'
  attempt.error = {
    status = status,
    kind = err and err.kind or status,
    message = err and err.message or status,
  }
  aggregated.sourceAttempts[#aggregated.sourceAttempts + 1] = attempt
end

local function appendResolvedAttempt(
    aggregated,
    source,
    adapterId,
    actions,
    translatedByCompat)
  local normalizedPath, identityError = sourcePath(source)
  if identityError ~= nil then
    appendFailedAttempt(
      aggregated,
      source,
      'resolve_error',
      identityError,
      adapterId,
      translatedByCompat
    )
    return nil
  end
  local detached, detachErrors = plain_data.detach(actions or {}, {
    path = 'sourceAttempt.actions',
  })
  if detached == nil then
    appendFailedAttempt(aggregated, source, 'resolve_error', {
      kind = 'source-actions-invalid',
      message = table.concat(detachErrors or {}, ' | '),
    }, adapterId, translatedByCompat)
    return nil
  end
  local attempt = sourceAttempt(source, translatedByCompat)
  attempt.adapterId = adapterId
  attempt.path = normalizedPath
  attempt.sourcePath = source and source.path or nil
  attempt.status = 'resolved'
  attempt.actions = detached
  aggregated.sourceAttempts[#aggregated.sourceAttempts + 1] = attempt
  return true
end

function M.loadAggregated(inputs, opts)
  opts = opts or {}
  local catalog = opts.catalog
  local compatRegistry = catalog and catalog.compat or nil
  local collector = opts.diagnosticCollector or compile_diagnostics.new()
  local aggregated = {
    sourceAttempts = {},
    loadInputs = {},
    diagnosticCollector = collector,
  }
  local variantContext = variant_resolver.createContext()
  local sources = assert(
    type(inputs.configSources) == 'table' and inputs.configSources,
    'bootstrap plan configSources are required'
  )
  if log.isEnabled and log.isEnabled('debug') then
    if inputs.usingExplicitList then
      log.debug('bootstrap', 'Loading %d config file(s) (explicit list)', #sources)
    else
      log.debug('bootstrap', 'Loading %d authored config file(s) from %s',
        #sources, table.concat(inputs.configDirs or {}, ', '))
    end
  end
  for _, source in ipairs(sources) do
    local path = source.path
    local preliminaryAdapterId, adapterError = config_sources.adapterId(source, compatRegistry)
    if adapterError then
      appendFailedAttempt(
        aggregated,
        source,
        'load_error',
        adapterError,
        preliminaryAdapterId or 'unknown'
      )
      log.error('bootstrap', 'Config %s adapter ownership failed: %s',
        tostring(path), tostring(adapterError.message or adapterError))
    else
      local rawCfg, loadErr = config_sources.loadRaw(source, compatRegistry)
      if loadErr and config_sources.sourcePolicy(source).onLoadError == 'skip' then
        appendResolvedAttempt(aggregated, source, preliminaryAdapterId, {}, true)
        collector:append({category = 'source-load-failed', severity = 'warn', phase = 'load',
          sourcePath = path, code = 'optional_source_skipped', message = tostring(loadErr.message or loadErr)})
        log.warn('source', '%s: %s; skipped by declared source admission policy',
          tostring(path), tostring(loadErr.message or loadErr))
      elseif loadErr then
        appendFailedAttempt(
          aggregated,
          source,
          'load_error',
          loadErr,
          preliminaryAdapterId
        )
        log.error('bootstrap', 'Config %s unavailable (%s): %s',
          tostring(path), tostring(loadErr.kind), tostring(loadErr.message))
      else
        local compatActions, translatedByCompat, translateErr, adapterId, sourceDiagnostics =
          config_sources.translateSource(source, rawCfg, compatRegistry)
        adapterId = adapterId or preliminaryAdapterId
          or (sourceKind(source, translatedByCompat) == 'native' and 'native' or 'unknown')
        if translateErr then
          appendFailedAttempt(
            aggregated,
            source,
            'translate_error',
            translateErr,
            adapterId,
            translatedByCompat
          )
          log.error('bootstrap', 'Config %s unavailable after compat translation (%s): %s',
            tostring(path), tostring(translateErr.kind), tostring(translateErr.message))
        elseif translatedByCompat then
          appendResolvedAttempt(aggregated, source, adapterId, compatActions, true)
          for _, message in ipairs(sourceDiagnostics or {}) do
            collector:append({category = 'config-invalid', severity = 'warn', phase = 'import',
              sourcePath = path, code = 'source_declaration_skipped', message = tostring(message)})
            log.warn('compat', '%s', tostring(message))
          end
        else
          local resolved, resolveErr = variant_resolver.resolve(rawCfg, {
            activeContent = variantContext.activeContent,
            sourcePath = path,
            adapterId = adapterId,
            guardRegistry = catalog and catalog.guards or nil,
            phase = opts.phase,
            deferPlacement = opts.deferPlacement,
          })
          if resolveErr then
            for _, input in ipairs(resolveErr.loadInputs or {}) do
              aggregated.loadInputs[#aggregated.loadInputs + 1] = input
            end
            appendFailedAttempt(
              aggregated,
              source,
              'resolve_error',
              resolveErr,
              adapterId
            )
            log.error('bootstrap', 'Config %s invalid after variant resolution (%s): %s',
              tostring(path), tostring(resolveErr.kind), tostring(resolveErr.message))
          else
            for _, input in ipairs(resolved.loadInputs or {}) do
              aggregated.loadInputs[#aggregated.loadInputs + 1] = input
            end
            appendResolvedAttempt(
              aggregated,
              source,
              adapterId,
              resolved.actions or {},
              false
            )
          end
        end
      end
    end
  end
  return aggregated
end
return M
