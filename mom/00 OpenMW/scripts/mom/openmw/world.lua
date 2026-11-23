-- Clean OpenMW world adapter: observed cells, cell/ref fact normalization,
-- per-frame cell:getAll cache, logical target resolution, and teleport fencing.
local M = {}

local cell_identity = require('scripts.mom.domain.cell.identity')
local model_path = require('scripts.mom.contracts.model_path')
local openmw_api = require('scripts.mom.openmw.api')
local ref_position = require('scripts.mom.domain.ref.position')
local ref_type = require('scripts.mom.contracts.ref_type')
local strings = require('scripts.mom.common.strings')
local tables = require('scripts.mom.common.tables')

local call = openmw_api.call
local property = openmw_api.property
local nonEmpty = strings.isNonEmpty
local lower = strings.lowerString
local DEFAULT_WORLDSPACE = cell_identity.DEFAULT_WORLDSPACE

local function plainPosition(value)
  local norm = ref_position.normalizePosition(value)
  if norm == nil then return nil end
  return {x = norm.x, y = norm.y, z = norm.z}
end

local function rotationDegrees(rotation)
  if rotation == nil or type(rotation.getAnglesZYX) ~= 'function' then
    return nil, 'ref rotation API is unavailable'
  end
  local z, y, x = call(rotation.getAnglesZYX, rotation)
  if type(z) ~= 'number' or type(y) ~= 'number' or type(x) ~= 'number' then
    return nil, 'ref rotation API returned invalid angles'
  end
  return {
    yaw = math.deg(z),
    pitch = math.deg(y),
    roll = math.deg(x),
    yawDegrees = math.deg(z),
    tiltXDegrees = math.deg(x),
    tiltYDegrees = math.deg(y),
  }, nil
end

local function routesForCell(facts)
  local keys = {shared = true}
  if facts.isExterior then
    keys['exterior:' .. facts.worldspaceKey .. ':' .. tostring(facts.packedCellKey)] = true
    keys['worldspace:' .. facts.worldspaceKey] = true
    if facts.regionKey ~= nil then
      keys['region:' .. facts.worldspaceKey .. ':' .. facts.regionKey] = true
    end
  else
    keys['interior:' .. tostring(facts.interiorKey or facts.key)] = true
  end
  return tables.sortedKeys(keys)
end

local function stableObjectId(ref)
  local objectId, idErr = property(ref, 'id')
  if idErr ~= nil or not nonEmpty(objectId) then
    return nil, idErr or 'ref object id is unavailable'
  end
  local contentFile, fileErr = property(ref, 'contentFile')
  if fileErr ~= nil then return nil, fileErr end
  if contentFile == nil then
    if objectId:match('^@0x%x+$') then return objectId, nil end
    return nil, 'ref generated object id is invalid'
  end
  if not nonEmpty(contentFile) then return nil, 'ref content file is invalid' end
  local hex = objectId:match('^0[xX](%x+)$')
  if hex == nil then return nil, 'ref object id is not an OpenMW form id' end
  local localIndex = tonumber(hex:sub(-6), 16)
  return string.format('content:%06x:%s', localIndex, contentFile:lower()), nil
end

