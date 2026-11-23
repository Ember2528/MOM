-- Compiler-built lookup/automaton for cell routes and predicates. Runtime
-- matching depends on cell-string length, never authored selector cardinality.
local M = {}

local cell_identity = require('scripts.mom.domain.cell.identity')

local function set(values)
  local out = {}
  for i = 1, #(values or {}) do out[values[i]] = true end
  return out
end

local function nestedSet(groups, valuesField)
  local out = {}
  for i = 1, #(groups or {}) do
    local group = groups[i]
    local key = group.worldspaceKey
    local bucket = out[key]
    if bucket == nil then bucket = {} out[key] = bucket end
    for j = 1, #(group[valuesField] or {}) do
      bucket[tostring(group[valuesField][j])] = true
    end
  end
  return out
end

local function addNested(target, source)
  for outer, values in pairs(source or {}) do
    local bucket = target[outer]
    if bucket == nil then bucket = {} target[outer] = bucket end
    for value in pairs(values) do bucket[value] = true end
  end
end

local function addSet(target, source)
  for value in pairs(source or {}) do target[value] = true end
end

local function appendRoute(index, route)
  if route == nil or route.kind == 'deferred' or route.kind == 'shared' then
    index.all = true
    return
  end
  if route.kind == 'union' then
    for i = 1, #(route.routes or {}) do appendRoute(index, route.routes[i]) end
  elseif route.kind == 'exact' then
    addSet(index.interiorKeys, set(route.interiorKeys))
    addNested(index.exteriorKeys, nestedSet(route.exteriors, 'packedCellKeys'))
  elseif route.kind == 'footprint' then
    addNested(index.exteriorKeys, nestedSet(route.exteriors, 'packedCellKeys'))
  elseif route.kind == 'region' then
    addNested(index.regionKeys, nestedSet(route.worldspaces, 'regionKeys'))
  elseif route.kind == 'worldspace' then
    addSet(index.worldspaceKeys, set(route.worldspaceKeys))
  else
    index.invalidKind = tostring(route.kind)
  end
end

function M.buildRoute(route)
  local index = {
    all = false,
    interiorKeys = {},
    exteriorKeys = {},
    regionKeys = {},
    worldspaceKeys = {},
  }
  appendRoute(index, route)
  return index
end

function M.matchesRoute(index, cell)
  if type(index) ~= 'table' then
    return nil, 'cell route index is invalid'
  end
  if index.invalidKind ~= nil then
    return nil, 'selection route kind is unsupported: ' .. index.invalidKind
  end
  if index.all == true then return true, nil end
  if cell.isExterior then
    local exterior = index.exteriorKeys[cell.worldspaceKey]
    if exterior and exterior[tostring(cell.packedCellKey)] == true then
      return true, nil
    end
    local regions = index.regionKeys[cell.worldspaceKey]
    if regions and regions[tostring(cell.regionKey)] == true then
      return true, nil
    end
    return index.worldspaceKeys[cell.worldspaceKey] == true, nil
  end
  return index.interiorKeys[cell.interiorKey or cell.key] == true
    or index.worldspaceKeys[cell.worldspaceKey] == true, nil
end

local function newTrie()
  return {{next = {}, terminal = false}}
end

local function addTrie(trie, value, reverse)
  local node = 1
  if value == '' then trie[node].terminal = true return end
  local first, last, step = 1, #value, 1
  if reverse then first, last, step = #value, 1, -1 end
  for i = first, last, step do
    local character = value:sub(i, i)
    local nextNode = trie[node].next[character]
    if nextNode == nil then
      nextNode = #trie + 1
      trie[node].next[character] = nextNode
      trie[nextNode] = {next = {}, terminal = false}
    end
    node = nextNode
  end
  trie[node].terminal = true
end

