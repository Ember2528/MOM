local types = require('openmw.types')
local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local KINDS = {types.Static, types.Activator, types.Container}
local ROOTS = {2100, 2200, 2300}
local MODELS = {'meshes/f/furn_de_tapestry_03.nif', 'meshes/f/furn_de_tapestry_02.nif', 'meshes/f/furn_de_tapestry_01.nif'}
local DECOY = {x = 2400, y = 1850, z = -311}
local GUILD_Y = 2700

local function outputs(cell)
  local found = {}
  for i = 1, 3 do found[i] = {{}, {}, {}} end
  local invalid = 0
  H.eachCellObject(cell, function(obj)
    local kind
    for i = 1, 3 do if H.objectIsInstance(KINDS[i], obj) then kind = i; break end end
    if not kind then return end
    local record = KINDS[kind].record(obj)
    local model = tostring(record and record.model or ''):lower():gsub('\\', '/')
    if not model:match('^meshes/') then model = 'meshes/' .. model end
    for modelIndex = 1, 3 do
      if model == MODELS[modelIndex] then
        local expectedX = ROOTS[kind] + 20 * modelIndex
        if H.positionNear(obj.position, {x = expectedX, y = 1850, z = -311}, 8) then
          local list = found[kind][modelIndex]
          list[#list + 1] = obj
        elseif obj.position.x >= 2000 and obj.position.x <= 2500 and math.abs(obj.position.y - 1850) <= 8 then
          invalid = invalid + 1
        end
      end
    end
  end)
  return found, invalid
end

local function complete(cell, present)
  local found, invalid = outputs(cell)
  if invalid ~= 0 then return false end
  local decoys = H.countObjects(cell, function(obj)
    return H.objectRecordId(obj) == H.normalizeRecordId('furn_de_tapestry_04')
      and H.positionNear(obj.position, DECOY, 8) and obj.enabled
  end)
  if decoys ~= (present and 1 or 0) then return false end
  for i = 1, 3 do
    for j = 1, 3 do
      local list = found[i][j]
      if #list ~= (present and 1 or 0) then return false end
      if present and (list[1].enabled ~= (j == 3)) then return false end
    end
  end
  return true
end

local function guildComplete(cell, present)
  local found = {0, 0, 0}
  H.eachCellObject(cell, function(obj)
    if not H.objectIsInstance(types.Static, obj) then return end
    local record = types.Static.record(obj)
    local model = tostring(record and record.model or ''):lower():gsub('\\', '/')
    if not model:match('^meshes/') then model = 'meshes/' .. model end
    for i = 1, 3 do
      if model == MODELS[i]
          and H.positionNear(obj.position, {x = 3000 + 20 * i, y = GUILD_Y, z = -100}, 8) then
        found[i] = found[i] + 1
        if i == 1 and present and not obj.enabled then found[i] = found[i] + 1 end
      end
    end
  end)
  return found[1] == (present and 1 or 0) and found[2] == 0 and found[3] == 0
end

return {
  id = 'tuple_nested_attach_acceptance',
  description = 'Nested tuple selectors, inherited cell narrowing, and exclusion of matching non-parent refs.',
  run = function()
    local cell = H.teleportInteriorAtHour(23, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'tuple attach inactive baseline')
    H.waitUntil(function() return complete(cell, false) end, C.LONG_TIMEOUT_FRAMES, 'tuple attach absent before guard')
    cell = H.advanceLoadedInteriorToHour(12, C.EIGHT_PLATES)
    H.waitUntil(function() return complete(cell, true) end, C.LONG_TIMEOUT_FRAMES, 'three complete nested tuple chains and no extra output')
    H.waitFrames(30)
    H.expect(complete(cell, true), 'tuple nested outputs changed after settling')
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION, 'tuple attach cross-cell output')
    cell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    H.waitUntil(function() return guildComplete(cell, true) end, C.LONG_TIMEOUT_FRAMES,
      'cross-cell parent output exists without the Eight Plates tuple descendant')
    H.waitFrames(90)
    H.expect(guildComplete(cell, true), 'Eight Plates tuple matched a Guild parent output')
    cell = H.advanceLoadedInteriorToHour(23, C.GUILD_OF_MAGES)
    H.waitUntil(function() return guildComplete(cell, false) end, C.LONG_TIMEOUT_FRAMES,
      'cross-cell parent output cleanup')
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'tuple attach cleanup')
    cell = H.requireCurrentInterior(C.EIGHT_PLATES)
    H.waitUntil(function() return complete(cell, false) end, C.LONG_TIMEOUT_FRAMES, 'tuple attach cleanup')
  end,
}
