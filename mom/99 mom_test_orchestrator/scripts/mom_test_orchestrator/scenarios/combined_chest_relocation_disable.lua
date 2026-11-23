local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local COMBINED_RELOCATION_HOUR = 21.0
local COMBINED_RELOCATION_TARGET = {
  x = 760.0,
  y = 980.0,
  z = -244.0,
}
return {
  id = 'combined_chest_relocation_disable',
  description = 'A single relocate+disable action moves the Guild chest to Eight Plates disabled, then restores it to the Guild by day.',
  run = function()
    H.advanceToHour(12.0)
    local guildCell = H.teleportInteriorReady(
      C.GUILD_OF_MAGES,
      C.GUILD_SAFE_POSITION,
      'Guild of Mages combined relocate+disable setup',
      function(cell)
        return H.findGuildChest(cell) ~= nil
      end)

    local guildChest = H.findGuildChest(guildCell)

    local refId = guildChest.id
    local startingCellId = guildChest.startingCell and guildChest.startingCell.id
      or guildChest.cell and guildChest.cell.id or C.GUILD_OF_MAGES
    local startingPosition = H.copyPosition(guildChest.startingPosition or guildChest.position)
    local guildPosition = H.offsetPosition(H.copyPosition(guildChest.position), 64, 64, 0)

    -- Advance into the combined relocation window (20-22)
    H.teleportInterior(C.GUILD_OF_MAGES, guildPosition,
      'Guild of Mages combined relocate+disable anchor setup')
    guildCell = H.requireCurrentInterior(C.GUILD_OF_MAGES)
    H.advanceToHour(COMBINED_RELOCATION_HOUR)

    H.waitUntil(function()
      return not H.guildChestEnabled(guildCell, startingCellId, startingPosition)
    end, C.LONG_TIMEOUT_FRAMES, 'combined relocate+disable removes source chest from Guild')

    -- Chest should be at Eight Plates, relocated and disabled
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates combined relocate+disable check')
    H.waitUntil(function()
      local movedChest = H.getObjectByRefId(refId)
      return movedChest ~= nil
        and H.normalizeCellId(movedChest.cell and movedChest.cell.id) == H.normalizeCellId(C.EIGHT_PLATES)
        and H.positionNear(movedChest.position, COMBINED_RELOCATION_TARGET, 96)
        and movedChest.enabled == false
    end, C.LONG_TIMEOUT_FRAMES, 'combined relocate+disable keeps moved chest disabled in Eight Plates')

    -- Day: chest returns to Guild enabled
    H.advanceToHour(12.0)
    H.teleportInterior(C.GUILD_OF_MAGES, guildPosition,
      'Guild of Mages combined relocate+disable revert check')
    H.waitUntil(function()
      local restoredChest = H.getObjectByRefId(refId)
      return restoredChest ~= nil
        and H.normalizeCellId(restoredChest.cell and restoredChest.cell.id) == H.normalizeCellId(C.GUILD_OF_MAGES)
        and H.positionNear(restoredChest.position, startingPosition, 8)
        and restoredChest.enabled ~= false
    end, C.LONG_TIMEOUT_FRAMES, 'combined relocate+disable restores source chest by day')
  end,
}