local function buildContains(values)
  local nodes = newTrie()
  for i = 1, #values do addTrie(nodes, values[i], false) end
  local queue, first = {}, 1
  for _, child in pairs(nodes[1].next) do
    nodes[child].fail = 1
    queue[#queue + 1] = child
  end
  while first <= #queue do
    local parent = queue[first]
    first = first + 1
    for character, child in pairs(nodes[parent].next) do
      local failure = nodes[parent].fail or 1
      while failure ~= 1 and nodes[failure].next[character] == nil do
        failure = nodes[failure].fail or 1
      end
      local fallback = nodes[failure].next[character]
      if fallback ~= nil and fallback ~= child then failure = fallback else failure = 1 end
      nodes[child].fail = failure
      nodes[child].terminal = nodes[child].terminal
        or nodes[failure].terminal == true
      queue[#queue + 1] = child
    end
  end
  nodes[1].fail = 1
  return nodes
end

local function patternIndex(patterns)
  local out = {
    all = false,
    exact = {},
    prefix = newTrie(),
    suffix = newTrie(),
    containsValues = {},
  }
  for i = 1, #(patterns or {}) do
    local pattern = patterns[i]
    local needle = tostring(pattern.needle or '')
    if pattern.kind == 'all' then
      out.all = true
    elseif pattern.kind == 'exact' then
      out.exact[needle] = true
    elseif pattern.kind == 'prefix' then
      addTrie(out.prefix, needle, false)
    elseif pattern.kind == 'suffix' then
      addTrie(out.suffix, needle, true)
    elseif pattern.kind == 'contains' then
      out.containsValues[#out.containsValues + 1] = needle
    else
      out.invalidKind = tostring(pattern.kind)
    end
  end
  out.contains = buildContains(out.containsValues)
  out.containsValues = nil
  return out
end

local function coordsIndex(query)
  local out = {}
  local worldspaces = query and query.worldspace
    or {cell_identity.DEFAULT_WORLDSPACE}
  for i = 1, #(worldspaces or {}) do
    local bucket = {}
    out[worldspaces[i]] = bucket
    for j = 1, #(query and query.coords or {}) do
      local pair = query.coords[j]
      local packed = cell_identity.packedCellKeyForCoords(pair.x, pair.y)
      if packed ~= nil then bucket[tostring(packed)] = true end
    end
  end
  return out
end

function M.buildQuery(query)
  if query == nil then return nil end
  return {
    kind = query.kind,
    worldspaces = set(query.worldspace),
    regions = set(query.region),
    exact = set(query.exact),
    coords = coordsIndex(query),
    patterns = patternIndex(query.match),
    hasExact = query.exact ~= nil,
    hasCoords = query.coords ~= nil,
    hasPatterns = query.match ~= nil,
    exclude = M.buildQuery(query.exclude),
  }
end

local function trieMatches(trie, value, reverse)
  local node = 1
  if trie[node].terminal then return true end
  local first, last, step = 1, #value, 1
  if reverse then first, last, step = #value, 1, -1 end
  for i = first, last, step do
    node = trie[node].next[value:sub(i, i)]
    if node == nil then return false end
    if trie[node].terminal then return true end
  end
  return false
end

local function containsMatches(nodes, value)
  local node = 1
  if nodes[node].terminal then return true end
  for i = 1, #value do
    local character = value:sub(i, i)
    while node ~= 1 and nodes[node].next[character] == nil do
      node = nodes[node].fail or 1
    end
    node = nodes[node].next[character] or 1
    if nodes[node].terminal then return true end
  end
  return false
end

local function patternsMatch(index, value)
  if value == nil then return false end
  if index.all or index.exact[value] then return true end
  return trieMatches(index.prefix, value, false)
    or trieMatches(index.suffix, value, true)
    or containsMatches(index.contains, value)
end

local function queryMatches(index, identity)
  if index.kind == 'interior' and identity.isExterior then return false end
  if index.kind == 'exterior' and not identity.isExterior then return false end
  if next(index.worldspaces) ~= nil
      and index.worldspaces[identity.worldspaceKey] ~= true then return false end
  if next(index.regions) ~= nil
      and index.regions[identity.regionKey] ~= true then return false end
  local matched = false
  if index.hasExact then
    matched = index.exact[identity.idLower] == true
      or index.exact[identity.key] == true
  end
  if not matched and index.hasCoords and identity.isExterior then
    local bucket = index.coords[identity.worldspaceKey]
    matched = bucket ~= nil
      and bucket[tostring(identity.packedCellKey)] == true
  end
  if not matched and index.hasPatterns then
    matched = patternsMatch(index.patterns, identity.idLower)
      or patternsMatch(index.patterns, identity.nameLower)
      or patternsMatch(index.patterns, identity.displayNameLower)
  end
  if not index.hasExact and not index.hasCoords and not index.hasPatterns then
    matched = true
  end
  if not matched then return false end
  return index.exclude == nil or not queryMatches(index.exclude, identity)
end

function M.matchesQuery(index, identity)
  if index == nil then return true, nil end
  if type(index) ~= 'table' then
    return nil, 'cell predicate index is invalid'
  end
  if index.patterns.invalidKind ~= nil then
    return nil, 'cell pattern kind is unsupported: ' .. index.patterns.invalidKind
  end
  return queryMatches(index, identity), nil
end

return M
