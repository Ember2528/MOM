-- Pure normalization and matching for manifest selection programs.
local M = {}

local cell_identity = require('scripts.mom.domain.cell.identity')
local cell_match_index = require('scripts.mom.contracts.cell_match_index')
local cell_predicate = require('scripts.mom.domain.cell.predicate')
local predicate_contract = require('scripts.mom.contracts.predicate')
local ref_position = require('scripts.mom.domain.ref.position')

local strings = require('scripts.mom.common.strings')
M.nonEmpty = strings.isNonEmpty

M.lower = strings.lowerString

function M.denseArray(value, path)
  if type(value) ~= 'table' then return nil, tostring(path) .. ': expected array' end
  local count, maximum = 0, 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key % 1 ~= 0 then
      return nil, tostring(path) .. ': expected dense array'
    end
    count = count + 1
    if key > maximum then maximum = key end
  end
  if count ~= maximum then return nil, tostring(path) .. ': expected dense array' end
  return value, nil
end

function M.normalizeCell(raw, path)
  path = tostring(path or 'cell')
  if type(raw) ~= 'table' then return nil, path .. ': expected cell facts' end
  local id = raw.id ~= nil and tostring(raw.id) or nil
  local key = M.lower(raw.key or raw.cellKey or raw.idLower or id)
  if not M.nonEmpty(id) or key == nil then return nil, path .. ': id and key are required' end
  local isExterior = raw.isExterior
  if isExterior == nil then isExterior = raw.gridX ~= nil and raw.gridY ~= nil end
  if type(isExterior) ~= 'boolean' then return nil, path .. '.isExterior: expected boolean' end
  local gridX = raw.gridX ~= nil and tonumber(raw.gridX) or nil
  local gridY = raw.gridY ~= nil and tonumber(raw.gridY) or nil
  local worldspaceKey = M.lower(raw.worldspaceKey or raw.worldSpaceId or raw.worldspace)
    or cell_identity.DEFAULT_WORLDSPACE
  local packedCellKey = raw.packedCellKey
  if isExterior and packedCellKey == nil then
    packedCellKey = cell_identity.packedCellKeyForCoords(gridX, gridY)
  end
  if isExterior and packedCellKey == nil then
    return nil, path .. ': exterior cell requires grid coordinates or packedCellKey'
  end
  return {
    id = id,
    idLower = M.lower(raw.idLower or id),
    key = key,
    interiorKey = not isExterior and M.lower(raw.interiorKey or key) or nil,
    isExterior = isExterior,
    worldspaceKey = worldspaceKey,
    regionKey = M.lower(raw.regionKey or raw.regionId or raw.region),
    gridX = gridX,
    gridY = gridY,
    packedCellKey = packedCellKey,
    nameLower = M.lower(raw.nameLower or raw.name or id),
    displayNameLower = M.lower(raw.displayNameLower or raw.displayName or raw.name or id),
  }, nil
end

local function same(left, right)
  return left == right or (left ~= nil and right ~= nil and tostring(left) == tostring(right))
end

local function contains(values, expected)
  for i = 1, #(values or {}) do if same(values[i], expected) then return true end end
  return false
end

local function matchesExteriorGroups(groups, cell)
  if not cell.isExterior then return false end
  for i = 1, #(groups or {}) do
    local group = groups[i]
    if M.lower(group.worldspaceKey) == cell.worldspaceKey
        and contains(group.packedCellKeys, cell.packedCellKey) then
      return true
    end
  end
  return false
end

local function matchesRoute(route, cell)
  if route == nil or route.kind == 'deferred' or route.kind == 'shared' then return true, nil end
  if route.kind == 'union' then
    for i = 1, #(route.routes or {}) do
      local matched, err = matchesRoute(route.routes[i], cell)
      if matched == nil then return nil, err end
      if matched then return true, nil end
    end
    return false, nil
  end
  if route.kind == 'exact' then
    if cell.isExterior then return matchesExteriorGroups(route.exteriors, cell), nil end
    return contains(route.interiorKeys, cell.interiorKey or cell.key), nil
  end
  if route.kind == 'footprint' then return matchesExteriorGroups(route.exteriors, cell), nil end
  if route.kind == 'region' then
    for i = 1, #(route.worldspaces or {}) do
      local group = route.worldspaces[i]
      if M.lower(group.worldspaceKey) == cell.worldspaceKey
          and contains(group.regionKeys, cell.regionKey) then
        return true, nil
      end
    end
    return false, nil
  end
  if route.kind == 'worldspace' then return contains(route.worldspaceKeys, cell.worldspaceKey), nil end
  return nil, 'selection route kind is unsupported: ' .. tostring(route.kind)
end

function M.cellMatches(selection, cell)
  local cellSelection = selection and selection.cell or nil
  if cellSelection == nil then return true, nil end
  if type(cellSelection) ~= 'table' then return nil, 'cell selection is malformed' end
  local routeMatched, routeError
  if cellSelection.routeIndex ~= nil then
    routeMatched, routeError = cell_match_index.matchesRoute(
      cellSelection.routeIndex,
      cell
    )
  else
    routeMatched, routeError = matchesRoute(cellSelection.route, cell)
  end
  if routeMatched == nil then return nil, routeError end
  if not routeMatched then return false, nil end
  if cellSelection.predicate ~= nil then
    if type(cellSelection.predicate) ~= 'table'
        or type(cellSelection.predicate.query) ~= 'table' then
      return nil, 'cell selection predicate is malformed'
    end
    if cellSelection.predicateIndex ~= nil then
      local matched, matchError = cell_match_index.matchesQuery(
        cellSelection.predicateIndex,
        cell
      )
      if matched == nil then return nil, matchError end
      return matched, nil
    end
    local ok, matched = pcall(cell_predicate.matches, cellSelection.predicate, cell)
    if not ok then return nil, 'cell selection predicate failed: ' .. tostring(matched) end
    return matched == true, nil
  end
  return true, nil
