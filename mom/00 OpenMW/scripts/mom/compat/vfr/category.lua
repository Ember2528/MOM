-- Foreign category defaults and admission. The resulting rules contain only
-- MOM replacement and spatial-profile data; execution never reads VFR input.
local M = {}

local model_path = require('scripts.mom.contracts.model_path')
local plain_data = require('scripts.mom.contracts.plain_data')
local tables = require('scripts.mom.common.tables')
local isArray = tables.isArray
local vfr_common = require('scripts.mom.compat.vfr.common')

local CATEGORIES = {
  plants = {order = 1, kinds = {'Container', 'Static', 'Activator'}, transfer = true,
    cluster = {scale = 3072, detail = 1024, detailWeight = 0.30, jitter = 0.22}},
  containers = {order = 2, kinds = {'Container'}, transfer = true,
    cluster = {scale = 3072, detail = 1024, detailWeight = 0.30, jitter = 0.22}},
  clutter = {order = 3, kinds = {'Static', 'Activator'}, transfer = false,
    cluster = {scale = 2048, detail = 768, detailWeight = 0.30, jitter = 0.5}},
  banners = {order = 4, kinds = {'Static', 'Activator'}, transfer = false,
    cluster = {scale = 2048, detail = 768, detailWeight = 0.30, jitter = 1}},
}
local KIND_NAMES = {Container = true, Static = true, Activator = true, Ingredient = true}
local MODULE_FIELDS = {
  name = true, enabled = true, priority = true, require_content = true, exclude_content = true,
  seed = true, clustering = true, weights = true, climate_overrides = true,
  variants = true, record_variants = true, kinds = true, ignore_records = true,
  transfer_contents = true, supersede_static_switcher = true,
}
local CLUSTERING_FIELDS = {scale = true, detail = true, detail_weight = true, jitter = true}
local WEIGHTS_FIELDS = {
  default = true, interior_default = true, regions = true, cells = true, points = true,
  interiors = true, latitude = true, longitude = true, latitude_offset = true,
  longitude_offset = true, wetness = true, warmth = true, snow = true, ash = true,
}
local ENTRY_FIELDS = {meshes = true, records = true, contents = true}
local CELL_ENTRY_FIELDS = {x = true, y = true, w = true}
local POINT_ENTRY_FIELDS = {x = true, y = true, r = true, w = true}
local INTERIOR_ENTRY_FIELDS = {x = true, y = true, region = true, w = true}
local CLIMATE_FIELDS = {wetness = true, warmth = true, snow = true, ash = true}
local function keys(value)
  local out = {}
  for key in pairs(value or {}) do out[#out + 1] = key end
  table.sort(out, function(a, b) return tostring(a) < tostring(b) end)
  return out
end

local function array(value, path)
  if type(value) ~= 'table' then return nil, path .. ': expected array' end
  if not isArray(value) then return nil, path .. ': expected dense array' end
  return true
end

-- Foreign spelling and category policy end here. The native builder validates
-- the mapped shape and constructs all indexes; this adapter never evaluates it.
local function mapped(values, convert, path)
  if type(values) ~= 'table' then return values, nil end
  local out = {}
  for key, value in pairs(values) do
    local converted, err = convert(value, path .. '.' .. tostring(key))
    if err ~= nil then return nil, err end
    out[key] = converted
  end
  return out, nil
end

local function profileInput(raw, category)
  local weights = raw.weights
  if weights == nil then weights = {} end
  if type(weights) ~= 'table' then return nil, 'weights: expected object' end
  local weightsFieldErr = tables.validateAllowedKeys(weights, WEIGHTS_FIELDS, 'weights')
  if weightsFieldErr then return nil, weightsFieldErr end
  local clustering = raw.clustering
  if clustering == nil then clustering = {} end
  if type(clustering) ~= 'table' then return nil, 'clustering: expected object' end
  local clusterFieldErr = tables.validateAllowedKeys(clustering, CLUSTERING_FIELDS, 'clustering')
  if clusterFieldErr then return nil, clusterFieldErr end
  local cluster = {}
  for _, names in ipairs({{'scale', 'scale'}, {'detail', 'detail'},
    {'detailWeight', 'detail_weight'}, {'jitter', 'jitter'}}) do
    local key, foreign = names[1], names[2]
    local value = clustering[foreign]
    if value == nil or ((key == 'scale' or key == 'detail') and type(value) == 'number' and value <= 0) then
      value = category.cluster[key]
    end
    cluster[key] = value
  end
  local gradients = {}
  for _, axis in ipairs({{'latitude', 'y', 'y', 'x'}, {'longitude', 'x', 'x', 'y'},
    {'wetness', 'wetness', 'at'}, {'warmth', 'warmth', 'at'}, {'snow', 'snow', 'at'}, {'ash', 'ash', 'at'}}) do
    local name, nativeAxis, anchor, other = axis[1], axis[2], axis[3], axis[4]
    local offsets
    if other then offsets = weights[name .. '_offset'] end
    if weights[name] ~= nil or offsets ~= nil then
      local authoredAnchors = weights[name]
      if authoredAnchors == nil then authoredAnchors = {} end
      local anchorAllowed = {[anchor] = true, w = true}
      local mappedAnchors, anchorErr = mapped(authoredAnchors, function(value, itemPath)
        if type(value) ~= 'table' then return value end
        local fieldErr = tables.validateAllowedKeys(value, anchorAllowed, itemPath)
        if fieldErr then return nil, fieldErr end
        return {at = value[anchor], weights = value.w}
      end, 'weights.' .. name)
      if anchorErr then return nil, anchorErr end
      local offsetAllowed = other and {[other] = true, by = true} or nil
      local mappedOffsets, offsetErr = mapped(offsets, function(value, itemPath)
        if type(value) ~= 'table' then return value end
        local fieldErr = tables.validateAllowedKeys(value, offsetAllowed, itemPath)
        if fieldErr then return nil, fieldErr end
        return {at = value[other], value = value.by}
      end, 'weights.' .. name .. '_offset')
      if offsetErr then return nil, offsetErr end
      gradients[#gradients + 1] = {
        axis = nativeAxis,
        anchors = mappedAnchors,
        offsetAxis = offsets ~= nil and other or nil,
        offsets = mappedOffsets,
      }
    end
  end
  local cells, cellsErr = mapped(weights.cells, function(value, itemPath)
    if type(value) ~= 'table' then return value end
    local fieldErr = tables.validateAllowedKeys(value, CELL_ENTRY_FIELDS, itemPath)
    if fieldErr then return nil, fieldErr end
    return {x = value.x, y = value.y, weights = value.w}
  end, 'weights.cells')
  if cellsErr then return nil, cellsErr end
  local points, pointsErr = mapped(weights.points, function(value, itemPath)
    if type(value) ~= 'table' then return value end
    local fieldErr = tables.validateAllowedKeys(value, POINT_ENTRY_FIELDS, itemPath)
    if fieldErr then return nil, fieldErr end
    return {x = value.x, y = value.y, radius = value.r, weights = value.w}
  end, 'weights.points')
  if pointsErr then return nil, pointsErr end
  local interiors, interiorsErr = mapped(weights.interiors, function(value, itemPath)
    if type(value) == 'number' then return {y = value} end
    if type(value) ~= 'table' then return value end
    local fieldErr = tables.validateAllowedKeys(value, INTERIOR_ENTRY_FIELDS, itemPath)
    if fieldErr then return nil, fieldErr end
    if value.w ~= nil then
      if value.x ~= nil or value.y ~= nil or value.region ~= nil then
        return nil, itemPath .. ': cannot combine explicit weights with x, y, or region'
      end
      return {weights = value.w}
    end
    return {x = value.x, y = value.y, region = value.region}
  end, 'weights.interiors')
  if interiorsErr then return nil, interiorsErr end
  local climateOverrides, climateErr = mapped(raw.climate_overrides, function(value, itemPath)
    if type(value) ~= 'table' then return value end
    local fieldErr = tables.validateAllowedKeys(value, CLIMATE_FIELDS, itemPath)
    if fieldErr then return nil, fieldErr end
    return {wetness = value.wetness, warmth = value.warmth, snow = value.snow, ash = value.ash}
  end, 'climate_overrides')
  if climateErr then return nil, climateErr end
  return {
    seed = raw.seed, cluster = cluster, default = weights.default, interiorDefault = weights.interior_default,
    regions = weights.regions, gradients = gradients,
    cells = cells,
    points = points,
    interiors = interiors,
    climateOverrides = climateOverrides,
  }
end

function M.forName(name)
  return CATEGORIES[tostring(name):lower()]
end

function M.parse(raw, category, path)
  if type(raw) ~= 'table' then return nil, 'expected category module object' end
  local topErr = tables.validateAllowedKeys(raw, MODULE_FIELDS, 'module')
  if topErr then return nil, topErr end
  local header, headerErr = vfr_common.validateModuleHeader(raw)
  if not header then return nil, headerErr end
  if header.enabled == false then return {disabled = true} end
  if type(raw.variants) ~= 'table' and type(raw.record_variants) ~= 'table' then
    return nil, 'expected variants or record_variants map'
  end
  if raw.variants ~= nil and type(raw.variants) ~= 'table' then return nil, 'variants: expected source map' end
  if raw.record_variants ~= nil and type(raw.record_variants) ~= 'table' then return nil, 'record_variants: expected source map' end
  if raw.supersede_static_switcher ~= nil and type(raw.supersede_static_switcher) ~= 'boolean' then
    return nil, 'supersede_static_switcher: expected boolean'
  end
  local kindList = raw.kinds ~= nil and raw.kinds or category.kinds
  if raw.kinds == false then return nil, 'kinds: expected array' end
  local ok, err = array(kindList, 'kinds')
  if not ok then return nil, err end
  if #kindList == 0 then return nil, 'kinds: expected at least one supported kind' end
  local sourceTypes = {}
  for i, name in ipairs(kindList) do
    if not KIND_NAMES[name] then return nil, 'kinds[' .. i .. ']: unknown kind ' .. tostring(name) end
    sourceTypes[name] = true
  end
  local transfer = category.transfer
  if raw.transfer_contents ~= nil then
    if type(raw.transfer_contents) ~= 'boolean' then return nil, 'transfer_contents: expected boolean' end
    transfer = raw.transfer_contents
  end
  local ignored = {}
  if raw.ignore_records ~= nil then
    ok, err = array(raw.ignore_records, 'ignore_records')
    if not ok then return nil, err end
    for i, id in ipairs(raw.ignore_records) do
      if type(id) ~= 'string' or id == '' then return nil, 'ignore_records[' .. i .. ']: expected record id' end
      ignored[id:lower()] = true
    end
  end

  local rulePriority = (header.priority ~= nil and header.priority ~= 0) and header.priority or nil
  local rules, variantCount = {}, nil
  for _, kind in ipairs({'record_id', 'model_path'}) do
    local field = kind == 'record_id' and 'record_variants' or 'variants'
    local seenSources = {}
    for _, source in ipairs(keys(raw[field])) do
      local label = field .. '.' .. tostring(source)
      local entry = raw[field][source]
      if type(source) ~= 'string' or source == '' then return nil, field .. ': expected source string keys' end
      if type(entry) ~= 'table' then return nil, label .. ': expected target object' end
      local entryFieldErr = tables.validateAllowedKeys(entry, ENTRY_FIELDS, label)
      if entryFieldErr then return nil, entryFieldErr end
      if entry.meshes ~= nil and entry.records ~= nil then return nil, label .. ': choose meshes or records' end
      local targetKind = entry.records ~= nil and 'record_id' or 'model_path'
      local targets = entry.records or entry.meshes
      ok, err = array(targets, label .. '.' .. (targetKind == 'record_id' and 'records' or 'meshes'))
      if not ok then return nil, err end
      if #targets == 0 then return nil, label .. ': expected at least one replacement' end
      if variantCount ~= nil and #targets ~= variantCount then return nil, label .. ': all sources must declare the same number of variants' end
      variantCount = #targets
      local normalized = {}
      for i, target in ipairs(targets) do
        if type(target) ~= 'string' or target == '' then return nil, label .. '[' .. i .. ']: expected target string' end
        local value = targetKind == 'model_path' and model_path.normalize(target) or target:lower()
        if value == nil then return nil, label .. '[' .. i .. ']: invalid model path' end
        normalized[i] = {targetKind = targetKind, targetValue = value}
      end
      if entry.contents ~= nil then
        ok, err = array(entry.contents, label .. '.contents')
        if not ok then return nil, err end
        if #entry.contents > variantCount then return nil, label .. '.contents: more entries than variants' end
        for i, value in ipairs(entry.contents) do
          if type(value) ~= 'string' then return nil, label .. '.contents[' .. i .. ']: expected record id or keep' end
          if value ~= '' and value:lower() ~= 'keep' then return nil, label .. '.contents[' .. i .. ']: inventory conversion is not supported' end
        end
      end
      local sourceKey = kind == 'model_path' and model_path.normalize(source) or source:lower()
      if sourceKey == nil then return nil, label .. ': invalid source model path' end
      if seenSources[sourceKey] then return nil, label .. ': duplicate normalized source ' .. sourceKey end
      seenSources[sourceKey] = true
      rules[#rules + 1] = {
        sourceKey = sourceKey, sourceKind = kind, targets = normalized,
        sourceTypes = sourceTypes, keepStops = kind == 'record_id', ignoreRecords = ignored,
        priority = rulePriority,
        orderKey = tostring(category.order) .. '/' .. path:lower() .. '/' .. kind .. '/' .. sourceKey,
      }
    end
  end
  if variantCount == nil then return nil, 'no replacement sources were declared' end
  local nativeInput, profileError = profileInput(raw, category)
  if nativeInput == nil then return nil, profileError end
  for i = 1, #rules do
    -- Compiler admission requires a tree, so module-local immutable inputs
    -- are copied at this foreign ownership boundary rather than aliased.
    local copied, errors = plain_data.detach(nativeInput)
    if not copied then return nil, table.concat(errors or {}, ' | ') end
    rules[i].profile = copied
    rules[i].sourceTypes = assert(plain_data.detach(sourceTypes))
    rules[i].ignoreRecords = assert(plain_data.detach(ignored))
  end
  local result = {
    rules = rules,
    types = assert(plain_data.detach(kindList)),
    -- Native MOM owns priority 0; VFR supersede (-1) > SSS (-2) > default VFR (-3).
    priority = raw.supersede_static_switcher == true and -1 or -3,
    modulePriority = rulePriority,
    requires = header.requires,
    requiresNot = header.requiresNot,
  }
  if transfer == false or raw.transfer_contents ~= nil then result.transferContents = transfer end
  return result
end

return M
