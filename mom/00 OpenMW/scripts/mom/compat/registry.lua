-- Deterministic compatibility translator registry. A foreign source is handled
-- by exactly one translator; native sources may remain unclaimed.
local M = {}

local diagnostic_log = require('scripts.mom.diagnostics.sink')
local error_message = require('scripts.mom.diagnostics.error_message')
local extension_registry = require('scripts.mom.compiler.extension_registry')
local source_action_contract = require('scripts.mom.compiler.source_action_contract')
local log = require('scripts.mom.diagnostics.log')
local vfs = require('openmw.vfs')

local COMPAT_ROOT = 'scripts/mom/compat'

-- Support files do not claim extension slots merely by living under compat;
-- only one translator.lua directly below a translator ID is discoverable.
function M.idForPath(path, root)
  local normalized = tostring(path or ''):gsub('\\', '/')
  local prefix = tostring(root or COMPAT_ROOT):gsub('\\', '/')
  return normalized:match('^' .. prefix .. '/([^/]+)/translator%.lua$')
end

local function pathToModule(path)
  path = path:gsub('\\', '/')
  path = path:gsub('%.lua$', '')
  return path:gsub('/', '.')
end

local function compatError(kind, message)
  return {
    kind = kind,
    message = tostring(message),
  }
end

local function discoverEntries()
  local entries = {}
  local errors = {}
  for rawPath in vfs.pathsWithPrefix(COMPAT_ROOT) do
    local path = tostring(rawPath or ''):gsub('\\', '/')
    if path:sub(-4) == '.lua' and path ~= COMPAT_ROOT .. '/registry.lua' then
      local expectedId = M.idForPath(path, COMPAT_ROOT)
      if expectedId then
        local moduleName = pathToModule(path)
        local ok, mod = pcall(require, moduleName)
        if not ok then
          errors[#errors + 1] = {
            code = 'extension_require_failed',
            path = path,
            expectedId = expectedId,
            message = string.format('failed requiring %s: %s', tostring(moduleName), tostring(mod)),
          }
        else
          entries[#entries + 1] = {
            path = path,
            expectedId = expectedId,
            module = mod,
          }
        end
      end
    end
  end
  return entries, errors
end

local function errorMessage(errors)
  return error_message.message(errors, 'compat registry error')
end

function M.buildRegistry()
  local entries, loadErrors = discoverEntries()
  local registry = assert(extension_registry.buildQuarantined('compat', entries, {
    supportedAbiVersion = 1,
    requiredMethods = {'translateSource'},
    exclusiveMethods = {'matchesPath', 'claims'},
    loadErrors = loadErrors,
  }))
  for i = 1, #(registry.quarantineDiagnostics or {}) do
    log.error('compat', 'Compat extension quarantined: %s',
      errorMessage({registry.quarantineDiagnostics[i]}))
  end
  log.debug('compat', 'Loaded compat handlers count=%d', #registry.ids)
  return registry
end

local function claimError(errors)
  local message = errorMessage(errors)
  diagnostic_log.error('config-invalid', 'compat-claim-failed', 'compat', '%s', message)
  return compatError(errors and errors[1] and errors[1].code or 'compat-claim-failed', message)
end

local function selectedRegistry(registry)
  assert(type(registry) == 'table' and registry.kind == 'compat',
    'compat registry requires an explicit compat extension registry')
  return registry
end

local function claimPath(path, registry)
  local claim, errors = extension_registry.claim(selectedRegistry(registry), path, {
    method = 'matchesPath',
    allowUnclaimed = true,
  })
  if errors then return nil, claimError(errors) end
  return claim, nil
end

local function claimSource(path, config, registry, pathClaim)
  local claim, errors = extension_registry.claim(selectedRegistry(registry), {
    path = path,
    config = config,
  }, {
    method = 'claims',
    allowUnclaimed = true,
    preclaimed = pathClaim,
    -- A translator with matchesPath() owns sources by path. Its result was
    -- already resolved during discovery, so only content-owned translators
    -- participate here. Seeding the selected path claim still preserves
    -- path/content ambiguity diagnostics.
    skipEntriesWithMethod = 'matchesPath',
  })
  if errors then return nil, claimError(errors) end
  return claim, nil
end

function M.configDirs(selected)
  local out = {}
  local seen = {}
  local registry = selectedRegistry(selected)
  for i = 1, #registry.ids do
    local mod = registry.byId[registry.ids[i]].module
    for j = 1, #((mod and mod.configDirs) or {}) do
      local dir = tostring(mod.configDirs[j])
      local key = dir:lower()
      if not seen[key] then
        seen[key] = true
        out[#out + 1] = dir
      end
    end
  end
  return out
end

function M.pathClaim(path, registry)
  return claimPath(path, registry)
end

function M.load(path, fallbackLoader, registry, selectedPathClaim)
  local claim, claimErr = selectedPathClaim, nil
  if claim == nil then claim, claimErr = claimPath(path, registry) end
  if claimErr then return nil, claimErr end
  local loader = claim and claim.module and claim.module.load or nil
  if type(loader) ~= 'function' then
    return fallbackLoader(path)
  end
  local ok, config, loadErr = pcall(loader, path)
  if not ok then
    diagnostic_log.error('source-load-failed', 'compat-load-failed', 'compat',
      'Compat loader %s failed for %s: %s', tostring(claim.id), tostring(path), tostring(config))
    return nil, compatError('compat-load-failed', config)
  end
  if loadErr ~= nil then
    diagnostic_log.error('source-load-failed', loadErr.kind or 'compat-load-failed', 'compat',
      'Compat loader %s rejected %s: %s',
      tostring(claim.id), tostring(path), tostring(loadErr.message or loadErr))
    return nil, loadErr
  end
  if type(config) ~= 'table' then
    diagnostic_log.error('compiler-contract', 'compat-load-invalid-return', 'compat',
      'Compat loader %s returned %s for %s', tostring(claim.id), type(config), tostring(path))
    return nil, compatError('compat-load-invalid-return', 'loader returned ' .. type(config))
  end
  return config, nil
end

function M.translateSource(source, registry, selectedPathClaim)
  local claim, claimErr = claimSource(
    source and source.path or nil,
    source and source.config or nil,
    registry,
    selectedPathClaim
  )
  if claimErr then return nil, false, claimErr end
  if not claim then return nil, false, nil end
  local ok, actions, translated, translateErr, diagnostics = pcall(claim.module.translateSource, source)
  if not ok then
    return nil, false, compatError('compat-source-translate-failed', actions), claim.id
  end
  if translateErr ~= nil then return nil, translated ~= false, translateErr, claim.id end
  if translated == false then return nil, false, nil, claim.id end
  local valid, validationErrors = source_action_contract.validateSourceActions(actions, {
    adapterId = claim.id,
    path = 'compatSource.actions',
    allowEmpty = claim.module.allowEmptySources == true,
  })
  if not valid then
    return nil, true, compatError(
      'compat-source-invalid',
      table.concat(validationErrors or {}, ' | ')
    ), claim.id
  end
  return actions, true, nil, claim.id, diagnostics
end

return M
