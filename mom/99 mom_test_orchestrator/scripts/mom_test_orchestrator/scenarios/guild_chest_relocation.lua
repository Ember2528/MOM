local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local EIGHT_PLATES_RELOCATION_TARGET = {
  x = 720.0,
  y = 910.0,
  z = -244.0,
}
return {
  id = 'guild_chest_relocation',
  description = 'Guild chest relocation appears in Eight Plates, returns to the Guild by day, and reapplies at night.',
  run = function()
    H.advanceToHour(12.0)
    local guildCell = H.teleportInteriorReady(
      C.GUILD_OF_MAGES,
      C.GUILD_SAFE_POSITION,
      'Guild of Mages chest setup',
      function(cell)
        return H.findGuildChest(cell) ~= nil
      end)

    local guildChest = H.findGuildChest(guildCell)

    local startingCellId = guildChest.startingCell and guildChest.startingCell.id
      or guildChest.cell and guildChest.cell.id or C.GUILD_OF_MAGES
    local startingPosition = H.copyPosition(guildChest.startingPosition or guildChest.position)
    local guildPosition = H.offsetPosition(H.copyPosition(guildChest.position), 64, 64, 0)
    local eightPlatesTarget = EIGHT_PLATES_RELOCATION_TARGET

    -- Night: source chest disappears from Guild
    guildCell = H.teleportInteriorReady(
      C.GUILD_OF_MAGES,
      guildPosition,
      'Guild of Mages chest anchor setup',
      function(cell)
        return H.findGuildChest(cell) ~= nil
      end)
    H.advanceToHour(23.0)
    H.waitUntil(function()
      return not H.guildChestEnabled(guildCell, startingCellId, startingPosition)
    end, C.LONG_TIMEOUT_FRAMES, 'night guild chest source disable')

    -- Night: relocated chest appears at Eight Plates target with scale
    local eightPlatesCell = H.teleportInteriorReady(
      C.EIGHT_PLATES,
      C.EIGHT_PLATES_SAFE_POSITION,
      'night chest relocation to Eight Plates',
      function(cell)
        local targetChest = H.findChestAtTarget(cell, startingCellId, startingPosition, eightPlatesTarget)
        return targetChest ~= nil and H.scaleNear(targetChest.scale, 0.75)
      end)

    -- Day: chest leaves Eight Plates
    eightPlatesCell = H.advanceLoadedInteriorToHour(12.0, C.EIGHT_PLATES)
    H.waitUntil(function()
      return H.countChestAtTarget(eightPlatesCell, startingCellId, startingPosition, eightPlatesTarget) == 0
    end, C.LONG_TIMEOUT_FRAMES, 'day chest leaves Eight Plates target')

    -- Day: chest returns to Guild at default scale
    local restored, restoreError = pcall(function()
      H.teleportInteriorReady(
        C.GUILD_OF_MAGES,
        guildPosition,
        'day chest returns to Guild of Mages source',
        function(cell)
          local guildChestCurrent = H.findGuildChest(cell)
          return guildChestCurrent ~= nil
            and H.sameStartingIdentity(
              guildChestCurrent,
              startingCellId,
              startingPosition,
              8
            )
            and guildChestCurrent.enabled ~= false
            and H.scaleNear(guildChestCurrent.scale, 1.0)
        end)
    end)
    if not restored then
      local current = H.requireCurrentInterior(C.GUILD_OF_MAGES)
      local identityChest = H.findFirstObject(current, function(obj)
        return H.sameStartingIdentity(obj, startingCellId, startingPosition, 8)
      end)
      local position = identityChest and identityChest.position or {}
      error(tostring(restoreError)
        .. '; identityChest=' .. tostring(identityChest ~= nil)
        .. ',enabled=' .. tostring(identityChest and identityChest.enabled)
        .. ',scale=' .. tostring(identityChest and identityChest.scale)
        .. ',position=' .. tostring(position.x) .. '/'
        .. tostring(position.y) .. '/' .. tostring(position.z)
        .. '; ' .. H.runtimeStatusText())
    end

    -- Night again: chest reapplies at Eight Plates
    H.advanceToHour(23.0)
    local reapplied, reapplyError = pcall(function()
      H.teleportInteriorReady(
        C.EIGHT_PLATES,
        C.EIGHT_PLATES_SAFE_POSITION,
        'relocated chest reapply on Eight Plates return',
        function(cell)
          local targetChest =
            H.findChestAtTarget(
              cell,
              startingCellId,
              startingPosition,
              eightPlatesTarget
            )
          return targetChest ~= nil and H.scaleNear(targetChest.scale, 0.75)
        end)
    end)
    if not reapplied then
      local current = H.requireCurrentInterior(C.EIGHT_PLATES)
      local identityChest = H.findFirstObject(current, function(obj)
        return H.sameStartingIdentity(obj, startingCellId, startingPosition, 8)
      end)
      local position = identityChest and identityChest.position or {}
      error(tostring(reapplyError)
        .. '; identityChest=' .. tostring(identityChest ~= nil)
        .. ',enabled=' .. tostring(identityChest and identityChest.enabled)
        .. ',scale=' .. tostring(identityChest and identityChest.scale)
        .. ',position=' .. tostring(position.x) .. '/'
        .. tostring(position.y) .. '/' .. tostring(position.z)
        .. '; ' .. H.runtimeStatusText())
    end
  end,
}
