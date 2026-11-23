-- Pure spatial choice. Compilation owns normalization; evaluation reads only
-- the installed profile and plain position/cell/climate facts.
local M = {}
local plain_data = require('scripts.mom.contracts.plain_data')
local tables = require('scripts.mom.common.tables')
local finite = require('scripts.mom.common.numbers').isFinite

local CELL_SIZE = 8192
local MAX_POINT_BUCKETS = 4096
local HASH_MODULUS = 2147483647
local MIN_NORMAL = 2.2250738585072014e-308
local MIN_POSITIVE = 4.9406564584124654e-324
local CLIMATE_AXES = {'wetness', 'warmth', 'snow', 'ash'}
local GRADIENT_AXES = {x = true, y = true, wetness = true, warmth = true, snow = true, ash = true}

local function lower(value)
  return value ~= nil and tostring(value):lower() or nil
end

local function cellKey(x, y)
  return ('%d,%d'):format(x, y)
end

local function sortAnchors(values)
  table.sort(values, function(a, b) return a.at > b.at end)
  return values
end

local function array(value, nonempty)
  return tables.isArray(value) and (not nonempty or #value > 0)
end

local function namedMap(value)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do if type(key) ~= 'string' or key == '' then return false end end
  return true
end

-- Private family programs can also arrive through compiler extensions. Validate
-- the installed representation before evaluation, rather than trusting its
-- provenance or repeating these checks for every target.
function M.validate(profile, variantCount)
  local valid, errors = plain_data.validate(profile)
  if not valid then return nil, table.concat(errors or {}, ' | ') end
  if type(profile) ~= 'table' or not finite(profile.seed) or profile.seed % 1 ~= 0 then
    return nil, 'spatial profile requires an integer seed'
  end
  local cluster = profile.cluster
  if type(cluster) ~= 'table' or not finite(cluster.scale) or cluster.scale <= 0
      or not finite(cluster.detail) or cluster.detail <= 0
      or not finite(cluster.detailWeight) or not finite(cluster.jitter) then
    return nil, 'spatial profile clustering is invalid'
  end
  local count = variantCount and variantCount + 1
    or (type(profile.default) == 'table' and #profile.default)
  local function vector(value)
    if not array(value, true) or #value ~= count then return false end
    for i = 1, #value do if not finite(value[i]) then return false end end
    return true
  end
  if not count or count < 2 or not vector(profile.default)
      or (profile.interiorDefault ~= nil and not vector(profile.interiorDefault)) then
    return nil, 'spatial profile default weights are invalid'
  end
  for _, field in ipairs({'regions', 'cells'}) do
    if not namedMap(profile[field]) then return nil, 'spatial profile ' .. field .. ' is invalid' end
    for _, values in pairs(profile[field]) do
      if not vector(values) then return nil, 'spatial profile ' .. field .. ' weights are invalid' end
    end
  end
  if not namedMap(profile.interiors) then return nil, 'spatial profile interiors are invalid' end
  for _, entry in pairs(profile.interiors) do
    if type(entry) ~= 'table' or (entry.weights ~= nil and not vector(entry.weights))
        or (entry.x ~= nil and not finite(entry.x)) or (entry.y ~= nil and not finite(entry.y))
        or (entry.region ~= nil and type(entry.region) ~= 'string')
        or (entry.weights == nil and entry.x == nil and entry.y == nil and entry.region == nil) then
      return nil, 'spatial profile interior entry is invalid'
    end
  end
  if not array(profile.gradients) then return nil, 'spatial profile gradients are invalid' end
  local function anchors(values, scalar)
    if not array(values, true) then return false end
    local previous = math.huge
    for _, entry in ipairs(values) do
      if type(entry) ~= 'table' or not finite(entry.at) or entry.at > previous
          or (scalar and not finite(entry.value)) or (not scalar and not vector(entry.weights)) then
        return false
      end
      previous = entry.at
    end
    return true
  end
  for _, gradient in ipairs(profile.gradients) do
    if type(gradient) ~= 'table' or not GRADIENT_AXES[gradient.axis] or not anchors(gradient.anchors)
        or (gradient.offsets ~= nil
          and ((gradient.offsetAxis ~= 'x' and gradient.offsetAxis ~= 'y')
            or not anchors(gradient.offsets, true)))
        or (gradient.offsetAxis ~= nil and gradient.offsets == nil) then
      return nil, 'spatial profile gradient entry is invalid'
    end
  end
  if not namedMap(profile.climateOverrides) then return nil, 'spatial profile climate overrides are invalid' end
  for _, override in pairs(profile.climateOverrides) do
    if type(override) ~= 'table' then return nil, 'spatial profile climate override is invalid' end
    for _, axis in ipairs(CLIMATE_AXES) do
      if override[axis] ~= nil and not finite(override[axis]) then
        return nil, 'spatial profile climate override axis is invalid'
      end
    end
  end
  if profile.points ~= nil then
    if not array(profile.points, true) or not namedMap(profile.pointBuckets) then
      return nil, 'spatial profile points are invalid'
    end
    for _, point in ipairs(profile.points) do
      if type(point) ~= 'table' or not finite(point.x) or not finite(point.y)
          or not finite(point.radiusSquared) or point.radiusSquared <= 0 or not vector(point.weights) then
        return nil, 'spatial profile point entry is invalid'
      end
    end
    for _, bucket in pairs(profile.pointBuckets) do
      if not array(bucket, true) then return nil, 'spatial profile point bucket is invalid' end
      for _, index in ipairs(bucket) do
        if not finite(index) or index % 1 ~= 0 or index < 1 or index > #profile.points then
          return nil, 'spatial profile point bucket index is invalid'
        end
      end
    end
    if profile.unindexedPoints ~= nil then
      if not array(profile.unindexedPoints, true) then return nil, 'spatial profile unindexed points are invalid' end
      for _, index in ipairs(profile.unindexedPoints) do
        if not finite(index) or index % 1 ~= 0 or index < 1 or index > #profile.points then
          return nil, 'spatial profile unindexed point index is invalid'
        end
      end
    end
  elseif profile.pointBuckets ~= nil or profile.unindexedPoints ~= nil then
    return nil, 'spatial profile point buckets require points'
  end
  return true
end

local SPEC_FIELDS = {seed = true, cluster = true, default = true, interiorDefault = true,
  regions = true, cells = true, points = true, interiors = true, gradients = true, climateOverrides = true}
local CLUSTER_FIELDS = {scale = true, detail = true, detailWeight = true, jitter = true}
local DEFAULT_CLUSTER = {scale = 3072, detail = 1024, detailWeight = 0.30, jitter = 0.22}

local function fields(value, allowed, path)
  if type(value) ~= 'table' then return nil, path .. ': expected object' end
  for key in pairs(value) do
    if not allowed[key] then return nil, path .. '.' .. tostring(key) .. ': field is not allowed' end
  end
  return true
end

local function optional(value)
  if value == nil then return {} end
  return value
end

local function vector(value, count, path)
  if not array(value) then return nil, path .. ': expected dense array' end
  if #value ~= count then return nil, path .. ': expected ' .. count .. ' weights (including keep)' end
  for i = 1, #value do
    if not finite(value[i]) then return nil, path .. '[' .. i .. ']: expected finite number' end
  end
  return tables.copyArray(value)
end

local function names(values, path, convert)
  if type(values) ~= 'table' then return nil, path .. ': expected named object' end
  local out = {}
  for name, value in pairs(values) do
    if type(name) ~= 'string' or name == '' then return nil, path .. ': expected non-empty name keys' end
    local key = lower(name)
    if out[key] ~= nil then return nil, path .. ': duplicate normalized name ' .. key end
    local normalized, reason = convert(value, path .. '.' .. name)
    if normalized == nil then return nil, reason end
    out[key] = normalized
  end
  return out
end

local function compileGradients(profile, rawGradients, count)
  local ok, reason
  local function anchors(values, path, scalar)
    if not array(values) then return nil, path .. ': expected dense array' end
    local out, seen = {}, {}
    for i, value in ipairs(values) do
      local atPath = path .. '[' .. i .. ']'
      local valid, err = fields(value,
        scalar and {at = true, value = true} or {at = true, weights = true}, atPath)
      if not valid then return nil, err end
      if not finite(value.at) then return nil, atPath .. '.at: expected finite number' end
      if seen[value.at] then
        return nil, atPath .. ': duplicate ' .. (scalar and 'offset' or 'gradient') .. ' anchor'
      end
      seen[value.at] = true
      if scalar then
        if not finite(value.value) then return nil, atPath .. '.value: expected finite number' end
        out[i] = {at = value.at, value = value.value}
      else
        local weights
        weights, err = vector(value.weights, count, atPath .. '.weights')
        if weights == nil then return nil, err end
        out[i] = {at = value.at, weights = weights}
      end
    end
    return sortAnchors(out)
  end
  local gradients = optional(rawGradients)
  if not array(gradients) then return nil, 'gradients: expected dense array' end
  for i, gradient in ipairs(gradients) do
    local path = 'gradients[' .. i .. ']'
    ok, reason = fields(gradient,
      {axis = true, anchors = true, offsetAxis = true, offsets = true}, path)
    if not ok then return nil, reason end
    if not GRADIENT_AXES[gradient.axis] then return nil, path .. '.axis: unknown gradient axis' end
    local values, offsets
    values, reason = anchors(gradient.anchors, path .. '.anchors')
    if values == nil then return nil, reason end
    if gradient.offsets ~= nil then
      if gradient.offsetAxis ~= 'x' and gradient.offsetAxis ~= 'y' then
        return nil, path .. '.offsetAxis: expected x or y'
      end
      offsets, reason = anchors(gradient.offsets, path .. '.offsets', true)
      if offsets == nil then return nil, reason end
    elseif gradient.offsetAxis ~= nil then
      return nil, path .. '.offsetAxis: requires offsets'
    end
    if #values > 0 then
      profile.gradients[#profile.gradients + 1] = {axis = gradient.axis, anchors = values,
        offsetAxis = offsets and #offsets > 0 and gradient.offsetAxis or nil,
        offsets = offsets and #offsets > 0 and offsets or nil}
    end
  end
  return true, nil
end

local function compilePoints(profile, rawPoints, count)
  local ok, reason
  local points = optional(rawPoints)
  if not array(points) then return nil, 'points: expected dense array' end
  if #points > 0 then
    profile.points, profile.pointBuckets = {}, {}
    for i, entry in ipairs(points) do
      local path = 'points[' .. i .. ']'
      ok, reason = fields(entry, {x = true, y = true, radius = true, weights = true}, path)
      if not ok then return nil, reason end
      if not finite(entry.x) or not finite(entry.y) then
        return nil, path .. ': expected finite x and y'
      end
      local radius = entry.radius
      if not finite(radius) or radius <= 0 or not finite(radius * radius) or radius * radius <= 0
          or not finite(entry.x - radius) or not finite(entry.x + radius)
          or not finite(entry.y - radius) or not finite(entry.y + radius) then
        return nil, path .. '.radius: expected positive finite radius with finite bounds'
      end
      local weights
      weights, reason = vector(entry.weights, count, path .. '.weights')
      if weights == nil then return nil, reason end
      profile.points[i] = {
        x = entry.x, y = entry.y, radiusSquared = radius * radius, weights = weights,
      }
      local x0 = math.floor((entry.x - radius) / CELL_SIZE)
      local x1 = math.floor((entry.x + radius) / CELL_SIZE)
      local y0 = math.floor((entry.y - radius) / CELL_SIZE)
      local y1 = math.floor((entry.y + radius) / CELL_SIZE)
      local bucketCount = (x1 - x0 + 1) * (y1 - y0 + 1)
      if bucketCount <= MAX_POINT_BUCKETS and x0 + 1 > x0 and x1 + 1 > x1
          and y0 + 1 > y0 and y1 + 1 > y1 then
        -- Count bounded offsets: at huge coordinates adding one can stop
        -- advancing between otherwise incrementable endpoints.
        for dx = 0, x1 - x0 do
          for dy = 0, y1 - y0 do
            local x, y = x0 + dx, y0 + dy
            local key = cellKey(x, y)
            local bucket = profile.pointBuckets[key] or {}
            profile.pointBuckets[key] = bucket
            bucket[#bucket + 1] = i
          end
        end
      else
        profile.unindexedPoints = profile.unindexedPoints or {}
        profile.unindexedPoints[#profile.unindexedPoints + 1] = i
      end
    end
  end
  return true, nil
end

-- Checked native input. The adapter owns foreign field names and category
-- defaults; this builder owns validation, normalization and spatial indexes.
-- The installed profile stays the same plain-data representation validated above.
function M.compile(spec, options)
  if options == nil then options = {} end
  local optionsValid, optionsError = fields(options, {variantCount = true}, 'spatial options')
  if not optionsValid then return nil, optionsError end
  local count = options.variantCount
  if not finite(count) or count % 1 ~= 0 or count < 1 then
    return nil, 'variantCount: expected positive integer'
  end
  count = count + 1
  if spec == nil then spec = {} end
  local copied, errors = plain_data.detach(spec, {path = 'spatial'})
  if copied == nil then return nil, table.concat(errors or {}, ' | ') end
  spec = copied
  local ok, reason = fields(spec, SPEC_FIELDS, 'spatial')
  if not ok then return nil, reason end
  if spec.seed ~= nil and not finite(spec.seed) then return nil, 'seed: expected finite number' end
  local cluster = optional(spec.cluster)
  ok, reason = fields(cluster, CLUSTER_FIELDS, 'cluster')
  if not ok then return nil, reason end
  local profile = {seed = math.floor(spec.seed or 0), cluster = {}, default = {},
    regions = {}, cells = {}, interiors = {}, gradients = {}, climateOverrides = {}}
  for key, fallback in pairs(DEFAULT_CLUSTER) do
    local value = cluster[key]
    if value == nil then value = fallback end
    if not finite(value) then return nil, 'cluster.' .. key .. ': expected finite number' end
    if (key == 'scale' or key == 'detail') and value <= 0 then
      return nil, 'cluster.' .. key .. ': expected positive number'
    end
    profile.cluster[key] = value
  end
  if spec.default ~= nil then
    profile.default, reason = vector(spec.default, count, 'default')
    if profile.default == nil then return nil, reason end
  else
    profile.default[1] = 1
    for i = 2, count do profile.default[i] = 0 end
  end
  if spec.interiorDefault ~= nil then
    profile.interiorDefault, reason = vector(spec.interiorDefault, count, 'interiorDefault')
    if profile.interiorDefault == nil then return nil, reason end
  end
  profile.regions, reason = names(optional(spec.regions), 'regions', function(value, path)
    return vector(value, count, path)
  end)
  if profile.regions == nil then return nil, reason end
  profile.interiors, reason = names(optional(spec.interiors), 'interiors', function(value, path)
    local valid, err = fields(value, {x = true, y = true, region = true, weights = true}, path)
    if not valid then return nil, err end
    if value.weights ~= nil then
      local weights
      weights, err = vector(value.weights, count, path .. '.weights')
      if weights == nil then return nil, err end
      return {weights = weights}
    end
    if value.x == nil and value.y == nil and value.region == nil then
      return nil, path .. ': expected weights, coordinates or region'
    end
    if (value.x ~= nil and not finite(value.x)) or (value.y ~= nil and not finite(value.y)) then
      return nil, path .. ': expected finite coordinates'
    end
    if value.region ~= nil and (type(value.region) ~= 'string' or value.region == '') then
      return nil, path .. '.region: expected non-empty name'
    end
    return {x = value.x, y = value.y, region = lower(value.region)}
  end)
  if profile.interiors == nil then return nil, reason end
  profile.climateOverrides, reason = names(optional(spec.climateOverrides), 'climateOverrides', function(value, path)
    local valid, err = fields(value, {wetness = true, warmth = true, snow = true, ash = true}, path)
    if not valid then return nil, err end
    for _, axis in ipairs(CLIMATE_AXES) do
      if value[axis] ~= nil and not finite(value[axis]) then return nil, path .. '.' .. axis .. ': expected finite number' end
    end
    return value
  end)
  if profile.climateOverrides == nil then return nil, reason end
  local gradientsOk, gradientsError = compileGradients(profile, spec.gradients, count)
  if not gradientsOk then return nil, gradientsError end
  local cells = optional(spec.cells)
  if not array(cells) then return nil, 'cells: expected dense array' end
  for i, entry in ipairs(cells) do
    local path = 'cells[' .. i .. ']'
    ok, reason = fields(entry, {x = true, y = true, weights = true}, path)
    if not ok then return nil, reason end
    if not finite(entry.x) or not finite(entry.y) or entry.x % 1 ~= 0 or entry.y % 1 ~= 0 then
      return nil, path .. ': expected integer cell coordinates'
    end
    local weights
    weights, reason = vector(entry.weights, count, path .. '.weights')
    if weights == nil then return nil, reason end
    -- Authored cell arrays are ordered: a later entry intentionally overrides.
    profile.cells[cellKey(entry.x, entry.y)] = weights
  end
  local pointsOk, pointsError = compilePoints(profile, spec.points, count)
  if not pointsOk then return nil, pointsError end
  local valid, validationError = M.validate(profile, options.variantCount)
  if not valid then return nil, validationError end
  return profile
end

local function hash01(x, y, salt)
  local hash = ((x % 100000) * 1000003 + (y % 100000) * 10007 + salt) % HASH_MODULUS
  hash = ((hash + 1) * 48271) % HASH_MODULUS
  hash = (hash * 48271) % HASH_MODULUS
  return ((hash * 48271) % HASH_MODULUS) / HASH_MODULUS
end

function M.key(position, cluster, seed)
  local coarse = hash01(math.floor(position.x / cluster.scale),
    math.floor(position.y / cluster.scale), seed + 1)
  local detail = hash01(math.floor(position.x / cluster.detail),
    math.floor(position.y / cluster.detail), seed + 2)
  local jitter = hash01(math.floor(position.x), math.floor(position.y), seed + 3)
  return (coarse + cluster.detailWeight * detail + cluster.jitter * (jitter - 0.5)) % 1
end

-- Slot zero keeps the source. All other slots index the replacement list.
function M.pick(weights, key)
  local total = 0
  for i = 1, #weights do total = total + math.max(weights[i], 0) end
  if total <= 0 then return 0 end
  -- Scale only extreme sums; ordinary weights retain their existing rounding
  -- and boundary behavior.
  if total == math.huge or total < MIN_NORMAL then
    if key == 0 then
      for i = 1, #weights do
        if weights[i] > 0 then return i - 1 end
      end
    end
    local maximum = 0
    for i = 1, #weights do maximum = math.max(maximum, weights[i]) end
    total = 0
    for i = 1, #weights do total = total + math.max(weights[i], 0) / maximum end
    local target, accumulated = key * total, 0
    for i = 1, #weights do
      accumulated = accumulated + math.max(weights[i], 0) / maximum
      if target < accumulated then return i - 1 end
    end
    return #weights - 1
  end
  local target, accumulated = key * total, 0
  for i = 1, #weights do
    accumulated = accumulated + math.max(weights[i], 0)
    if target < accumulated then return i - 1 end
  end
  return #weights - 1
end

-- Climate describes authored regional probabilities, rather than today's
-- weather. Missing base data can still be supplied by an explicit override.
local function withClimateOverride(base, override)
  if not override then return base end
  base = base or {wetness = 0, snow = 0, ash = 0, warmth = 50}
  local result = {}
  for _, axis in ipairs(CLIMATE_AXES) do result[axis] = override[axis] or base[axis] end
  return result
end

function M.climate(probabilities, override)
  local base
  if probabilities then
    local snow = (probabilities.snow or 0) + (probabilities.blizzard or 0)
    local ash = (probabilities.ashstorm or 0) + (probabilities.blight or 0)
    base = {
      wetness = (probabilities.rain or 0) + (probabilities.thunderstorm or 0) + snow,
      snow = snow,
      ash = ash,
      warmth = math.max(0, math.min(100,
        50 - 0.7 * snow + 0.25 * ash + 0.2 * ((probabilities.clear or 0) - 50))),
    }
  end
  return withClimateOverride(base, override)
end

local function bracket(anchors, value)
  if value >= anchors[1].at then return anchors[1] end
  if value <= anchors[#anchors].at then return anchors[#anchors] end
  for i = 1, #anchors - 1 do
    local high, low = anchors[i], anchors[i + 1]
    if value <= high.at and value >= low.at then
      local span = high.at - low.at
      if span == math.huge then
        return high, low, (high.at / 2 - value / 2) / (high.at / 2 - low.at / 2)
      end
      return high, low, (high.at - value) / span
    end
  end
end

local function interpolate(anchors, value, scalar)
  local high, low, fraction = bracket(anchors, value)
  if scalar then
    if not low then return high.value end
    local result = high.value + fraction * (low.value - high.value)
    if not finite(result) then
      return high.value * (1 - fraction) + low.value * fraction
    end
    return result
  end
  if not low then return high.weights end
  local result = {}
  for i = 1, #high.weights do
    local highWeight, lowWeight = high.weights[i], low.weights[i] or 0
    local weight = highWeight + fraction * (lowWeight - highWeight)
    if not finite(weight) then
      weight = highWeight * (1 - fraction) + lowWeight * fraction
    end
    result[i] = weight
  end
  return result
end

local function combine(sets)
  if #sets == 1 then return sets[1] end
  local product, total, unstable = {}, 0, false
  for i = 1, #sets[1] do
    local value = 1
    for s = 1, #sets do
      local weight = math.max(sets[s][i] or 0, 0)
      local nextValue = value * weight
      if value > 0 and weight > 0
          and (nextValue < MIN_NORMAL or nextValue == math.huge) then
        unstable = true
      end
      value = nextValue
    end
    product[i], total = value, total + value
  end
  if not unstable and finite(total) and total >= MIN_NORMAL then return product end
  -- The ordinary product may overflow or underflow even though each input is
  -- finite. Relative log products recover the same distribution when any
  -- slot has positive weight in every contributing gradient.
  local logProducts, maximum = {}, nil
  for i = 1, #sets[1] do
    local value = 0
    for s = 1, #sets do
      local weight = sets[s][i] or 0
      if weight <= 0 then
        value = nil
        break
      end
      value = value + math.log(weight)
    end
    logProducts[i] = value
    if value ~= nil and (maximum == nil or value > maximum) then maximum = value end
  end
  if maximum ~= nil then
    for i = 1, #sets[1] do
      product[i] = logProducts[i]
        and math.max(math.exp(logProducts[i] - maximum), MIN_POSITIVE) or 0
    end
    return product
  end
  local average, unstableAverage = {}, false
  for i = 1, #sets[1] do
    local value = 0
    for s = 1, #sets do value = value + math.max(sets[s][i] or 0, 0) end
    average[i] = value / #sets
    if value == math.huge or (value > 0 and average[i] < MIN_NORMAL) then
      unstableAverage = true
    end
  end
  if unstableAverage then
    -- A shared scale preserves the fallback's proportions without overflow or
    -- underflow; division by the number of gradients is common to every slot.
    local maximumWeight = 0
    for s = 1, #sets do
      for i = 1, #sets[1] do
        maximumWeight = math.max(maximumWeight, sets[s][i] or 0)
      end
    end
    for i = 1, #sets[1] do
      local value, positive = 0, false
      for s = 1, #sets do
        local weight = math.max(sets[s][i] or 0, 0)
        positive = positive or weight > 0
        value = value + weight / maximumWeight
      end
      average[i] = positive and math.max(value, MIN_POSITIVE) or 0
    end
  end
  return average
end

local function regionAxes(profile, id, climateByRegion)
  if not id or id == '' then return nil end
  local base = climateByRegion and climateByRegion[id]
  return withClimateOverride(base, profile.climateOverrides[id])
end

function M.region(profile, cell)
  local interior = not cell.isExterior
    and profile.interiors[lower(cell.nameLower or cell.name or cell.id)] or nil
  return (interior and interior.region) or lower(cell.regionKey or cell.region)
end

function M.resolveWeights(profile, cell, position, climateByRegion)
  local interior
  if cell.isExterior then
    if profile.points and position then
      local best, bestDistance, bestIndex
      local bucket = profile.pointBuckets[cellKey(cell.gridX, cell.gridY)] or {}
      local function consider(index)
        local point = profile.points[index]
        local dx, dy = position.x - point.x, position.y - point.y
        local distance = dx * dx + dy * dy
        if distance <= point.radiusSquared and (not bestDistance or distance < bestDistance
            or (distance == bestDistance and index < bestIndex)) then
          best, bestDistance, bestIndex = point.weights, distance, index
        end
      end
      for i = 1, #bucket do consider(bucket[i]) end
      for _, index in ipairs(profile.unindexedPoints or {}) do
        local point = profile.points[index]
        local radius = math.sqrt(point.radiusSquared)
        if cell.gridX >= math.floor((point.x - radius) / CELL_SIZE)
            and cell.gridX <= math.floor((point.x + radius) / CELL_SIZE)
            and cell.gridY >= math.floor((point.y - radius) / CELL_SIZE)
            and cell.gridY <= math.floor((point.y + radius) / CELL_SIZE) then
          consider(index)
        end
      end
      if best then return best end
    end
    local exact = profile.cells[cellKey(cell.gridX, cell.gridY)]
    if exact then return exact end
  else
    interior = profile.interiors[lower(cell.nameLower or cell.name or cell.id)]
    if interior and interior.weights then return interior.weights end
    if not interior and profile.interiorDefault then return profile.interiorDefault end
  end
  local region = M.region(profile, cell)
  if region and profile.regions[region] then return profile.regions[region] end
  local axes = {}
  if cell.isExterior then
    axes.x, axes.y = cell.gridX, cell.gridY
  elseif interior then
    axes.x, axes.y = interior.x, interior.y
  end
  local climate = regionAxes(profile, region, climateByRegion)
  if climate then
    for _, axis in ipairs(CLIMATE_AXES) do axes[axis] = climate[axis] end
  end
  local sets = {}
  for i = 1, #profile.gradients do
    local gradient = profile.gradients[i]
    local value = axes[gradient.axis]
    if value ~= nil then
      local along = gradient.offsetAxis and axes[gradient.offsetAxis]
      if along ~= nil then value = value + interpolate(gradient.offsets, along, true) end
      sets[#sets + 1] = interpolate(gradient.anchors, value, false)
    end
  end
  if #sets > 0 then return combine(sets) end
  return profile.default
end

-- A constant result needs no cell, climate or spatial noise. This proof is
-- deliberately narrower than comparing a few samples of a variable profile.
function M.constantChoice(profile)
  if profile.points ~= nil or #profile.gradients > 0
      or next(profile.regions) ~= nil or next(profile.cells) ~= nil
      or next(profile.interiors) ~= nil then return nil end
  local function onePositive(weights)
    local selected = 0
    for i, weight in ipairs(weights) do
      if weight > 0 then
        if selected ~= 0 then return nil end
        selected = i
      end
    end
    return selected > 0 and selected - 1 or 0
  end
  local selected = onePositive(profile.default)
  if selected == nil or (profile.interiorDefault ~= nil
      and onePositive(profile.interiorDefault) ~= selected) then return nil end
  return selected
end

function M.choose(profile, cell, position, climateByRegion)
  return M.pick(M.resolveWeights(profile, cell, position, climateByRegion),
    M.key(position, profile.cluster, profile.seed))
end

return M
