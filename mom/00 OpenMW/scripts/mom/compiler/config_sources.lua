local M = {}
local log = require('scripts.mom.diagnostics.log')
local readAll = require('scripts.mom.openmw.vfs')
local compat_registry = require('scripts.mom.compat.registry')
local vfs = require('openmw.vfs')
local markup = require('openmw.markup')
local function loadError(errorKind, errorMessage)
  return {
    kind = errorKind,
    message = errorMessage,
  }
end
local function normalizePath(path)
  return tostring(path or ''):gsub('\\', '/')
end
local function isYamlPath(path)
  local lower = normalizePath(path):lower()
  return lower:sub(-5) == '.yaml' or lower:sub(-4) == '.yml'
end
local function ensureSource(out, seen, path)
  if type(path) ~= 'string' or path == '' then
    return nil
  end
  local normalized = normalizePath(path)
  local key = normalized:lower()
  local source = seen[key]
  if source then
    return source
  end
  source = {
    path = normalized,
    native = false,
    compat = false,
  }
  seen[key] = source
  out[#out + 1] = source
  return source
end
local function pathClaim(path, registry)
  local claim, err = compat_registry.pathClaim(path, registry)
  if err then error(err.message, 0) end
  return claim
end
function M.configDirs(registry)
  return compat_registry.configDirs(registry)
end
function M.discover(configDirs, registry)
  local out = {}
  local seen = {}
  for _, configDir in ipairs(configDirs or {}) do
    local prefix = tostring(configDir or ''):gsub('\\', '/')
    if prefix ~= '' then
      if prefix:sub(-1) ~= '/' then
        prefix = prefix .. '/'
      end
      local iter = vfs.pathsWithPrefix(prefix)
      while true do
        local path = iter()
        if not path then break end
        local native = isYamlPath(path)
        local claim = pathClaim(path, registry)
        if native or claim ~= nil then
          local source = ensureSource(out, seen, path)
          source.native = source.native or native
          source.compat = source.compat or claim ~= nil
          source.compatClaim = source.compatClaim or claim or false
        end
      end
    end
  end
  table.sort(out, function(left, right)
    return tostring(left.path) < tostring(right.path)
  end)
  return out
end
function M.fromPaths(paths, registry)
  local out = {}
  local seen = {}
  for _, path in ipairs(paths or {}) do
    local source = ensureSource(out, seen, path)
    if source then
      source.native = isYamlPath(source.path)
      local claim = pathClaim(source.path, registry)
      source.compat = claim ~= nil
      source.compatClaim = claim or false
      source.explicit = true
    end
  end
  return out
end
function M.adapterId(source, registry)
  if source and source.compat then
    local claim = source.compatClaim
    if type(claim) == 'table' then return claim.id, nil end
    local selected, adapterError = compat_registry.pathClaim(source.path, registry)
    if adapterError then return nil, adapterError end
    source.compatClaim = selected or false
    if selected ~= nil then return selected.id, nil end
  end
  if source and source.native then return 'native', nil end
  return 'unknown', nil
end
function M.sourcePolicy(source)
  local claim = source and source.compatClaim
  local policy = type(claim) == 'table' and claim.module and claim.module.sourcePolicy
  if type(policy) ~= 'function' then return {} end
  local value = policy(source.path) or {}
  assert(type(value) == 'table' and (value.onLoadError == nil or value.onLoadError == 'skip'),
    'source admission policy is invalid')
  return value
end
local function loadNativeConfig(path, policy)
  local report = policy and policy.onLoadError == 'skip' and log.warn or log.error
  local ok, doc = pcall(markup.loadYaml, path)
  if ok and type(doc) == 'table' then return doc end
  if ok then
    report('config', 'loadYaml returned non-table for path=%s got=%s', path, type(doc))
    return nil, loadError('yaml-non-table', 'loadYaml returned ' .. type(doc))
  end
  local exists = vfs.fileExists(path) and 'yes' or 'no'
  log.debug('config', 'loadYaml failed path=%s exists=%s err=%s; trying decode fallback', path, exists, tostring(doc))
  local content, err = readAll(path)
  if not content then
    report('config', 'YAML load failed path=%s exists=%s loadYaml=%s readAll=%s', path, exists, tostring(doc), tostring(err))
    return nil, loadError('yaml-load-failed', tostring(err or doc))
  end
  local okD, val = pcall(markup.decodeYaml, content)
  if okD and type(val) == 'table' then return val end
  if okD then
    report('config', 'YAML load failed path=%s exists=%s loadYaml=%s decodeYaml returned %s', path, exists, tostring(doc), type(val))
    return nil, loadError('yaml-non-table', 'decodeYaml returned ' .. type(val))
  end
  report('config', 'YAML load failed path=%s exists=%s loadYaml=%s decodeYaml=%s', path, exists, tostring(doc), tostring(val))
  return nil, loadError('yaml-decode-failed', tostring(val))
end
function M.loadRaw(source, registry)
  local path = source and source.path or nil
  if source and source.compat then
    local claim = type(source.compatClaim) == 'table'
        and source.compatClaim or nil
    return compat_registry.load(path, function(value) return loadNativeConfig(value, M.sourcePolicy(source)) end, registry, claim)
  end
  return loadNativeConfig(path)
end
function M.translateSource(source, rawCfg, registry)
  return compat_registry.translateSource({
    path = source and source.path or nil,
    config = rawCfg,
  }, registry, type(source and source.compatClaim) == 'table'
      and source.compatClaim or nil)
end
return M
