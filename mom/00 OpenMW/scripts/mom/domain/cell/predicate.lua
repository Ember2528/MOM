-- Matches compiled cell queries against normalized scalar cell identities.
local M = {}
local cell_identity = require('scripts.mom.domain.cell.identity')

local function fieldMatchesPattern(value, pattern)
  if value == nil then return false end
  if pattern.kind == 'all' then return true end
  if pattern.kind == 'exact' then return value == pattern.needle end
  if pattern.kind == 'prefix' then return value:sub(1, #pattern.needle) == pattern.needle end
  if pattern.kind == 'suffix' then return value:sub(-#pattern.needle) == pattern.needle end
  if pattern.kind == 'contains' then return string.find(value, pattern.needle, 1, true) ~= nil end
  return false
end

local function matchesBroadFilters(identity, query)
  if query.kind == 'interior' and identity.isExterior then return false end
  if query.kind == 'exterior' and not identity.isExterior then return false end
  if query.worldspace then
    local matched = false
    for i = 1, #query.worldspace do
      if identity.worldspaceKey == query.worldspace[i] then
        matched = true
        break
      end
    end
    if not matched then return false end
  end
  if query.region then
    local matched = false
    for i = 1, #query.region do
      if identity.regionKey == query.region[i] then
        matched = true
        break
      end
    end
    if not matched then return false end
  end
  return true
end

local function matchesExact(identity, query)
  local exact = query and query.exact or nil
  if not exact then return false end
  for i = 1, #exact do
    local value = exact[i]
    if value == identity.idLower or value == identity.key then
      return true
    end
  end
  return false
end

local function matchesCoords(identity, query)
  local coords = query and query.coords or nil
  if not (coords and identity.isExterior and identity.packedCellKey) then return false end
  local worldspaces = query.worldspace or {cell_identity.DEFAULT_WORLDSPACE}
  for i = 1, #coords do
    local pair = coords[i]
    local packedCellKey = cell_identity.packedCellKeyForCoords(pair.x, pair.y)
    for j = 1, #worldspaces do
      if packedCellKey == identity.packedCellKey and worldspaces[j] == identity.worldspaceKey then
        return true
      end
    end
  end
  return false
end

local function matchesPattern(identity, query)
  local match = query and query.match or nil
  if not match then return false end
  for i = 1, #match do
    local pattern = match[i]
    if fieldMatchesPattern(identity.idLower, pattern)
        or fieldMatchesPattern(identity.nameLower, pattern)
        or fieldMatchesPattern(identity.displayNameLower, pattern) then
      return true
    end
  end
  return false
end

function M.matchesQuery(identity, query)
  if not (identity and query and matchesBroadFilters(identity, query)) then return false end
  local matched = false
  if query.exact then matched = matchesExact(identity, query) end
  if not matched and query.coords then matched = matchesCoords(identity, query) end
  if not matched and query.match then matched = matchesPattern(identity, query) end
  if not matched and query.exact == nil and query.coords == nil and query.match == nil then
    matched = true
  end
  if not matched then return false end
  if query.exclude and M.matchesQuery(identity, query.exclude) then return false end
  return true
end

function M.matches(predicate, identity)
  if not predicate then return true end
  return M.matchesQuery(identity, predicate.query)
end

M.fieldMatchesPattern = fieldMatchesPattern

M.matchesBroadFilters = matchesBroadFilters

return M
