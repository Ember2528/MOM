local types = require('openmw.types')
local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local M = {}
local slots = {
  {name = 'first.1', x = 1420, model = 'meshes/f/furn_de_tapestry_03.nif', scale = 1},
  {name = 'first.2', x = 1520, model = 'meshes/f/furn_de_tapestry_03.nif', scale = 1},
  {name = 'second.1', x = 1440, model = 'meshes/f/furn_de_tapestry_02.nif', scale = 1.2},
  {name = 'second.2', x = 1540, model = 'meshes/f/furn_de_tapestry_02.nif', scale = 1.2},
}

function M.read(cell)
  local found = {}
  for _, slot in ipairs(slots) do found[slot.name] = {} end
  H.eachCellObject(cell, function(obj)
    if not H.objectIsInstance(types.Static, obj) then return end
    local record = types.Static.record(obj)
    local model = tostring(record and record.model or ''):lower():gsub('\\', '/')
    if not model:match('^meshes/') then model = 'meshes/' .. model end
    for _, slot in ipairs(slots) do
      if model == slot.model and H.positionNear(obj.position, {x=slot.x, y=960, z=-311}, 8) then
        local list = found[slot.name]
        list[#list + 1] = {id = tostring(obj.id), record = H.objectRecordId(obj),
          good = obj.enabled ~= false and H.scaleNear(obj.scale, slot.scale, 0.02)}
      end
    end
  end)
  return found
end

function M.waitAbsent(cell, label)
  H.waitUntil(function()
    local found = M.read(cell)
    for _, slot in ipairs(slots) do if #found[slot.name] ~= 0 then return false end end
    return true
  end, C.LONG_TIMEOUT_FRAMES, label)
end

function M.waitReady(cell, label)
  H.waitUntil(function()
    local found = M.read(cell)
    for _, slot in ipairs(slots) do
      local list = found[slot.name]
      if #list ~= 1 or not list[1].good then return false end
    end
    return true
  end, C.LONG_TIMEOUT_FRAMES, label)
  H.waitFrames(30)
  local found = M.read(cell)
  local ids = {}
  for _, slot in ipairs(slots) do
    local list = found[slot.name]
    H.expect(#list == 1 and list[1].good and not ids[list[1].id], label .. ': wrong count/scale/identity for ' .. slot.name)
    H.expect(list[1].record ~= 'furn_de_tapestry_04', label .. ': expected physical generated record for ' .. slot.name)
    ids[list[1].id] = true
  end
  return found
end

function M.emit(campaign, found)
  for _, slot in ipairs(slots) do
    campaign.emitValue('nested_attach.' .. slot.name .. '.id', found[slot.name][1].id)
    campaign.emitValue('nested_attach.' .. slot.name .. '.record', found[slot.name][1].record)
  end
end

function M.expectSame(campaign, found)
  for _, slot in ipairs(slots) do
    local item = found[slot.name][1]
    H.expect(item.id == campaign.handoffValue('nested_attach.' .. slot.name .. '.id'), 'object identity changed after restart: ' .. slot.name)
    H.expect(item.record == campaign.handoffValue('nested_attach.' .. slot.name .. '.record'), 'physical record changed after restart: ' .. slot.name)
  end
end

return M
