local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local G = require('scripts.mom_test_orchestrator.scenarios.support.group1_common')
local world = require('openmw.world')
local util = require('openmw.util')

return {
  id = 'structured_selectors',
  description = 'Exact references survive movement; typed record/script/provenance queries narrow targets.',
  run = function()
    for _, key in ipairs({'structured_reference', 'structured_relocation',
        'structured_query', 'structured_mwscript'}) do G.toggle(key, false) end
    local crate = G.crate()
    local first = assert(G.ref(484126), 'selected tapestry unavailable')
    local sibling = assert(G.ref(484127), 'unselected tapestry unavailable')
    local firstScale, siblingScale = first.scale, sibling.scale
    G.toggle('structured_reference', true)
    H.waitUntil(function() return H.scaleNear(first.scale, 0.75, 0.001) end,
      C.LONG_TIMEOUT_FRAMES, 'exact reference selected')
    H.expect(H.scaleNear(sibling.scale, siblingScale, 0.001), 'exact reference changed its sibling')
    G.toggle('structured_reference', false)
    H.waitUntil(function() return H.scaleNear(first.scale, firstScale, 0.001) end,
      C.LONG_TIMEOUT_FRAMES, 'exact reference restored')

    local current = H.requireCurrentInterior(C.EIGHT_PLATES)
    local generated = world.createObject('furn_de_tapestry_04')
    generated:teleport(current, util.vector3(1900, 960, -311))
    H.waitFrames(5)
    local generatedScale = generated.scale
    G.toggle('structured_query', true)
    H.waitUntil(function()
      return H.scaleNear(first.scale, 0.8, 0.001) and H.scaleNear(sibling.scale, 0.8, 0.001)
    end, C.LONG_TIMEOUT_FRAMES, 'record pattern selects multiple source references')
    H.expect(H.scaleNear(generated.scale, generatedScale, 0.001), 'content provenance matched a generated object')
    G.toggle('structured_query', false)
    H.waitUntil(function()
      return H.scaleNear(first.scale, firstScale, 0.001) and H.scaleNear(sibling.scale, siblingScale, 0.001)
    end, C.LONG_TIMEOUT_FRAMES, 'query withdrawal restores sources')
    generated:remove()

    local innkeeper = assert(G.ref(67599), 'scripted innkeeper unavailable')
    local other = assert(G.ref(67601), 'other scripted NPC unavailable')
    local baseline, otherScale = innkeeper.scale, other.scale
    G.toggle('structured_mwscript', true)
    H.waitUntil(function() return H.scaleNear(innkeeper.scale, 0.85, 0.001) end,
      C.LONG_TIMEOUT_FRAMES, 'base MWScript selects the innkeeper')
    H.expect(H.scaleNear(other.scale, otherScale, 0.001), 'MWScript query selected another script')
    G.toggle('structured_mwscript', false)
    H.waitUntil(function() return H.scaleNear(innkeeper.scale, baseline, 0.001) end,
      C.LONG_TIMEOUT_FRAMES, 'MWScript query restores the innkeeper')

    local origin = H.copyPosition(crate.startingPosition)
    local originalId = tostring(crate.id)
    G.toggle('structured_relocation', true)
    H.teleportInterior(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION, 'exact reference destination')
    H.waitUntil(function()
      local moved = G.ref(56704)
      return moved and tostring(moved.id) == originalId and moved.cell
        and H.normalizeCellId(moved.cell.id) == H.normalizeCellId(C.GUILD_OF_MAGES)
        and H.positionNear(moved.position, {x = 400, y = 400, z = 100}, 2)
    end, C.LONG_TIMEOUT_FRAMES, 'exact reference cross-cell relocation')
    G.toggle('structured_relocation', false)
    H.teleportInterior(C.EIGHT_PLATES, C.EIGHT_PLATES_SAFE_POSITION, 'exact reference origin')
    H.waitUntil(function()
      local restored = G.ref(56704)
      return restored and tostring(restored.id) == originalId and restored.cell
        and H.normalizeCellId(restored.cell.id) == H.normalizeCellId(C.EIGHT_PLATES)
        and H.positionNear(restored.position, origin, 2)
    end, C.LONG_TIMEOUT_FRAMES, 'exact reference restores its origin after relocation')
  end,
}
