local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local DUPLICATE_DAY_TARGETS = {
  {
    recordId = 'misc_com_bottle_05',
    position = { x = -294.999, y = 484.871, z = -101.713 },
  },
  {
    recordId = 'misc_com_bottle_05',
    position = { x = -309.109, y = 489.567, z = -101.836 },
  },
  {
    recordId = 'misc_de_goblet_01',
    position = { x = -119.565, y = 616.176, z = -178.241 },
  },
}
return {
  id = 'targeting_duplicates',
  description = 'Exact keyed duplicate-target selectors disable only the intended Eight Plates clutter.',
  run = function()
    local cell = H.teleportInteriorAtHour(23.0, C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION,
      'Eight Plates duplicate target night baseline setup')

    local selected = {}
    for i, target in ipairs(DUPLICATE_DAY_TARGETS) do
      H.waitUntil(function()
        selected[i] = H.findFirstObject(cell, function(obj)
          return H.objectRecordId(obj) == target.recordId
            and H.sameStartingIdentity(obj, C.EIGHT_PLATES, target.position,
              C.DUPLICATE_TARGET_TOLERANCE)
        end)
        return selected[i] ~= nil and selected[i].enabled ~= false
      end, C.LONG_TIMEOUT_FRAMES, 'Eight Plates selected duplicate baseline #' .. i)
    end

    local sibling = H.findFirstObject(cell, function(obj)
      if H.objectRecordId(obj) ~= 'misc_com_bottle_05' or obj.enabled == false then
        return false
      end
      for _, target in ipairs(DUPLICATE_DAY_TARGETS) do
        if H.sameStartingIdentity(obj, C.EIGHT_PLATES, target.position,
            C.DUPLICATE_TARGET_TOLERANCE) then
          return false
        end
      end
      return true
    end)
    H.expect(sibling ~= nil, 'No unselected same-record sibling for duplicate selector')

    cell = H.advanceLoadedInteriorToHour(12.0, C.EIGHT_PLATES)

    H.waitUntil(function()
      for _, obj in ipairs(selected) do
        if not obj:isValid() or obj.enabled ~= false then return false end
      end
      return true
    end, C.LONG_TIMEOUT_FRAMES, 'selected duplicate targets disabled')

    H.expect(sibling:isValid() and sibling.enabled ~= false,
      'Duplicate selector disabled an unselected same-record sibling')

    cell = H.advanceLoadedInteriorToHour(23.0, C.EIGHT_PLATES)

    H.waitUntil(function()
      for _, obj in ipairs(selected) do
        if not obj:isValid() or obj.enabled == false then return false end
      end
      return true
    end, C.LONG_TIMEOUT_FRAMES, 'selected duplicate targets restored')
  end,
}
