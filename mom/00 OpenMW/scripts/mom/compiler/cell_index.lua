local M = {}
local cell_identity = require('scripts.mom.domain.cell.identity')
local strings = require('scripts.mom.common.strings')
local lowerString = strings.lowerString
local world = require('openmw.world')
-- This builder is stateless. A compile context retains its result lazily for
-- exactly one atomic source-set attempt.
local function appendIndexBucket(index, key, entry)
  if not key then return end
  local bucket = index[key]
  if not bucket then
    bucket = {}
    index[key] = bucket
  end
  bucket[#bucket + 1] = entry
end
local function appendNestedIndexBucket(index, key1, key2, entry)
  if not (key1 and key2) then return end
  local outer = index[key1]
  if not outer then
    outer = {}
    index[key1] = outer
  end
  appendIndexBucket(outer, key2, entry)
end
local function sortExteriorEntries(entries)
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
    return tostring(a.key) < tostring(b.key)
  end)
end
local function sortNestedExteriorBuckets(index)
  for _, outer in pairs(index) do
    for _, bucket in pairs(outer) do
      sortExteriorEntries(bucket)
    end
  end
end
local function buildEntry(cellObj)
  if not cellObj then return nil end
  local cellId = cellObj.id and tostring(cellObj.id) or nil
  local idLower = lowerString(cellId)
  if not idLower then return nil end
  local isExterior = cellObj.isExterior == true
  local identity = cell_identity.fromCellObject(cellObj, cellId)
  local key = identity and identity.key or idLower
  if not key then return nil end
  return {
    key = key,
    id = cellId,
    idLower = idLower,
    interiorKey = not isExterior and key or nil,
    nameLower = lowerString(cellObj.name),
    displayNameLower = lowerString(cellObj.displayName),
    isExterior = isExterior,
    gridX = isExterior and tonumber(cellObj.gridX) or nil,
    gridY = isExterior and tonumber(cellObj.gridY) or nil,
    regionKey = identity and identity.regionKey or nil,
    worldspaceKey = identity and identity.worldspaceKey or nil,
    packedCellKey = identity and identity.packedCellKey or nil,
  }
end
function M.build()
  assert(world.cells, 'compiler requires openmw.world.cells')
  local index = {
    entries = {},
    byKey = {},
    byId = {},
    byName = {},
    byDisplayName = {},
    byExteriorWorldspace = {},
    byRegion = {},
    byWorldspace = {},
    totalCount = 0,
    interiorCount = 0,
    exteriorCount = 0,
  }
  -- The collection is fixed during one compile. Read its size once instead
  -- of asking the engine's iterator to recompute it for every cell.
  local cells = world.cells
  for i = 1, #cells do
    local cellObj = cells[i]
    local entry = buildEntry(cellObj)
    if entry then
      index.entries[#index.entries + 1] = entry
      index.byKey[entry.key] = entry
      appendIndexBucket(index.byId, entry.idLower, entry)
      appendIndexBucket(index.byName, entry.nameLower, entry)
      appendIndexBucket(index.byDisplayName, entry.displayNameLower, entry)
      if entry.isExterior then
        appendNestedIndexBucket(index.byExteriorWorldspace, entry.worldspaceKey, entry.packedCellKey, entry)
        appendNestedIndexBucket(index.byRegion, entry.worldspaceKey, entry.regionKey, entry)
        appendIndexBucket(index.byWorldspace, entry.worldspaceKey, entry)
      end
      index.totalCount = index.totalCount + 1
      if entry.isExterior then
        index.exteriorCount = index.exteriorCount + 1
      else
        index.interiorCount = index.interiorCount + 1
      end
    end
  end
  for _, bucket in pairs(index.byWorldspace) do
    sortExteriorEntries(bucket)
  end
  sortNestedExteriorBuckets(index.byRegion)
  return index
end
return M