end

local function normalizeOrientation(raw)
  if type(raw) ~= 'table' then return nil end
  return {
    yawDegrees = tonumber(raw.yawDegrees),
    tiltXDegrees = tonumber(raw.tiltXDegrees),
    tiltYDegrees = tonumber(raw.tiltYDegrees),
  }
end

function M.normalizeRefFacts(raw, currentCell, path)
  path = tostring(path or 'ref')
  if type(raw) ~= 'table' then return nil, path .. ': expected ref facts' end
  local recordId = M.lower(raw.recordId)
  local typeName = raw.typeName ~= nil and tostring(raw.typeName) or nil
  if recordId == nil or not M.nonEmpty(typeName) then
    return nil, path .. ': recordId and typeName are required'
  end
  if type(raw.origin) ~= 'table' then
    return nil, path .. '.origin: expected origin facts'
  end
  local origin = raw.origin
  local originCellRaw = origin.cell
  local originCell = nil
  if originCellRaw ~= nil then
    local originCellError
    originCell, originCellError = M.normalizeCell(originCellRaw, path .. '.origin.cell')
    if not originCell then return nil, originCellError end
  end
  local originCellId = M.lower(
    origin.cellId or (originCell and (originCell.key or originCell.id))
  )
  local originPosition = ref_position.normalizePosition(origin.position)
  local objectId = raw.objectId ~= nil and tostring(raw.objectId) or nil
  if objectId == '' then objectId = nil end
  if objectId == nil then
    return nil, path .. ': objectId is required'
  end
  return {
    recordId = recordId,
    typeName = typeName,
    objectId = objectId,
    origin = {cellId = originCellId, position = originPosition, cell = originCell,
      rotation = origin.rotation},
    currentCell = currentCell,
    position = ref_position.normalizePosition(raw.position or raw.currentPosition),
    orientation = normalizeOrientation(raw.orientation),
  }, nil
end

function M.listSet(values, lowerValues)
  local out = {}
  for i = 1, #(values or {}) do
    local value = lowerValues and M.lower(values[i]) or values[i]
    if value ~= nil then out[value] = true end
  end
  return out
end

local function normalizedAngle(value)
  value = tonumber(value)
  if value == nil then return nil end
  value = value % 360
  if value > 180 then value = 360 - value end
  return math.abs(value)
end

local function angleDifference(left, right)
  if left == nil or right == nil then return nil end
  local distance = math.abs((left % 360) - (right % 360))
  return distance > 180 and 360 - distance or distance
end

function M.matchesPredicates(predicates, facts)
  for i = 1, #(predicates or {}) do
    local predicate = predicates[i]
    if predicate_contract.isRecordIdExclude(predicate) then
      if type(predicate.excludedIds) ~= 'table' then
        return nil, 'record-id exclusion predicate is malformed'
      end
      if predicate.excludedIds[facts.recordId] == true then return false, nil end
    elseif predicate_contract.isOrientation(predicate) then
      local orientation = facts.orientation
      if type(orientation) ~= 'table' then return false, nil end
      if predicate.mode == predicate_contract.MODE_FACING then
        local difference = angleDifference(orientation.yawDegrees, predicate.direction)
        if difference == nil or difference > (tonumber(predicate.tolerance) or 45) then
          return false, nil
        end
      elseif predicate.mode == predicate_contract.MODE_UPRIGHT then
        local x = normalizedAngle(orientation.tiltXDegrees)
        local y = normalizedAngle(orientation.tiltYDegrees)
        local maximum = tonumber(predicate.maxTilt) or 25
        if x == nil or y == nil or x > maximum or y > maximum then return false, nil end
      else
        return nil, 'orientation predicate mode is unsupported: ' .. tostring(predicate.mode)
      end
    else
      return nil, 'selection predicate kind is unsupported: ' .. tostring(predicate and predicate.kind)
    end
  end
  return true, nil
end

function M.identityFacts(identity)
  local data = identity and identity.data or nil
  if type(data) ~= 'table' then return nil end
  if identity.kind ~= 'ref' and identity.kind ~= 'output' then return nil end
  return {
    recordId = M.lower(data.recordId),
    typeName = data.typeName,
    objectId = data.objectId,
    origin = {
      cellId = data.origin and M.lower(data.origin.cellId) or nil,
      position = data.origin and ref_position.normalizePosition(data.origin.position) or nil,
    },
  }
end

function M.predicatesNeedLiveRead(predicates)
  for i = 1, #(predicates or {}) do
    if predicate_contract.isOrientation(predicates[i]) then return true end
  end
  return false
end

function M.inheritedNeedsLiveRead(selection)
  return selection.cell ~= nil or selection.additionalCells ~= nil or #(selection.predicates or {}) > 0
    or (type(selection.directTargets) == 'table'
      and #(selection.directTargets.entries or {}) > 0)
end

return M
