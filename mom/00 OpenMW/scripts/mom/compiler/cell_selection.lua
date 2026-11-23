-- Compiles authored cell selectors into normalized predicates, routes, and
-- query entries. Predicates preserve the authored truth; routes choose the
-- cheapest runtime bucket that can still honor that truth.
local M = {}
local cell_identity = require('scripts.mom.domain.cell.identity')
local cell_predicate = require('scripts.mom.domain.cell.predicate')
local sortedKeys = require('scripts.mom.common.tables').sortedKeys
local spec_key = require('scripts.mom.compiler.spec_key')
local strings = require('scripts.mom.common.strings')
local lowerString = strings.lowerString
local fieldMatchesPattern = cell_predicate.fieldMatchesPattern
local FOOTPRINT_EXACT_ROUTE_PROJECTION_BUDGET = 2
local function incrementMetric(metrics, field)
  if type(metrics) == 'table' then
    metrics[field] = (metrics[field] or 0) + 1
  end
end
local function addUnique(array, seen, value)
  if value == nil or seen[value] then return end
  seen[value] = true
  array[#array + 1] = value
end
local function normalizeStringOrArray(value, lowercase)
  if value == nil then return nil end
  local transform = lowercase and lowerString or tostring
  local out, seen = {}, {}
  if type(value) == 'string' then
    addUnique(out, seen, transform(value))
  elseif type(value) == 'table' then
    for i = 1, #value do
      addUnique(out, seen, transform(value[i]))
    end
  end
  return #out > 0 and out or nil
end
local function normalizeCoords(rawCoords)
  if rawCoords == nil then return nil, nil end
  local coordPairs = {}
  local seen = {}
  local function appendPair(value)
    local pair, pairErr = cell_identity.normalizePair(value)
    if not pair then return false, pairErr end
    local key = assert(cell_identity.packedCellKeyForCoords(pair.x, pair.y))
    if seen[key] then return true end
    seen[key] = true
    coordPairs[#coordPairs + 1] = pair
    return true
  end
  if type(rawCoords) ~= 'table' then
    return nil, 'expected coord pair or coord pair array'
  end
  if rawCoords.x ~= nil or rawCoords.y ~= nil then
    local ok, err = appendPair(rawCoords)
    if not ok then return nil, err or 'invalid coord pair' end
  elseif #rawCoords == 2 and type(rawCoords[1]) == 'number' and type(rawCoords[2]) == 'number' then
    local ok, err = appendPair(rawCoords)
    if not ok then return nil, err or 'invalid coord pair' end
  else
    for i = 1, #rawCoords do
      local ok, err = appendPair(rawCoords[i])
      if not ok then
        return nil, string.format('invalid coord pair at index %d: %s', i, tostring(err or 'invalid coord pair'))
      end
    end
  end
  return #coordPairs > 0 and coordPairs or nil, nil
end
local function normalizePattern(value)
  local raw = tostring(value)
  local starts = raw:sub(1, 1) == '*'
  local ends = raw:sub(-1) == '*'
  local innerStart = starts and 2 or 1
  local innerEnd = ends and (#raw - 1) or #raw
  local inner = raw:sub(innerStart, innerEnd)
  if raw == '*' then
    return {
      kind = 'all',
      raw = raw,
      needle = '',
    }
  end
  if starts and ends then
    return { kind = 'contains', raw = raw, needle = lowerString(inner) or '' }
  elseif starts then
    return { kind = 'suffix', raw = raw, needle = lowerString(inner) or '' }
  elseif ends then
    return { kind = 'prefix', raw = raw, needle = lowerString(inner) or '' }
  end
  return { kind = 'exact', raw = raw, needle = lowerString(raw) }
end
local function normalizePatterns(value)
  local raw = normalizeStringOrArray(value)
  if not raw then return nil end
  local out = {}
  for i = 1, #raw do
    out[i] = normalizePattern(raw[i])
  end
  return #out > 0 and out or nil
end
local function normalizeCellQuery(cellSpec, opts)
  opts = opts or {}
  local allowImplicitAll = opts.allowImplicitAll ~= false
  if cellSpec == nil then return nil, nil end
  if type(cellSpec) == 'string' then
    if cellSpec == '*' then
      return {
        match = normalizePatterns(cellSpec),
      }, nil
    end
    return {
      exact = normalizeStringOrArray(cellSpec, true),
    }, nil
  end
  if type(cellSpec) ~= 'table' then
    return nil, 'expected string or object'
  end
  local normalized = {
    exact = normalizeStringOrArray(cellSpec.exact, true),
    match = normalizePatterns(cellSpec.match),
    worldspace = normalizeStringOrArray(cellSpec.worldspace, true),
    region = normalizeStringOrArray(cellSpec.region, true),
    kind = cellSpec.kind ~= nil and tostring(cellSpec.kind):lower() or nil,
  }
  local coords, coordErr = normalizeCoords(cellSpec.coords)
  if coordErr then return nil, coordErr end
  normalized.coords = coords
  if normalized.kind ~= nil and normalized.kind ~= 'interior' and normalized.kind ~= 'exterior' then
    return nil, 'kind must be interior or exterior'
  end
  if normalized.coords and normalized.kind == 'interior' then
    return nil, 'coords cannot be combined with kind: interior'
  end
  local hasSelector = normalized.exact ~= nil
    or normalized.match ~= nil
    or normalized.coords ~= nil
    or normalized.worldspace ~= nil
    or normalized.region ~= nil
  if allowImplicitAll and not hasSelector then
    normalized.match = normalizePatterns('*')
  elseif not allowImplicitAll and not hasSelector then
    return nil, 'exclude requires at least one of exact, match, coords, worldspace, or region'
  end
  return normalized, nil
end
local function normalizeCellSpec(cellSpec)
  if cellSpec == nil then return nil, nil end
  if type(cellSpec) == 'string' then
    return normalizeCellQuery(cellSpec, { allowImplicitAll = true })
  end
  if type(cellSpec) ~= 'table' then
    return nil, 'expected string or object'
  end
  local include, includeErr = normalizeCellQuery(cellSpec, { allowImplicitAll = true })
  if includeErr then return nil, includeErr end
  local exclude = nil
  if cellSpec.exclude ~= nil then
    exclude, includeErr = normalizeCellQuery(cellSpec.exclude, { allowImplicitAll = false })
    if includeErr then return nil, 'exclude: ' .. tostring(includeErr) end
  end
  if exclude == nil then
    return include, nil
  end
  return {
    exact = include.exact,
    match = include.match,
    worldspace = include.worldspace,
    region = include.region,
    kind = include.kind,
    coords = include.coords,
    exclude = exclude,
  }, nil
end
local function queryHasExplicitCellKeys(query)
  return query ~= nil and (query.exact ~= nil or query.coords ~= nil)
end
local function queryHasFiniteMatch(query)
  local match = query and query.match or nil
  if not match then return false end
  for i = 1, #match do
    if match[i] and match[i].kind == 'all' then return false end
  end
  return #match > 0
end
local function addEntry(outEntries, seen, entry)
  if not entry or seen[entry.key] then return end
  seen[entry.key] = true
  outEntries[#outEntries + 1] = entry
end
local function resolveExact(index, query, seen, outEntries)
  for i = 1, #(query.exact or {}) do
    local exact = query.exact[i]
    local keyedEntry = index.byKey[exact]
    if keyedEntry and cell_predicate.matchesBroadFilters(keyedEntry, query) then
      addEntry(outEntries, seen, keyedEntry)
    end
    local buckets = {
      index.byId[exact],
      index.byName[exact],
      index.byDisplayName[exact],
    }
    for j = 1, #buckets do
      for k = 1, #((buckets[j]) or {}) do
        local entry = buckets[j][k]
        if cell_predicate.matchesBroadFilters(entry, query) then
          addEntry(outEntries, seen, entry)
        end
      end
    end
  end
end
local function resolveMatch(index, query, seen, outEntries)
  for i = 1, #index.entries do
    local entry = index.entries[i]
    if cell_predicate.matchesBroadFilters(entry, query) then
      local matched = false
      for j = 1, #(query.match or {}) do
        local pattern = query.match[j]
        if fieldMatchesPattern(entry.idLower, pattern)
            or fieldMatchesPattern(entry.nameLower, pattern)
            or fieldMatchesPattern(entry.displayNameLower, pattern) then
          matched = true
          break
        end
      end
      if matched then
        addEntry(outEntries, seen, entry)
      end
    end
  end
end
local function resolveCoords(index, query, seen, outEntries)
  local worldspaces = query.worldspace or {cell_identity.DEFAULT_WORLDSPACE}
  for i = 1, #(query.coords or {}) do
    local pair = query.coords[i]
    local packedCellKey = cell_identity.packedCellKeyForCoords(pair.x, pair.y)
    for j = 1, #worldspaces do
      local byWorldspace = packedCellKey and index.byExteriorWorldspace and index.byExteriorWorldspace[worldspaces[j]] or nil
      local bucket = byWorldspace and byWorldspace[packedCellKey] or nil
      for k = 1, #(bucket or {}) do
        local entry = bucket[k]
        if entry and cell_predicate.matchesBroadFilters(entry, query) then
          addEntry(outEntries, seen, entry)
        end
      end
    end
  end
end
local function appendIndexedSelectionBucket(bucket, query, seen, outEntries)
  for i = 1, #(bucket or {}) do
    local entry = bucket[i]
    if cell_predicate.matchesQuery(entry, query) then
      addEntry(outEntries, seen, entry)
    end
  end
end
local function resolveRegionBuckets(index, query, seen, outEntries)
  local byRegion = index.byRegion or {}
  local worldspaces = query.worldspace
  for i = 1, #(query.region or {}) do
    local region = query.region[i]
    if worldspaces then
      for j = 1, #worldspaces do
        local bucket = byRegion[worldspaces[j]] and byRegion[worldspaces[j]][region] or nil
        appendIndexedSelectionBucket(bucket, query, seen, outEntries)
      end
    else
      for _, regionBuckets in pairs(byRegion) do
        appendIndexedSelectionBucket(regionBuckets and regionBuckets[region] or nil, query, seen, outEntries)
      end
    end
  end
end
local function resolveWorldspaceBuckets(index, query, seen, outEntries)
  local byWorldspace = index.byWorldspace or {}
  for i = 1, #(query.worldspace or {}) do
    appendIndexedSelectionBucket(byWorldspace[query.worldspace[i]], query, seen, outEntries)
  end
end
local function filterExcludedEntries(entries, query)
  local exclude = query and query.exclude or nil
  if not exclude then return entries end
  local filtered = {}
  for i = 1, #entries do
    if not cell_predicate.matchesQuery(entries[i], exclude) then
      filtered[#filtered + 1] = entries[i]
    end
  end
  return filtered
end
local function compactEntry(entry)
  if not entry then return nil end
  return {
    key = entry.key,
    id = entry.id,
    idLower = entry.idLower,
    interiorKey = entry.interiorKey,
    isExterior = entry.isExterior == true,
    worldspaceKey = entry.worldspaceKey,
    gridX = entry.gridX,
    gridY = entry.gridY,
    packedCellKey = entry.packedCellKey,
  }
end
local function compactEntries(entries)
  local out = {}
  for i = 1, #(entries or {}) do
    out[i] = compactEntry(entries[i])
  end
  return out
end
local function sortedWorldspaceGroups(sets, valuesField)
  local groups = {}
  local worldspaceKeys = sortedKeys(sets)
  for i = 1, #worldspaceKeys do
    local worldspaceKey = worldspaceKeys[i]
    groups[i] = {
      worldspaceKey = worldspaceKey,
      [valuesField] = sortedKeys(sets[worldspaceKey]),
    }
  end
  return groups
end
local function buildExactRoute(entries, routeKey)
  local interiors, exteriors = {}, {}
  local exteriorCount = 0
  for i = 1, #entries do
    local entry = entries[i]
    if entry.isExterior then
      local worldspaceKey, packedCellKey = entry.worldspaceKey, entry.packedCellKey
      if worldspaceKey and packedCellKey then
        local keys = exteriors[worldspaceKey]
        if keys == nil then keys = {} exteriors[worldspaceKey] = keys end
        if not keys[packedCellKey] then
          keys[packedCellKey] = true
          exteriorCount = exteriorCount + 1
        end
      end
    else
      local key = entry.interiorKey or entry.key
      if key then interiors[key] = true end
    end
  end
  local interiorKeys = sortedKeys(interiors)
  local exteriorGroups = sortedWorldspaceGroups(exteriors, 'packedCellKeys')
  if #interiorKeys == 0 and exteriorCount > FOOTPRINT_EXACT_ROUTE_PROJECTION_BUDGET then
    return {kind = 'footprint', key = routeKey, exteriors = exteriorGroups}
  end
  return {kind = 'exact', interiorKeys = interiorKeys, exteriors = exteriorGroups}
end
local function buildRegionRoute(entries)
  local regions = {}
  for i = 1, #entries do
    local entry = entries[i]
    local worldspaceKey, regionKey = entry.worldspaceKey, entry.regionKey
    if worldspaceKey and regionKey then
      local keys = regions[worldspaceKey]
      if keys == nil then keys = {} regions[worldspaceKey] = keys end
      keys[regionKey] = true
    end
  end
  return {kind = 'region', worldspaces = sortedWorldspaceGroups(regions, 'regionKeys')}
end
local function buildWorldspaceRoute(entries)
  local keys = {}
  for i = 1, #entries do
    local key = entries[i].worldspaceKey
    if key then keys[key] = true end
  end
  return {kind = 'worldspace', worldspaceKeys = sortedKeys(keys)}
end
local function buildPrevisitEntry(entry)
  if not (entry and entry.isExterior and entry.packedCellKey) then return nil end
  return {
    worldspaceKey = entry.worldspaceKey,
    gridX = entry.gridX,
    gridY = entry.gridY,
    packedCellKey = entry.packedCellKey,
  }
end
local function sortPrevisitEntries(entries)
  table.sort(entries, function(a, b)
    if a.worldspaceKey ~= b.worldspaceKey then
      return tostring(a.worldspaceKey) < tostring(b.worldspaceKey)
    end
    if a.packedCellKey ~= b.packedCellKey then
      return (a.packedCellKey or 0) < (b.packedCellKey or 0)
    end
    if a.gridX ~= b.gridX then
      return (a.gridX or 0) < (b.gridX or 0)
    end
    if a.gridY ~= b.gridY then
      return (a.gridY or 0) < (b.gridY or 0)
    end
    return false
  end)
end
local function collectPrevisitEntries(entries)
  local previsitEntries = {}
  for i = 1, #entries do
    if entries[i].isExterior then
      local previsitEntry = buildPrevisitEntry(entries[i])
      if previsitEntry then
        previsitEntries[#previsitEntries + 1] = previsitEntry
      end
    end
  end
  sortPrevisitEntries(previsitEntries)
  return previsitEntries
end
local function buildPredicate(normalized, runtimeBroad)
  return {
    query = normalized,
    runtimeBroad = runtimeBroad == true or nil,
  }
end
local function routeBucketKind(query)
  if not query then return nil end
  if query.region ~= nil and (query.match ~= nil or not queryHasExplicitCellKeys(query)) then
    return 'region'
  end
  if query.worldspace ~= nil and query.region == nil and (query.match ~= nil or not queryHasExplicitCellKeys(query)) then
    return 'worldspace'
  end
  if queryHasExplicitCellKeys(query) then
    return 'cell'
  end
  return 'deferred'
end
local function queryNeedsDeferredRoute(query, bucketKind)
  return bucketKind == 'deferred'
    or (bucketKind == 'cell' and query and query.match ~= nil and query.region == nil and query.worldspace == nil)
end
local function mergeUniverseEntries(primary, secondary)
  local out, seen = {}, {}
  local function append(entries)
    for i = 1, #(entries or {}) do
      local entry = entries[i]
      local key = entry and entry.key
      if key ~= nil and not seen[key] then
        seen[key] = true
        out[#out + 1] = entry
      end
    end
  end
  append(primary)
  append(secondary)
  table.sort(out, function(left, right)
    return tostring(left.key) < tostring(right.key)
  end)
  return out
end
local function buildUniverse(mode, entries, open)
  if mode == nil or mode == 'none' then return nil end
  local compact = compactEntries(entries)
  if open then
    -- These entries are cooperative seeds, not proof that the authored cell
    -- predicate is exhausted. Runtime discovery must visit its observed-cell
    -- arm after the seeds.
    return {
      kind = 'open',
      entries = compact,
    }
  end
  if #compact > 0 or mode == 'required' then
    return {
      kind = 'finite',
      entries = compact,
    }
  end
  if mode == 'explicit' then
    return {
      kind = 'open',
      entries = {},
    }
  end
  return nil
end
function M.compile(cellSpec, actionId, opts)
  opts = opts or {}
  local requireExplicit = opts.requireExplicit == true
  local universeMode = opts.universe or 'none'
  local path = opts.path or ('action:' .. tostring(actionId) .. '.select.cell')
  if cellSpec == nil then
    if requireExplicit then
      return nil, { path .. ': required; use "*" for all cells' }
    end
    return nil, nil
  end
  local normalized, normalizeErr = normalizeCellSpec(cellSpec)
  if normalizeErr then
    return nil, { path .. ': ' .. tostring(normalizeErr) }
  end
  local index = opts.cellIndex
  if index == nil and type(opts.requireCellIndex) == 'function' then
    index = opts.requireCellIndex()
  end
  assert(index, 'cell_selection.compile requires cellIndex')
  local bucketKind = routeBucketKind(normalized)
  local cacheKey = tostring(universeMode) .. ':' .. tostring(bucketKind) .. ':' .. spec_key.fromSpec(normalized)
  local workspace = type(opts.workspace) == 'table' and opts.workspace or nil
  local cache = workspace and workspace.cellSelectionPlans or nil
  local cached = cache and cache[cacheKey] or nil
  if cached then
    incrementMetric(opts.metrics, 'cellSelectionCacheHits')
    return cached, nil
  end
  local matchEntries = nil
  if queryHasFiniteMatch(normalized) then
    matchEntries = {}
    resolveMatch(index, normalized, {}, matchEntries)
    if normalized.exclude then
      matchEntries = filterExcludedEntries(matchEntries, normalized)
    end
    table.sort(matchEntries, function(a, b)
      return a.key < b.key
    end)
  end
  if bucketKind == 'deferred' then
    if matchEntries and #matchEntries == 0 then
      if opts.allowEmpty == true then return {empty = true, count = 0}, nil end
      return nil, { path .. ': resolved to zero cells' }
    end
    cached = {
      predicate = buildPredicate(normalized, true),
      route = {kind = 'deferred'},
      universe = buildUniverse(universeMode, matchEntries, true),
      count = matchEntries and #matchEntries or nil,
      exactCellCount = 0,
    }
    incrementMetric(opts.metrics, 'cellSelectionPlansBuilt')
    if cache then cache[cacheKey] = cached end
    return cached, nil
  end
  local entries, seen = {}, {}
  if bucketKind == 'cell' then
    resolveExact(index, normalized, seen, entries)
    resolveCoords(index, normalized, seen, entries)
    if normalized.exclude then
      entries = filterExcludedEntries(entries, normalized)
    end
  elseif bucketKind == 'region' then
    resolveRegionBuckets(index, normalized, seen, entries)
  else
    resolveWorldspaceBuckets(index, normalized, seen, entries)
  end
  table.sort(entries, function(a, b)
    return a.key < b.key
  end)
  if #entries == 0 and not (matchEntries and #matchEntries > 0) then
    if opts.allowEmpty == true then return {empty = true, count = 0}, nil end
    return nil, { path .. ': resolved to zero cells' }
  end
  local exactPrevisitEntries = collectPrevisitEntries(entries)
  local previsitEntries = bucketKind == 'cell' and exactPrevisitEntries or nil
  local deferredMatchCount = matchEntries and #matchEntries or nil
  local count = math.max(#entries, deferredMatchCount or 0)
  local exactCellCount = bucketKind == 'cell' and #entries or 0
  local route
  if bucketKind == 'region' then
    route = buildRegionRoute(entries)
  elseif bucketKind == 'worldspace' then
    route = buildWorldspaceRoute(entries)
  else
    route = buildExactRoute(entries, cacheKey)
  end
  local hasDeferred = queryNeedsDeferredRoute(normalized, bucketKind)
  if hasDeferred then
    route = {kind = 'union', routes = {route, {kind = 'deferred'}}}
  end
  local universeEntries = mergeUniverseEntries(entries, matchEntries)
  cached = {
    predicate = buildPredicate(normalized, hasDeferred),
    route = route,
    universe = buildUniverse(
      universeMode,
      universeEntries,
      hasDeferred
    ),
    count = count,
    exactCellCount = exactCellCount,
    previsitEntries = previsitEntries and #previsitEntries > 0 and previsitEntries or nil,
  }
  incrementMetric(opts.metrics, 'cellSelectionPlansBuilt')
  if cache then cache[cacheKey] = cached end
  return cached, nil
end
local function finiteUniverseEntries(selection)
  local universe = selection and selection.universe or nil
  return universe and universe.kind == 'finite' and universe.entries or nil
end
function M.singleUniverseEntry(selection)
  local entries = finiteUniverseEntries(selection)
  return entries and #entries == 1 and entries[1] or nil
end
function M.previsitEntries(selection)
  return selection and selection.previsitEntries or nil
end
function M.validateExactDestinationSpec(cellSpec, path)
  path = path or 'cell'
  local normalized, normalizeErr = normalizeCellSpec(cellSpec)
  if normalizeErr then
    return nil, path .. ': ' .. tostring(normalizeErr)
  end
  if normalized == nil then
    return nil, path .. ': required'
  end
  if normalized.match ~= nil then
    return nil, path .. ': wildcard or match cell selections cannot be used as place destinations'
  end
  if normalized.exclude ~= nil then
    return nil, path .. '.exclude: is not allowed for place destinations'
  end
  if normalized.exact == nil and normalized.coords == nil then
    return nil, path .. ': place destinations must use exact or coords'
  end
  return true, nil
end

return M
