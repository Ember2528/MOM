local M = {}
-- Resolves authored variants against active content files and merges the
-- satisfied action lists into compiler input.
local authored_contract = require('scripts.mom.compiler.authored_contract')
local source_variant_actions = require('scripts.mom.compiler.source_variant_actions')
local log = require('scripts.mom.diagnostics.log')
local tables = require('scripts.mom.common.tables')
local content_files = require('scripts.mom.common.content_files')
local core = require('openmw.core')
local AUTHORED_CONFIG_VERSION = authored_contract.configVersion
local hasNamedKeys = tables.hasNamedKeys
local isArray = tables.isArray
local isObject = tables.isObject
local sortedKeys = tables.sortedKeys
local validateAllowedKeys = tables.validateAllowedKeys
local function validateStringArray(values, path)
  for i, value in ipairs(values or {}) do
    if type(value) ~= 'string' or value == '' then
      return string.format('%s[%d]: expected non-empty string', tostring(path), i)
    end
  end
  return nil
end
local function validateStringKeys(value, path)
  for key in pairs(value or {}) do
    if type(key) ~= 'string' or key == '' then
      return string.format('%s: expected object keyed by non-empty strings', tostring(path))
    end
  end
  return nil
end
local function validateOptionalString(value, path)
  if value == nil then return nil end
  if type(value) ~= 'string' then
    return string.format('%s: expected string', tostring(path))
  end
  return nil
end
local function validateConfigVersion(value)
  if value == nil then
    return string.format('version: expected %d', AUTHORED_CONFIG_VERSION)
  end
  if type(value) ~= 'number' or value ~= AUTHORED_CONFIG_VERSION then
    return string.format('version: expected %d, got %s', AUTHORED_CONFIG_VERSION, tostring(value))
  end
  return nil
end
local VARIANT_FIELDS = authored_contract.variantFields
local TOP_LEVEL_FIELDS = authored_contract.topLevelFields
local function invalidConfig(message, loadInputs)
  return nil, {
    kind = 'invalid-config-shape',
    message = message,
    loadInputs = loadInputs,
  }
end
local function activeContentSet()
  return content_files.activeSet(core.contentFiles)
end
function M.createContext()
  local active = activeContentSet()
  return {
    activeContent = active,
  }
end
local function variantSatisfied(variant, active)
  -- Conditions: requires (all), requiresAny (at least one), requiresNot (none)
  local req = variant.requires or {}
  for _, r in ipairs(req) do if not active[r:lower()] then return false, 'missing required '..r end end
  local any = variant.requiresAny or {}
  if #any > 0 then
    local okAny = false
    for _, r in ipairs(any) do if active[r:lower()] then okAny = true break end end
    if not okAny then return false, 'none of requiresAny present' end
  end
  local notList = variant.requiresNot or {}
  for _, r in ipairs(notList) do if active[r:lower()] then return false, 'forbidden present '..r end end
  return true, nil
end
function M.resolve(cfg, ctx)
  if type(cfg) ~= 'table' then
    return invalidConfig('config: expected object')
  end
  local out = {actions = {}, loadInputs = {}}
  if next(cfg) ~= nil and not hasNamedKeys(cfg) then
    return invalidConfig('config: expected object')
  end
  local active = ctx and ctx.activeContent or nil
  if active == nil then
    active = activeContentSet()
  end
  local applied = {}
  local skipped = {}
  local selectedVariants = {}
  if cfg.actions ~= nil or cfg.guards ~= nil then
    return invalidConfig('actions/guards: top-level fields are not allowed')
  end
  local topLevelFieldErr = validateAllowedKeys(cfg, TOP_LEVEL_FIELDS, 'config')
  if topLevelFieldErr then
    return invalidConfig(topLevelFieldErr)
  end
  local versionErr = validateConfigVersion(cfg.version)
  if versionErr then return invalidConfig(versionErr) end
  local nameErr = validateOptionalString(cfg.name, 'name')
  if nameErr then return invalidConfig(nameErr) end
  local descriptionErr = validateOptionalString(cfg.description, 'description')
  if descriptionErr then return invalidConfig(descriptionErr) end
  if cfg.variants == nil then
    return invalidConfig('variants: is required')
  end
  local variants = cfg.variants
  if type(variants) ~= 'table' then
    return invalidConfig('variants: expected object keyed by variant id')
  end
  if next(variants) ~= nil and not hasNamedKeys(variants) then
    return invalidConfig('variants: expected object keyed by variant id')
  end
  local variantKeyErr = validateStringKeys(variants, 'variants')
  if variantKeyErr then
    return invalidConfig(variantKeyErr)
  end
  local variantIds = sortedKeys(variants)
  for i = 1, #variantIds do
    local variantId = variantIds[i]
    local v = variants[variantId]
    local variantPath = 'variants.' .. tostring(variantId)
    if not isObject(v) then
      return invalidConfig(variantPath .. ': expected object')
    end
    local variantFieldErr = validateAllowedKeys(v, VARIANT_FIELDS, variantPath)
    if variantFieldErr then
      return invalidConfig(variantFieldErr)
    end
    local variantDescriptionErr = validateOptionalString(v.description,
      variantPath .. '.description')
    if variantDescriptionErr then
      return invalidConfig(variantDescriptionErr)
    end
    if v.requires ~= nil and not isArray(v.requires) then
      return invalidConfig(variantPath .. '.requires: expected array')
    end
    if v.requiresAny ~= nil and not isArray(v.requiresAny) then
      return invalidConfig(variantPath .. '.requiresAny: expected array')
    end
    if v.requiresNot ~= nil and not isArray(v.requiresNot) then
      return invalidConfig(variantPath .. '.requiresNot: expected array')
    end
    local requiresErr = validateStringArray(v.requires, variantPath .. '.requires')
    if requiresErr then return invalidConfig(requiresErr) end
    local requiresAnyErr = validateStringArray(v.requiresAny, variantPath .. '.requiresAny')
    if requiresAnyErr then return invalidConfig(requiresAnyErr) end
    local requiresNotErr = validateStringArray(v.requiresNot, variantPath .. '.requiresNot')
    if requiresNotErr then return invalidConfig(requiresNotErr) end
    local ok, reason = variantSatisfied(v, active)
    if ok then
      selectedVariants[#selectedVariants + 1] = {id = variantId, variant = v}
      applied[#applied+1] = variantId
    else
      skipped[#skipped+1] = variantId .. ' ('.. reason ..')'
    end
  end
  for _, entry in ipairs(selectedVariants) do
    local actions, resolveError, loadInputs = source_variant_actions.collect(entry.id, entry.variant, {
      sourcePath = ctx and ctx.sourcePath or nil,
      adapterId = ctx and ctx.adapterId or 'native',
      guardRegistry = ctx and ctx.guardRegistry or nil,
      phase = ctx and ctx.phase or nil,
      deferPlacement = ctx and ctx.deferPlacement,
    })
    if not actions then return invalidConfig(tostring(resolveError), out.loadInputs) end
    for _, action in ipairs(actions) do out.actions[#out.actions + 1] = action end
    for _, input in ipairs(loadInputs or {}) do out.loadInputs[#out.loadInputs + 1] = input end
  end
  log.debug('variants', 'Applied %d variant(s), skipped %d', #applied, #skipped)
  return out, nil
end
return M
