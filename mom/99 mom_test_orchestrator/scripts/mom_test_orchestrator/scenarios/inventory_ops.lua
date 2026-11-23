local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local AJIRA_RECORD_ID = 'ajira'
local AJIRA_ROBE_TARGET_ID = 'exquisite_robe_01'
local AJIRA_AMULET_ID = 'expensive_amulet_02'
local AJIRA_RING_ID = 'common_ring_01'
local function findAjira(cell)
  return H.findFirstObject(cell, function(obj)
    return H.objectRecordId(obj) == AJIRA_RECORD_ID
  end)
end

local function inventorySummary(ajira)
  return string.format('ring=%d ringEquipped=%s amulet=%d robe=%d robeEquipped=%s',
    H.countInventoryRecord(ajira, AJIRA_RING_ID),
    tostring(H.isEquippedRecord(ajira, AJIRA_RING_ID)),
    H.countInventoryRecord(ajira, AJIRA_AMULET_ID),
    H.countInventoryRecord(ajira, AJIRA_ROBE_TARGET_ID),
    tostring(H.isEquippedRecord(ajira, AJIRA_ROBE_TARGET_ID)))
end

return {
  id = 'inventory_ops',
  description = 'Ajira inventory add, equip, unequip, remove, and guard-close revert paths work together.',
  run = function()
    H.advanceToHour(8.0)
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
      'Guild inventory ops setup')
    local guildCell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    local ajira = findAjira(guildCell)
    H.expect(ajira ~= nil, 'Ajira not found in Guild of Mages')

    local daySummary = ''
    local baselineOk, baselineError = pcall(function()
      H.waitUntil(function()
        daySummary = inventorySummary(ajira)
        return H.countInventoryRecord(ajira, AJIRA_RING_ID) == 1
          and not H.isEquippedRecord(ajira, AJIRA_RING_ID)
          and H.countInventoryRecord(ajira, AJIRA_AMULET_ID) > 0
          and H.countInventoryRecord(ajira, AJIRA_ROBE_TARGET_ID) > 0
          and H.isEquippedRecord(ajira, AJIRA_ROBE_TARGET_ID)
      end, C.LONG_TIMEOUT_FRAMES, 'Ajira daytime inventory ops baseline')
    end)
    if not baselineOk then
      error(tostring(baselineError) .. ': ' .. daySummary
        .. '; ' .. H.runtimeStatusText())
    end

    local function waitInventory(description, predicate)
      local summary = ''
      local ok, waitError = pcall(function()
        H.waitUntil(function()
          summary = inventorySummary(ajira)
          return predicate()
        end, C.LONG_TIMEOUT_FRAMES, description)
      end)
      if not ok then
        error(tostring(waitError) .. ': ' .. summary
          .. '; ' .. H.runtimeStatusText())
      end
    end

    H.advanceToHour(12.0)
    waitInventory('Ajira midday ring equip', function()
      return H.countInventoryRecord(ajira, AJIRA_RING_ID) == 1
        and H.isEquippedRecord(ajira, AJIRA_RING_ID)
    end)

    H.advanceToHour(22.0)
    waitInventory('Ajira night remove and unequip', function()
      return H.countInventoryRecord(ajira, AJIRA_RING_ID) == 0
        and H.countInventoryRecord(ajira, AJIRA_AMULET_ID) == 0
        and H.countInventoryRecord(ajira, AJIRA_ROBE_TARGET_ID) > 0
        and not H.isEquippedRecord(ajira, AJIRA_ROBE_TARGET_ID)
    end)

    H.advanceToHour(8.0)
    waitInventory('Ajira inventory ops restored by guard close', function()
      return H.countInventoryRecord(ajira, AJIRA_RING_ID) == 1
        and not H.isEquippedRecord(ajira, AJIRA_RING_ID)
        and H.countInventoryRecord(ajira, AJIRA_AMULET_ID) > 0
        and H.countInventoryRecord(ajira, AJIRA_ROBE_TARGET_ID) > 0
        and H.isEquippedRecord(ajira, AJIRA_ROBE_TARGET_ID)
    end)
  end,
}
