-- Translate VFR decoration syntax into ordinary declarative place/modify
-- actions. Shared compilation owns admission, sampling and record capabilities.
local M = {}
local source_ir = require('scripts.mom.compiler.source_ir')
local vfr_common = require('scripts.mom.compat.vfr.common')
local CELL_SIZE = 8192
local finite = require('scripts.mom.common.numbers').isFinite
local tables = require('scripts.mom.common.tables')
local array = tables.isArray
local fields = vfr_common.fields
local MODULE_FIELDS = {
  name = true, enabled = true, priority = true, require_content = true, exclude_content = true,
  seed = true, placements = true,
}
local PLACEMENT_FIELDS = {id = true, enabled = true, spawn = true, conditions = true, condition = true,
  record = true, alternatives = true, record_draft = true, position = true, rotation = true, scale = true,
  cell = true, interior = true, exterior = true}
local CONDITION_FIELDS = {chance = true, require_content = true, exclude_content = true}
local text = require('scripts.mom.common.strings').isNonEmpty
local function vector(value, default)
  if value == nil then return default end
  if not fields(value, {x = true, y = true, z = true, [1] = true, [2] = true, [3] = true}) then return nil end
  local x = value.x ~= nil and value.x or value[1]
  local y = value.y ~= nil and value.y or value[2]
  local z = value.z ~= nil and value.z or value[3]
  if not finite(x) or not finite(y) or not finite(z) then return nil end
  return {x, y, z}
end
local contentNames = vfr_common.contentNames
local function admission(raw, id, seed, moduleHeader)
  local conditions = raw.conditions or raw.condition
  if conditions ~= nil then
    if not fields(conditions, CONDITION_FIELDS) then return nil, 'conditions contain unsupported fields' end
    if raw.conditions ~= nil and raw.condition ~= nil then return nil, 'declare conditions or condition, not both' end
  end
  local chance = conditions and conditions.chance or nil
  if chance ~= nil and (not finite(chance) or chance < 0 or chance > 1) then
    return nil, 'conditions.chance must be between 0 and 1'
  end
  local required, err = contentNames(conditions and conditions.require_content or nil)
  if err then return nil, err end
  local excluded
  excluded, err = contentNames(conditions and conditions.exclude_content or nil)
  if err then return nil, err end
  local mergedReq = vfr_common.mergeContentNames(moduleHeader and moduleHeader.requires or nil, required)
  local mergedExc = vfr_common.mergeContentNames(moduleHeader and moduleHeader.requiresNot or nil, excluded)
  if conditions == nil and mergedReq == nil and mergedExc == nil then return nil end
  return {requires = mergedReq, requiresNot = mergedExc,
    chance = chance, seed = seed, key = id, salt = 'condition'}
