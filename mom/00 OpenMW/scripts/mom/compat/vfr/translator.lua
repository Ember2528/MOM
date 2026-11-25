local M = {
  id = 'vfr', abiVersion = 1, behaviorVersion = 0,
  allowEmptySources = true,
  configDirs = {
    'scripts/variationframework/plants/data',
    'scripts/variationframework/containers/data',
    'scripts/variationframework/clutter/data',
    'scripts/variationframework/banners/data',
    'scripts/variationframework/placements/data',
    'scripts/variationframework/leveled_creatures/data',
  },
}

local category = require('scripts.mom.compat.vfr.category')
local source_ir = require('scripts.mom.compiler.source_ir')

local function normalize(path)
  return tostring(path or ''):gsub('\\', '/')
end

local function locate(path)
  local normalized = normalize(path):lower()
  if not (normalized:match('%.yaml$') or normalized:match('%.yml$')) then return nil end
  local name = normalized:match('^scripts/variationframework/([^/]+)/data/.+')
  if category.forName(name) or name == 'placements' or name == 'leveled_creatures' then
    return name
  end
  return nil
end

local function failure(path, message)
  return nil, true, {kind = 'invalid-vfr-config', message = normalize(path) .. ': ' .. tostring(message)}
end

function M.matchesPath(path)
  return locate(path) ~= nil
end

function M.sourcePolicy(path)
  if locate(path) == 'leveled_creatures' then return {onLoadError = 'skip'} end
  return nil
end

function M.translateSource(source)
  local path = normalize(source and source.path)
  local name = locate(path)
  if name == nil then return nil, false end
  local basename = path:lower():match('([^/]+)$')
  local stem = basename and basename:match('^([^.]+)')
  if stem and stem:lower() == 'example' then return {}, true end
  local raw = source and source.config
  if name == 'placements' or name == 'leveled_creatures' then
    local adapter = name == 'placements' and require('scripts.mom.compat.vfr.placements')
      or require('scripts.mom.compat.vfr.leveled_creatures')
    local actions, err, diagnostics = adapter.translate(raw, path)
    if actions == nil then return failure(path, err) end
    return actions, true, nil, diagnostics
  end
  local parsed, err = category.parse(raw, category.forName(name), path)
  if parsed == nil then return failure(path, err) end
  if parsed.disabled == true then return {}, true end
  local rows = {}
  for _, rule in ipairs(parsed.rules) do
    local choices = {}
    for _, target in ipairs(rule.targets) do
      local value = target.targetKind == 'record_id' and {recordId = target.targetValue}
        or {model = target.targetValue}
      choices[#choices + 1] = {value, 0}
    end
    local source = rule.sourceKind == 'record_id' and {recordId = rule.sourceKey} or rule.sourceKey
    local expr = {choose = choices, profile = rule.profile,
      keep = rule.keepStops and 'stop' or 'continue', order = rule.orderKey}
    if rule.priority ~= nil then expr.priority = rule.priority end
    rows[#rows + 1] = {'*', source, expr}
  end
  local spec = {attach = rows, select = {type = parsed.types}, disableOriginal = true,
    transferContents = parsed.transferContents}
  if parsed.requires ~= nil or parsed.requiresNot ~= nil then
    spec.admission = {requires = parsed.requires, requiresNot = parsed.requiresNot}
  end
  local ignored = {}
  for id in pairs(parsed.rules[1].ignoreRecords) do ignored[#ignored + 1] = id end
  table.sort(ignored)
  if #ignored > 0 then
    local tuple = {'exclude'}
    for _, id in ipairs(ignored) do tuple[#tuple + 1] = id end
    spec.filters = tuple
  end
  return {source_ir.sourceActionOwned(spec, {
    family = 'place_ref',
    diagnosticId = path .. '#compat:vfr:' .. name,
    source = {adapterId = M.id, file = path, variant = 'vfr:' .. name, path = {}},
    priority = parsed.priority,
  })}, true
end

return M
