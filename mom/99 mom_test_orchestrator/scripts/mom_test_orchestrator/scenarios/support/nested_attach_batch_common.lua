-- Real-engine checks for multiple abbreviated child attachments in one batch.
local types = require('openmw.types')
local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local M = {}
local roots = {
  {name = 'both', x = 1400, record = 'furn_de_tapestry_04', kind = types.Static, rows = {true, true}},
  {name = 'second', x = 1500, record = 'furn_sign_arms_01', kind = types.Activator, rows = {false, true}},
  {name = 'neither', x = 1600, record = 'furn_de_tapestry_01', kind = types.Static, rows = {false, false}},
  {name = 'first', x = 1700, record = 'furn_de_signpost_02', kind = types.Static, rows = {true, false}},
}
local models = {'meshes/f/furn_de_tapestry_03.nif', 'meshes/f/furn_de_tapestry_02.nif'}

local function name(root, row)
  return root.name .. (row and ('.row' .. tostring(row)) or '.root')
end

local function observed(cell)
  local found = {}
  for _, root in ipairs(roots) do
    found[name(root)] = {}
    for row = 1, 2 do found[name(root, row)] = {} end
  end
  H.eachCellObject(cell, function(obj)
    for _, root in ipairs(roots) do
      if H.objectIsInstance(root.kind, obj) then
        local recordId = H.objectRecordId(obj)
        if recordId == root.record
            and H.positionNear(obj.position, {x = root.x, y = 1160, z = -311}, 8) then
          local list = found[name(root)]
          list[#list + 1] = {id = tostring(obj.id), record = recordId,
            good = (obj.enabled ~= false) == (not (root.rows[1] or root.rows[2]))}
        end
        local record = root.kind.record(obj)
        local model = tostring(record and record.model or ''):lower():gsub('\\', '/')
        if not model:match('^meshes/') then model = 'meshes/' .. model end
        for row = 1, 2 do
          if model == models[row] and recordId ~= root.record
              and H.positionNear(obj.position, {x = root.x + 20 * row, y = 1160, z = -311}, 8) then
            local list = found[name(root, row)]
            list[#list + 1] = {id = tostring(obj.id), record = recordId,
              good = obj.enabled ~= false and H.scaleNear(obj.scale, 1.25, 0.02)}
          end
        end
      end
    end
  end)
  return found
end

local function expected(root, row, present)
  if not present then return 0 end
  return row == nil and 1 or (root.rows[row] and 1 or 0)
end

local function ready(found, present)
  for _, root in ipairs(roots) do
    for row = 0, 2 do
      local index
      if row ~= 0 then index = row end
      local list = found[name(root, index)]
      if #list ~= expected(root, index, present) then return false end
      if #list == 1 and not list[1].good then return false end
    end
  end
  return true
end

function M.wait(cell, present, label)
  H.waitUntil(function() return ready(observed(cell), present) end, C.LONG_TIMEOUT_FRAMES, label)
  H.waitFrames(30)
  local found = observed(cell)
  H.expect(ready(found, present), label .. ': batch outputs changed after settling')
  return found
end

function M.emit(campaign, found)
  for _, root in ipairs(roots) do
    for row = 0, 2 do
      local index
      if row ~= 0 then index = row end
      local key = name(root, index)
      if expected(root, index, true) == 1 then
        campaign.emitValue('nested_batch.' .. key .. '.id', found[key][1].id)
        campaign.emitValue('nested_batch.' .. key .. '.record', found[key][1].record)
      end
    end
  end
end

function M.expectSame(campaign, found)
  local ids = {}
  for _, root in ipairs(roots) do
    for row = 0, 2 do
      local index
      if row ~= 0 then index = row end
      local key = name(root, index)
      if expected(root, index, true) == 1 then
        local item = found[key][1]
        H.expect(item.id == campaign.handoffValue('nested_batch.' .. key .. '.id')
            and item.record == campaign.handoffValue('nested_batch.' .. key .. '.record')
            and not ids[item.id], 'batch output changed or duplicated after restart: ' .. key)
        ids[item.id] = true
      end
    end
  end
end

return M