end
local function recordExpression(raw, id, seed)
  local count = (raw.record ~= nil and 1 or 0) + (raw.alternatives ~= nil and 1 or 0)
    + (raw.record_draft ~= nil and 1 or 0)
  if count ~= 1 then return nil, 'declare exactly one of record, alternatives, or record_draft' end
  if raw.record_draft ~= nil then
    return nil, 'record_draft placements are unsupported; use an existing Static or Activator record'
  end
  if raw.record ~= nil then
    if not text(raw.record) then return nil, 'record must be a non-empty string' end
    return raw.record:lower()
  end
  if not array(raw.alternatives) or #raw.alternatives == 0 then
    return nil, 'alternatives must be a non-empty array'
  end
  local total, choices = 0, {}
  for _, alternative in ipairs(raw.alternatives) do
    if not fields(alternative, {record = true, weight = true}) or not text(alternative.record)
        or not finite(alternative.weight) or alternative.weight <= 0 then
      return nil, 'alternatives require a record and positive finite weight'
    end
    total = total + alternative.weight
    choices[#choices + 1] = {{recordId = alternative.record:lower()}, alternative.weight}
  end
  if not finite(total) then return nil, 'alternative weights overflow' end
  return {choose = choices, seed = seed, key = id, salt = 'alternative'}
end
local function location(raw, position)
  local count = (raw.cell ~= nil and 1 or 0) + (raw.interior ~= nil and 1 or 0)
    + (raw.exterior ~= nil and 1 or 0)
  if count ~= 1 then return nil, 'declare exactly one of cell, interior, or exterior' end
  local value = raw.cell
  if raw.interior ~= nil then value = raw.interior end
  if raw.exterior ~= nil then value = raw.exterior end
  if type(value) == 'string' then
    if value == '' then return nil, 'interior cell name must not be empty' end
    return {exact = value, kind = 'interior'}
  end
  local x, y
  if value == true then
    x, y = math.floor(position[1] / CELL_SIZE), math.floor(position[2] / CELL_SIZE)
  elseif fields(value, {x = true, y = true, [1] = true, [2] = true}) then
    x = value.x ~= nil and value.x or value[1]
    y = value.y ~= nil and value.y or value[2]
  end
  if not finite(x) or not finite(y) or x % 1 ~= 0 or y % 1 ~= 0 then
    return nil, 'exterior must be true or integer {x, y} coordinates'
  end
  if x ~= math.floor(position[1] / CELL_SIZE) or y ~= math.floor(position[2] / CELL_SIZE) then
    return nil, 'position does not lie in the declared exterior cell'
  end
  return {coords = {x, y}, kind = 'exterior'}
end
local function metadata(path, id, suffix)
  return {
    family = suffix and 'modify_ref' or 'place_ref',
    diagnosticId = path .. '#compat:vfr:placements:' .. id .. (suffix or ''),
    source = {adapterId = 'vfr', file = path,
      variant = 'vfr:placements:' .. id, path = {'placements', id}},
  }
end

-- False means a valid placement was intentionally skipped. Nil indicates a
-- malformed placement, with its diagnostic in the second return value.
local function translatePlacement(placement, index, path, seen, seed, moduleHeader)
  local prefix = path .. '.placements[' .. index .. ']'
  if type(placement) == 'table' and text(placement.id) then
    prefix = prefix .. ' (' .. placement.id .. ')'
  end
  if not fields(placement, PLACEMENT_FIELDS) or not text(placement.id) then
    return nil, prefix .. ': unsupported placement fields or missing permanent non-empty id'
  end
  local id = placement.id:lower()
  if seen[id] then return nil, prefix .. ': duplicate placement id' end
  seen[id] = true
  if placement.enabled ~= nil and type(placement.enabled) ~= 'boolean' then
    return nil, prefix .. ': enabled must be boolean'
  end
  if placement.enabled == false then return false end

  if placement.spawn ~= nil and type(placement.spawn) ~= 'boolean' then
    return nil, prefix .. ': spawn must be boolean'
  end
  local when, err = admission(placement, id, seed, moduleHeader)
  if err then return nil, prefix .. ': ' .. err end
  if placement.spawn then
    return nil, prefix .. ': native spawn placements are unsupported; leveled-list injection is supported separately'
  end

  local recordId
  recordId, err = recordExpression(placement, id, seed)
  if recordId == nil then return nil, prefix .. ': ' .. err end
  local position = vector(placement.position)
  local rotation = vector(placement.rotation, {0, 0, 0})
  local scale = placement.scale == nil and 1 or placement.scale
  if position == nil then return nil, prefix .. ': position requires three finite coordinates' end
  if rotation == nil then return nil, prefix .. ': rotation requires three finite degree angles' end
  if not finite(scale) or scale <= 0 then return nil, prefix .. ': scale must be positive and finite' end
  local cell
  cell, err = location(placement, position)
  if cell == nil then return nil, prefix .. ': ' .. err end

  local action = metadata(path, id)
  action.uniqueSourceKey = 'vfr:placement:' .. id
  if moduleHeader and moduleHeader.priority ~= nil and moduleHeader.priority ~= 0 then
    action.priority = moduleHeader.priority
  end
  if scale ~= 1 then
    action.children = {source_ir.sourceActionOwned({modify = {scale = {to = scale}}},
      metadata(path, id, ':scale'))}
  end
  local spec = {
    key = action.uniqueSourceKey, admission = when, targetTypes = {'Static', 'Activator'},
    place = {{cell, recordId, position,
      {roll = rotation[1], pitch = rotation[2], yaw = rotation[3]}}},
  }
  return source_ir.sourceActionOwned(spec, action)
end

function M.translate(raw, path)
  path = tostring(path or 'VFR placements'):gsub('\\', '/')
  if not fields(raw, MODULE_FIELDS) or not array(raw.placements) then
    return nil, path .. ': unsupported module fields or placements is not an array'
  end
  local header, headerErr = vfr_common.validateModuleHeader(raw)
  if not header then return nil, path .. ': ' .. headerErr end
  if raw.seed ~= nil and not finite(raw.seed) then return nil, path .. ': seed must be finite' end
  if header.enabled == false then return {}, nil end
  local seed = finite(raw.seed) and math.floor(raw.seed) or 0
  local actions, seen = {}, {}
  for index, placement in ipairs(raw.placements) do
    local action, err = translatePlacement(placement, index, path, seen, seed, header)
    if action == nil then return nil, err end
    if action ~= false then actions[#actions + 1] = action end
  end
  return actions, nil
end
return M
