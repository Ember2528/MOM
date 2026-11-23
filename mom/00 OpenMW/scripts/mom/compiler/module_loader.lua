-- Discovers deterministic, versioned action and guard extension registries.
local M = {}

local extension_registry = require('scripts.mom.compiler.extension_registry')
local log = require('scripts.mom.diagnostics.log')
local vfs = require('openmw.vfs')

local ACTION_ROOT = 'scripts/mom/actions'
local GUARD_ROOT = 'scripts/mom/guards'

local function pathToModule(path)
  path = path:gsub('\\', '/')
  path = path:gsub('%.lua$', '')
  return path:gsub('/', '.')
end

local function relativePath(prefix, path)
  local normalizedPrefix = prefix:gsub('\\', '/')
  local normalizedPath = path:gsub('\\', '/')
  local expectedStart = normalizedPrefix .. '/'
  if normalizedPath:sub(1, #expectedStart) ~= expectedStart then return nil end
  local relative = normalizedPath:sub(#expectedStart + 1)
  if relative == '' then return nil end
  return relative
end

local function directChildId(prefix, path)
  local relative = relativePath(prefix, path)
  if not relative or relative:find('/', 1, true) then return nil end
  if relative == 'init.lua' then return nil end
  return relative:gsub('%.lua$', '')
end

local function guardId(prefix, path)
  local relative = relativePath(prefix, path)
  if not relative then return nil end
  if relative == 'init.lua' or relative:match('/init%.lua$') then return nil end
  return relative:gsub('%.lua$', ''):gsub('/', '.')
end

local function discoverEntries(prefix, idForPath)
  local entries = {}
  local loadErrors = {}
  for rawPath in vfs.pathsWithPrefix(prefix) do
    local path = tostring(rawPath or ''):gsub('\\', '/')
    if path:sub(-4) == '.lua' then
      local expectedId = idForPath(prefix, path)
      if expectedId then
        local moduleName = pathToModule(path)
        local ok, mod = pcall(require, moduleName)
        if not ok then
          loadErrors[#loadErrors + 1] = {
            code = 'extension_require_failed',
            message = string.format('failed requiring %s: %s', tostring(moduleName), tostring(mod)),
            path = path,
            expectedId = expectedId,
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
  return entries, loadErrors
end

local function reportQuarantine(label, registry)
  local diagnostics = registry and registry.quarantineDiagnostics or {}
  for i = 1, #diagnostics do
    local err = diagnostics[i]
    local message = string.format(
      '%s%s%s',
      tostring(err.code or 'extension_error'),
      err.path and (' at ' .. tostring(err.path)) or '',
      err.message and (': ' .. tostring(err.message)) or ''
    )
    log.error('loader', '%s extension quarantined: %s', tostring(label), message)
  end
end

local function buildRegistry(prefix, idForPath, label, requiredMethods, opts)
  local entries, loadErrors = discoverEntries(prefix, idForPath)
  local registry = assert(extension_registry.buildQuarantined(label:lower(), entries, {
    supportedAbiVersion = 0,
    requiredMethods = requiredMethods,
    loadRequiredMethods = opts and opts.loadRequiredMethods,
    requireProgramVersion = opts and opts.requireProgramVersion == true,
    loadErrors = loadErrors,
  }))
  reportQuarantine(label, registry)
  return registry
end

function M.buildActionRegistry()
  local registry = buildRegistry(
    ACTION_ROOT,
    directChildId,
    'Action',
    {'prepareAction', 'compileAction', 'validateProgram'},
    {
      requireProgramVersion = true,
      loadRequiredMethods = {'analyzeLoad', 'compileLoad'},
    }
  )
  log.debug('loader', 'Loaded action modules count=%d', #registry.ids)
  return registry
end

function M.buildGuardRegistry()
  local registry = buildRegistry(
    GUARD_ROOT,
    guardId,
    'Guard',
    {'lowerTuple', 'compileProgram', 'evaluate'},
    {requireProgramVersion = true}
  )
  log.debug('loader', 'Loaded guard modules count=%d', #registry.ids)
  return registry
end

return M
