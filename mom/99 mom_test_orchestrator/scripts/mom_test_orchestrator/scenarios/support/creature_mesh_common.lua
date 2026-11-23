local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local types = require('openmw.types')
local model_path = require('scripts.mom.contracts.model_path')
local core = require('openmw.core')
local provider = require('scripts.mom_test_orchestrator.guard_provider')

local M = {SOURCE = 'scamp_creeper', MODEL = 'meshes/r/rust rat.nif'}

local function activate(value)
  assert(provider.set('creature_mesh_fixture', value))
  core.sendGlobalEvent('MOM_GuardEvent', {
    event = 'external:harness:toggle_changed:creature_mesh_fixture',
  })
end

function M.deactivate()
  activate(false)
end

function M.teleport(hour)
  -- Other scenarios share this cell and change the clock. Do not create a
  -- live actor until this test starts; unknown provider truth holds saved work
  -- across restart until the verification phase publishes true again.
  activate(true)
  if hour ~= nil then
    return H.teleportInteriorAtHour(hour, C.EIGHT_PLATES,
      C.EIGHT_PLATES_SAFE_POSITION, 'Creature replacement destination')
  end
  H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
    'Creature replacement after restart')
  return H.requireCurrentInterior(C.EIGHT_PLATES)
end

function M.rows(cell)
  local sources, outputs = {}, {}
  H.eachCellObject(cell, function(object)
    if not types.Creature.objectIsInstance(object) then return end
    if H.objectRecordId(object) == M.SOURCE then
      sources[#sources + 1] = object
    elseif object.enabled ~= false then
      local record = types.Creature.record(object)
      -- Vanilla rats use this model too. Other suite fixtures intentionally
      -- leave living and dead rats in this cell; only a copied Creeper record
      -- carries the merchant MWScript required by this replacement test.
      if model_path.normalize(record.model) == M.MODEL
          and tostring(record.mwscript):lower() == 'scampscript' then
        outputs[#outputs + 1] = object
      end
    end
  end)
  return sources, outputs
end

function M.waitReady(cell)
  local source, output
  local ready, readyError = pcall(function()
    H.waitUntil(function()
      local sources, outputs = M.rows(cell)
      if #sources ~= 1 or #outputs ~= 1 or sources[1].enabled ~= false then return false end
      source, output = sources[1], outputs[1]
      return true
    end, C.LONG_TIMEOUT_FRAMES, 'Exactly one Creature mesh output with hidden source')
  end)
  if not ready then
    local sources, outputs = M.rows(cell)
    local rows = {}
    for _, group in ipairs({sources, outputs}) do
      for _, ref in ipairs(group) do
        local p = ref.position
        rows[#rows + 1] = string.format('%s:%s:enabled=%s:dead=%s:(%.1f,%.1f,%.1f)',
          tostring(ref.id), tostring(ref.recordId), tostring(ref.enabled ~= false),
          tostring(types.Actor.isDead(ref)), p.x, p.y, p.z)
      end
    end
    error(tostring(readyError) .. '; creatures={' .. table.concat(rows, ',')
      .. '}; ' .. H.runtimeStatusText())
  end
  H.expect(types.Actor.isDead(output) == false, 'Creature mesh output was dead')
  H.expect(H.scaleNear(source.scale, output.scale, 0.001),
    'Creature mesh replacement lost source scale')
  H.expect(H.positionNear(source.position, output.position, 64),
    'Creature mesh replacement lost source position')
  local baseline, replacement = types.Creature.record(M.SOURCE), types.Creature.record(output)
  H.expect(tostring(replacement.mwscript):lower() == 'scampscript', 'Creature template lost its MWScript')
  for _, key in ipairs({'name', 'mwscript', 'baseGold', 'soulValue', 'type',
      'combatSkill', 'magicSkill', 'stealthSkill', 'isRespawning', 'isEssential'}) do
    H.expect(replacement[key] == baseline[key], 'Creature template changed ' .. key)
  end
  H.expect(replacement.baseGold == 5000, 'Creature merchant base gold was not preserved')
  for key, value in pairs(baseline.servicesOffered) do
    H.expect(replacement.servicesOffered[key] == value,
      'Creature merchant service changed: ' .. tostring(key))
  end
  local inventory = types.Actor.inventory(source)
  local outputInventory = types.Actor.inventory(output)
  -- random_scamp_skin is a leveled inventory entry. Independent fresh actors
  -- can legitimately resolve it differently, even with the same base template.
  for _, id in ipairs({'iron shortsword', 'potion_local_brew_01', 'potion_skooma_01',
      'potion_local_liquor_01', 'potion_cyro_whiskey_01', 'potion_cyro_brandy_01',
      'potion_comberry_wine_01', 'potion_comberry_brandy_01', 'potion_ancient_brandy',
      'misc_de_drum_02'}) do
    H.expect(inventory:countOf(id) == 1 and outputInventory:countOf(id) == 1,
      'Fresh Creature template inventory changed: ' .. id)
  end
  return source, output
end

function M.waitAbsent(cell)
  H.waitUntil(function()
    local sources, outputs = M.rows(cell)
    return #sources == 0 and #outputs == 0
  end, C.LONG_TIMEOUT_FRAMES, 'Creature source and output withdrawn')
end

function M.emit(campaign, source, output)
  campaign.emitValue('creature.source', tostring(source.id))
  campaign.emitValue('creature.output', tostring(output.id))
  campaign.emitValue('creature.record', tostring(output.recordId))
end

function M.expectSame(campaign, source, output)
  H.expect(tostring(source.id) == campaign.handoffValue('creature.source'),
    'Creature source identity changed after restart')
  H.expect(tostring(output.id) == campaign.handoffValue('creature.output'),
    'Creature output was duplicated after restart')
  H.expect(tostring(output.recordId) == campaign.handoffValue('creature.record'),
    'Creature variant record was recreated after restart')
end

return M