function M.new(deps, opts)
  deps = deps or {}
  opts = opts or {}
  local world = openmw_api.dependency(deps, 'world', 'openmw.world')
  local types = openmw_api.dependency(deps, 'types', 'openmw.types')
  local core = openmw_api.dependency(deps, 'core', 'openmw.core')

  -- Prebuild O(1) ref.type -> typeName map.
  local typeNames = ref_type.names()
  local typeToName = {}
  for i = 1, #typeNames do
    local name = typeNames[i]
    if types and types[name] ~= nil then
      typeToName[types[name]] = name
    end
  end

  local observed = {}        -- cellKey -> { handle, facts, routes, loaded, previsit, lastSeenFrame }
  local byHandle = {}        -- cell userdata -> entry
  local cellCache = {}       -- lowerKey/id -> cell userdata
  local factsCache = {}      -- lowerKey -> facts
  local worldspaceHints = {} -- worldspaceKey -> exterior cell userdata
  local liveOutputs = {}     -- outputRefId -> GameObject handle
  local fencedCells = {}     -- cellKey -> frame (fenced until frame advances)
  local frameCacheFrame = -1
  local frameGetAllCache = {} -- cellKey..'\0'..(typeName or '*') -> array of refs
  local frameFactsCache = {}  -- GameObject -> normalized ref facts

  local api = {
    plainPosition = plainPosition,
    rotationDegrees = rotationDegrees,
    routesForCell = routesForCell,
    stableObjectId = stableObjectId,
  }

  function api.beginFrame(frame)
    if frameCacheFrame ~= frame then
      frameCacheFrame = frame
      frameGetAllCache = {}
      frameFactsCache = {}
      -- Clear expired teleport fences from prior frames.
      for key, fenceFrame in pairs(fencedCells) do
        if fenceFrame < frame then fencedCells[key] = nil end
      end
    end
  end

  function api.isValid(ref)
    if ref == nil then return false end
    local fn = property(ref, 'isValid')
    return fn ~= nil and call(fn, ref) == true
  end

  function api.typeNameForRef(ref)
    local refType, err = property(ref, 'type')
    if err ~= nil then return nil, err end
    if refType ~= nil and typeToName[refType] ~= nil then
      return typeToName[refType], nil
    end
    for i = 1, #typeNames do
      local name = typeNames[i]
      local ns = types and types[name]
      if openmw_api.isNamespace(ns) and type(ns.objectIsInstance) == 'function' then
        local ok = call(ns.objectIsInstance, ref)
        if ok == true then return name, nil end
      end
    end
    return nil, 'ref type is unsupported'
  end

  function api.recordModelForRef(ref, typeName)
    local ns = types and types[typeName]
    if not openmw_api.isNamespace(ns) or type(ns.record) ~= 'function' then
      return nil, 'record API is unavailable for ' .. tostring(typeName)
    end
    local rec, recErr = call(ns.record, ref)
    if rec == nil then return nil, recErr or 'ref record is unavailable' end
    local raw, modelErr = property(rec, 'model')
    if modelErr ~= nil then return nil, modelErr end
    local norm = model_path.normalize(raw)
    if norm == nil then return nil, 'ref record model is unavailable' end
    return norm, nil
  end

  function api.describeCell(cell)
    if cell == nil then return nil, 'cell is unavailable' end
    local entry = byHandle[cell]
    if entry ~= nil then return entry.facts, nil end
    local ok, facts = pcall(function()
      local identity = cell_identity.fromCellObject(cell, cell.id)
      if identity == nil or not nonEmpty(identity.id) or not nonEmpty(identity.key) then
        error('cell has no stable identity', 0)
      end
      local hasSky = false
      if identity.isExterior == true then
        hasSky = true
      else
        local sky = property(cell, 'hasSky')
        hasSky = sky == true
      end
      return {
        id = tostring(identity.id),
        idLower = lower(identity.idLower or identity.id),
        key = tostring(identity.key),
        interiorKey = identity.isExterior == true and nil
          or lower(identity.interiorKey or identity.key),
        isExterior = identity.isExterior == true,
        worldspaceKey = lower(identity.worldspaceKey) or DEFAULT_WORLDSPACE,
        regionKey = lower(identity.regionKey or cell.region),
        gridX = identity.gridX,
        gridY = identity.gridY,
        packedCellKey = identity.packedCellKey,
        name = tostring(cell.name or identity.id),
        displayName = cell.displayName ~= nil and tostring(cell.displayName) or nil,
        nameLower = lower(cell.name or identity.id),
        displayNameLower = lower(cell.displayName or cell.name or identity.id),
        hasSky = hasSky,
      }
    end)
    if not ok then return nil, tostring(facts) end
    cellCache[facts.key] = cell
    cellCache[facts.idLower] = cell
    factsCache[facts.key] = facts
    if facts.isExterior then
      worldspaceHints[facts.worldspaceKey] = worldspaceHints[facts.worldspaceKey] or cell
    end
    return facts, nil
  end

  function api.resolveCell(idOrKey)
    local key = lower(idOrKey)
    if key == nil then return nil, 'cell identity is invalid' end
    local existing = observed[key]
    if existing ~= nil then return existing.handle, nil end
    if cellCache[key] ~= nil then return cellCache[key], nil end
    local parsed = cell_identity.parseExteriorKey(idOrKey)
    if parsed ~= nil then
      local hint = worldspaceHints[parsed.worldspace]
      local cell, err
      if hint ~= nil then
        cell, err = call(world.getExteriorCell, parsed.gridX, parsed.gridY, hint)
      elseif parsed.worldspace == DEFAULT_WORLDSPACE then
        cell, err = call(world.getExteriorCell, parsed.gridX, parsed.gridY)
      else
        return nil, 'exterior worldspace is not observed: ' .. tostring(parsed.worldspace)
      end
      if cell == nil then return nil, err or 'exterior cell is unavailable' end
      local facts, factsErr = api.describeCell(cell)
      if not facts then return nil, factsErr end
      return cell, nil
    end
    local byId, idErr = call(world.getCellById, tostring(idOrKey))
    if byId ~= nil then
      api.describeCell(byId)
      return byId, nil
    end
    local byName, nameErr = call(world.getCellByName, tostring(idOrKey))
    if byName ~= nil then
      api.describeCell(byName)
      return byName, nil
    end
    return nil, nameErr or idErr or ('cell is unavailable: ' .. tostring(idOrKey))
  end

  function api.observeCell(cell, frame, isPrevisit)
    if cell == nil then return nil, false end
    local facts, err = api.describeCell(cell)
    if not facts then return nil, false, err end
    local entry = observed[facts.key]
    local isNew = entry == nil
    if entry == nil then
      entry = {
        handle = cell,
        facts = facts,
        routes = routesForCell(facts),
        loaded = not isPrevisit,
        previsit = isPrevisit == true,
        lastSeenFrame = frame or 0,
      }
      observed[facts.key] = entry
      byHandle[cell] = entry
    else
      local handleChanged = entry.handle ~= cell
      if handleChanged then
        byHandle[entry.handle] = nil
        entry.handle = cell
        byHandle[cell] = entry
      end
      entry.facts = facts
      if not isPrevisit then entry.loaded = true end
      if isPrevisit then entry.previsit = true end
      entry.lastSeenFrame = frame or entry.lastSeenFrame
      if handleChanged then isNew = true end
    end
    return entry, isNew, nil
  end

  -- Synchronize observed loaded cells from world.players + world.activeActors + activeCells.
  -- Returns lists of newly entered cell entries and unloaded cell keys.
  function api.syncObservedCells(frame)
    local activeKeys = {}
    local entered = {}
    local function visit(cell)
      if cell == nil then return end
      local entry, isNew = api.observeCell(cell, frame, false)
      if entry ~= nil then
        activeKeys[entry.facts.key] = true
        if isNew then entered[#entered + 1] = entry end
      end
    end
    if type(world.activeCells) == 'table' or openmw_api.isNamespace(world.activeCells) then
      local ok = pcall(function()
        for i = 1, #world.activeCells do visit(world.activeCells[i]) end
      end)
      if not ok then
        pcall(function()
          for _, cell in pairs(world.activeCells) do visit(cell) end
        end)
      end
    end
    for _, list in ipairs({world.players, world.activeActors}) do
      if list ~= nil then
        pcall(function()
          for i = 1, #list do
            local obj = list[i]
            local c = obj and property(obj, 'cell')
            if c ~= nil then visit(c) end
          end
        end)
      end
    end
    local unloaded = {}
    for key, entry in pairs(observed) do
      if not activeKeys[key] and not entry.previsit then
        -- Unload cell only if not currently in active set and not seen this frame.
        if (entry.lastSeenFrame or 0) < frame then
          byHandle[entry.handle] = nil
          observed[key] = nil
          unloaded[#unloaded + 1] = key
        end
      end
    end
    return entered, unloaded
  end

  function api.previsitRoute(routeKey, frame)
    if type(routeKey) ~= 'string' then return nil end
    local worldspace, coords = routeKey:match('^exterior:(.*):([%-]?%d+,[%-]?%d+)$')
    local cell
    if worldspace ~= nil then
      local x, y = coords:match('^([%-]?%d+),([%-]?%d+)$')
      local key = cell_identity.exteriorKey(worldspace, tonumber(x), tonumber(y))
      cell = key and api.resolveCell(key) or nil
    else
      local interior = routeKey:match('^interior:(.+)$')
      cell = api.resolveCell(interior or routeKey)
    end
    if cell == nil then return nil end
    local entry = api.observeCell(cell, frame, true)
    return entry
  end

  function api.observedCells()
    return observed
  end

  function api.getObservedCell(cellKey)
    return observed[lower(cellKey) or '']
  end

  function api.fenceCell(cell, frame)
    if cell == nil then return end
    local facts = api.describeCell(cell)
    if facts then
      fencedCells[facts.key] = frame or frameCacheFrame
    end
  end

  function api.isCellFenced(cellKey, frame)
    local fenceFrame = fencedCells[cellKey]
    return fenceFrame ~= nil and fenceFrame >= (frame or frameCacheFrame)
  end

  -- Cached per-frame cell:getAll(typeApi) reader.
  function api.cellRefs(cell, typeName)
    if cell == nil then return {}, nil end
    local facts = api.describeCell(cell)
    local cacheKey = (facts and facts.key or tostring(cell)) .. '\0' .. (typeName or '*')
    local cached = frameGetAllCache[cacheKey]
    if cached ~= nil then return cached, nil end
    local typeApi = typeName ~= nil and types and types[typeName] or nil
    local ok, refs
    if typeApi ~= nil then
      ok, refs = pcall(cell.getAll, cell, typeApi)
    else
      ok, refs = pcall(cell.getAll, cell)
    end
    if not ok then return nil, tostring(refs) end
    local out = refs or {}
    frameGetAllCache[cacheKey] = out
    return out, nil
  end

  function api.describeRef(ref, ledger)
    if not api.isValid(ref) then return nil, 'ref is invalid' end
    local cached = frameFactsCache[ref]
    if cached ~= nil then return cached, nil end
    local objectId, idErr = stableObjectId(ref)
    if objectId == nil then return nil, idErr end
    local rawRecordId, recErr = property(ref, 'recordId')
    if recErr ~= nil or not nonEmpty(rawRecordId) then
      return nil, recErr or 'ref recordId is unavailable'
    end
    local recordId = lower(rawRecordId)
    local typeName, typeErr = api.typeNameForRef(ref)
    if typeName == nil then return nil, typeErr end
    local currentPos = plainPosition(property(ref, 'position'))
    local currentCell = property(ref, 'cell')
    local currentCellFacts = currentCell and api.describeCell(currentCell) or nil
    local startingCell = property(ref, 'startingCell')
    local originCell = startingCell and api.describeCell(startingCell) or nil
    local originPos = plainPosition(property(ref, 'startingPosition'))
    local originRot = nil
    local rawRot = property(ref, 'rotation')
    local angles = rawRot and rotationDegrees(rawRot) or nil
    local orientation = angles and {
      yawDegrees = angles.yawDegrees,
      tiltXDegrees = angles.tiltXDegrees,
      tiltYDegrees = angles.tiltYDegrees,
    } or nil
    local refId = objectId
    if objectId:sub(1, 1) == '@' and ledger ~= nil then
      local outId = ledger:getOutputIdByObjectId(objectId)
      if outId ~= nil then refId = outId end
    end
    -- For Doors with persisted origin (before MOM moved them), prefer saved origin.
    if typeName == 'Door' and ledger ~= nil then
      local stored = ledger:getRef(refId)
      if stored and type(stored.origin) == 'table' then
        originPos = stored.origin.position or originPos
        originRot = stored.origin.rotation or originRot
        if stored.origin.cellId and (originCell == nil or originCell.key ~= stored.origin.cellId) then
          local c = api.resolveCell(stored.origin.cellId)
          if c then originCell = api.describeCell(c) end
        end
      end
    end
    if typeName == 'Door' and originRot == nil then
      local sRot = property(ref, 'startingRotation')
      local sAngles = sRot and rotationDegrees(sRot) or nil
      if sAngles then
        originRot = {yaw = sAngles.yaw, pitch = sAngles.pitch, roll = sAngles.roll}
      end
    end
    local rawObjId = tostring(property(ref, 'id') or objectId)
    local facts = {
      id = refId,
      objectId = objectId,
      rawObjectId = rawObjId,
      recordId = recordId,
      typeName = typeName,
      position = currentPos,
      currentCell = currentCellFacts,
      cell = currentCellFacts,
      origin = {
        cellId = originCell and originCell.key or nil,
        cell = originCell,
        position = originPos,
        rotation = originRot,
      },
      orientation = orientation,
      isGenerated = objectId:sub(1, 1) == '@',
    }
    frameFactsCache[ref] = facts
    return facts, nil
  end

  function api.registerLiveOutput(outputId, ref)
    if nonEmpty(outputId) then
      liveOutputs[outputId] = ref
    end
  end

  function api.unregisterLiveOutput(outputId)
    if nonEmpty(outputId) then
      liveOutputs[outputId] = nil
    end
  end

  local function lookupContentRef(refId)
    local indexHex, contentFile = refId:match('^content:(%x%x%x%x%x%x):(.+)$')
    if indexHex == nil or core == nil or type(core.getFormId) ~= 'function' then
      return nil
    end
    local formId = call(core.getFormId, contentFile, tonumber(indexHex, 16))
    if formId == nil then return nil end
    local obj = call(world.getObjectByFormId, formId)
    if api.isValid(obj) then return obj end
    return nil
  end

  local function scanCellsForObjectId(cellKeys, wantedObjectId, typeName)
    for i = 1, #cellKeys do
      local cell = api.resolveCell(cellKeys[i])
      if cell ~= nil then
        local refs = api.cellRefs(cell, typeName)
        if refs then
          for j = 1, #refs do
            local ref = refs[j]
            if api.isValid(ref) then
              local rawId = property(ref, 'id')
              if tostring(rawId) == wantedObjectId then
                return ref
              end
              local stable = stableObjectId(ref)
              if stable == wantedObjectId then
                return ref
              end
            end
          end
        end
      end
    end
    return nil
  end

  -- Resolves any logical targetId (cell:, content:, output:) to a live OpenMW handle.
  function api.resolveTarget(targetId, ledger)
    if not nonEmpty(targetId) then return nil, 'targetId is invalid' end
    if targetId:sub(1, 5) == 'cell:' then
      return api.resolveCell(targetId:sub(6))
    end
    if targetId:sub(1, 7) == 'output:' then
      local live = liveOutputs[targetId]
      if api.isValid(live) then return live, nil end
      liveOutputs[targetId] = nil
      local stored = ledger and ledger:getRef(targetId)
      if stored == nil or not nonEmpty(stored.objectId) then
        return nil, 'output ref record is unavailable'
      end
      -- Try direct getObjectByFormId for @0x... or FormId if supported, else scan known cells.
      local direct = call(world.getObjectByFormId, stored.objectId)
      if api.isValid(direct) then
        liveOutputs[targetId] = direct
        return direct, nil
      end
      local cellsToScan, seen = {}, {}
      local function addCell(k)
        k = lower(k)
        if k and not seen[k] then seen[k] = true; cellsToScan[#cellsToScan + 1] = k end
      end
      addCell(stored.cellKey)
      for i = 1, #(stored.recoveryCells or {}) do addCell(stored.recoveryCells[i]) end
      local recovery = ledger and ledger:recoveryCellsForTarget(targetId)
      for i = 1, #(recovery or {}) do addCell(recovery[i]) end
      for key in pairs(observed) do addCell(key) end
      local found = scanCellsForObjectId(cellsToScan, stored.objectId, stored.typeName)
      if found ~= nil then
        liveOutputs[targetId] = found
        return found, nil
      end
      return nil, 'output object is not currently loaded'
    end
    if targetId:sub(1, 8) == 'content:' then
      local direct = lookupContentRef(targetId)
      if direct ~= nil then return direct, nil end
      local stored = ledger and ledger:getRef(targetId)
      local cellsToScan, seen = {}, {}
      local function addCell(k)
        k = lower(k)
        if k and not seen[k] then seen[k] = true; cellsToScan[#cellsToScan + 1] = k end
      end
      if stored then
        addCell(stored.cellKey)
        if stored.origin then addCell(stored.origin.cellId) end
      end
      local recovery = ledger and ledger:recoveryCellsForTarget(targetId)
      for i = 1, #(recovery or {}) do addCell(recovery[i]) end
      for key in pairs(observed) do addCell(key) end
      local found = scanCellsForObjectId(cellsToScan, targetId, stored and stored.typeName or nil)
      if found ~= nil then
        liveOutputs[targetId] = found
        return found, nil
      end
      return nil, 'content ref is not currently loaded'
    end
    if targetId:sub(1, 1) == '@' then
      local direct = call(world.getObjectByFormId, targetId)
      if api.isValid(direct) then return direct, nil end
      local stored = ledger and ledger:getRef(targetId)
      local cellsToScan, seen = {}, {}
      local function addCell(k)
        k = lower(k)
        if k and not seen[k] then seen[k] = true; cellsToScan[#cellsToScan + 1] = k end
      end
      if stored then
        addCell(stored.cellKey)
        for i = 1, #(stored.recoveryCells or {}) do addCell(stored.recoveryCells[i]) end
      end
      local recovery = ledger and ledger:recoveryCellsForTarget(targetId)
      for i = 1, #(recovery or {}) do addCell(recovery[i]) end
      for key in pairs(observed) do addCell(key) end
      local found = scanCellsForObjectId(cellsToScan, targetId, stored and stored.typeName or nil)
      if found ~= nil then return found, nil end
      return nil, 'foreign generated ref is not currently loaded'
    end
    return nil, 'unsupported targetId: ' .. tostring(targetId)
  end

  function api.clear()
    observed = {}
    byHandle = {}
    cellCache = {}
    factsCache = {}
    worldspaceHints = {}
    liveOutputs = {}
    fencedCells = {}
    frameGetAllCache = {}
    frameFactsCache = {}
  end

  return api
end

return M
