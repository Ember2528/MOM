-- Imported placement instances keep distinct native ownership even when their
-- physical record and transform facts coincide. No foreign runtime is loaded.
package.preload['openmw.core'] = package.preload['openmw.core'] or function() return {contentFiles = {list = {}}} end
package.preload['openmw.vfs'] = package.preload['openmw.vfs'] or function() return {} end
package.preload['openmw.types'] = package.preload['openmw.types'] or function() return {} end
package.preload['openmw.world'] = package.preload['openmw.world'] or function() return {} end
package.preload['openmw.markup'] = package.preload['openmw.markup'] or function() return {} end
local support = require('pure.test_support')
local expect = support.expect
local placements = require('scripts.mom.compat.vfr.placements')
local translator = require('scripts.mom.compat.vfr.translator')
local source_ir = require('scripts.mom.compiler.source_ir')
local source_contract = require('scripts.mom.compiler.source_action_contract')
local compiler = require('scripts.mom.compiler.compile_sources')
local frontend = require('scripts.mom.compiler.action_frontend')
local place_family = require('scripts.mom.actions.place_ref')
local cell_index = require('scripts.mom.compiler.cell_index')
local record_index = require('scripts.mom.compiler.record_index')
local plain_data = require('scripts.mom.contracts.plain_data')
local ledger_api = require('scripts.mom.ledger.ledger')
local runtime = require('scripts.mom.actions.place_ref.runtime')
local M = {}
local PREFIX = 'scripts/variationframework/placements/data/'

local function catalog()
  return {kind = 'mom-extension-catalog',
    actions = {kind = 'action', ids = {'place_ref'}, byId = {place_ref = {
      id = 'place_ref', abiVersion = 0, behaviorVersion = 0, programVersion = 0,
      revertTokenVersion = 0, module = place_family,
    }}}, guards = {kind = 'guard', ids = {}, byId = {}},
    compat = {kind = 'compat', ids = {}, byId = {}}}
end
local function decoration(id)
  return {id = id, record = 'target_lamp', interior = 'Balmora', position = {1, 2, 3}}
end
local function imported(path, definitions)
  local actions, err = placements.translate({placements = definitions}, PREFIX .. path)
  expect(actions, tostring(err))
  local valid, errors = source_contract.validateSourceActions(actions, {adapterId = 'vfr'})
  expect(valid, table.concat(errors or {}, ' | '))
  return {adapterId = 'vfr', path = PREFIX .. path, sourcePath = PREFIX .. path,
    status = 'resolved', actions = actions}
end
local function compile(attempts)
  local oldCells, oldRecords = cell_index.build, record_index.build
  cell_index.build = function()
    local entry = {key = 'balmora', id = 'Balmora', idLower = 'balmora', interiorKey = 'balmora',
      nameLower = 'balmora', isExterior = false}
    return {entries = {entry}, byKey = {balmora = entry}, byId = {balmora = {entry}},
      byName = {balmora = {entry}}, byDisplayName = {}, byExteriorWorldspace = {},
      byRegion = {}, byWorldspace = {}, totalCount = 1, interiorCount = 1, exteriorCount = 0}
  end
  record_index.build = function()
    return {recordExists = function(id) return id == 'target_lamp', 'invalid_record_id' end,
      resolveLiveRefType = function(id) return id == 'target_lamp' and 'Static' or nil end}
  end
  local ok, result = pcall(function()
    local normalized, errors = frontend.normalize(attempts, {activeContent = {}})
    if not normalized then return {status = 'rejected', fatal = {errors = errors}} end
    return compiler.compile({sourceAttempts = normalized}, catalog())
  end)
  cell_index.build, record_index.build = oldCells, oldRecords
  if not ok then error(result, 0) end
  return result
end
local function accepted(attempts)
  local result = compile(attempts)
  expect(result.status == 'accepted', 'placement compilation rejected: '
    .. table.concat(result.fatal and result.fatal.errors or {}, ' | '))
  return result.manifest
end

local function stableIndependentInstances()
  local first = accepted({imported('first.yaml', {decoration('one'), decoration('two')})})
  expect(#first.actionIds == 2, 'coincident placement IDs collapsed to one semantic action')
  local moved = accepted({imported('nested/renamed.yaml', {decoration('TWO'), decoration('ONE')})})
  local split = accepted({imported('z.yaml', {decoration('two')}), imported('a.yaml', {decoration('one')})})
  local expected = table.concat(first.actionIds, ',')
  expect(expected == table.concat(moved.actionIds, ',') and expected == table.concat(split.actionIds, ','),
    'file rename, regrouping, order or ID casing changed native placement ownership')
  local left, right = first.actionsById[first.actionIds[1]], first.actionsById[first.actionIds[2]]
  expect(left.program.objects[1].slot ~= right.program.objects[1].slot
      and left.program.objects[1].position.x == right.program.objects[1].position.x
      and left.program.objects[1].targetValue == right.program.objects[1].targetValue,
    'independent placement slots changed physical facts or lost their instance identity')
end

local function duplicateIdsStillReject()
  local duplicate = compile({imported('first.yaml', {decoration('same')}),
    imported('second.yaml', {decoration('SAME')})})
  expect(duplicate.status == 'rejected' and duplicate.manifest == nil
      and table.concat(duplicate.fatal.errors or {}, ' | '):find('duplicate source key', 1, true),
    'coincident instance support admitted two declarations of the same permanent ID')
end

local function publicAndPrivateAdmission()
  local function native(spec)
    return {adapterId = 'native', path = 'native.yaml', sourcePath = 'native.yaml', status = 'resolved',
      actions = {source_ir.sourceAction(spec, {family = 'place_ref', diagnosticId = 'native',
        source = {adapterId = 'native', file = 'native.yaml', path = {'actions', 1}}})}}
  end
  local ordinary = {place = {{'Balmora', 'target_lamp', {1, 2, 3}, {}}}}
  local manifest = accepted({native(ordinary)})
  expect(manifest.actionsById[manifest.actionIds[1]].program.objects[1].slot == 'a:1',
    'private instance support changed ordinary authored placement slot identity')
  local malformed = assert(plain_data.detach(ordinary))
  malformed.instanceKey = 'not-public'
  local rejected = compile({native(malformed)})
  expect(rejected.status == 'rejected' and rejected.manifest == nil
      and table.concat(rejected.fatal.errors or {}, ' | '):find('instanceKey', 1, true),
    'private instance key leaked into public authored syntax')
  local importedAction = imported('ordinary.yaml', {decoration('keyed')}).actions[1]
  local keyed = assert(plain_data.detach(importedAction.spec))
  local equivalent = accepted({native(keyed)})
  local importedManifest = accepted({imported('ordinary.yaml', {decoration('keyed')})})
  expect(equivalent.actionIds[1] == importedManifest.actionIds[1],
    'native and imported ordinary keyed placements have different semantic identities')
  importedAction.familyInput = {verb = 'place', payloadKind = 'tuples', payload = {}}
  local valid = source_contract.validateSourceActions({importedAction}, {adapterId = 'vfr'})
  expect(not valid, 'translator supplied prepared familyInput after convergence')
end

local function coincidentOutputsStayIndependent()
  local manifest = accepted({imported('coincident.yaml', {decoration('left'), decoration('right')})})
  local ledger = ledger_api.new()
  local cell = {id = 'Balmora', key = 'balmora', isExterior = false}
  local live, createdCount = {}, 0
  local worldAdapter = {
    resolveCell = function() return cell, nil end,
    describeCell = function() return cell, nil end,
    isValid = function(r) return r ~= nil and r.valid == true end,
    registerLiveOutput = function(id, ref) live[id] = ref end,
    unregisterLiveOutput = function(id) live[id] = nil end,
    resolveTarget = function(id) return live[id] end,
  }
  local placementOps = {
    createObject = function(recordId, slot)
      createdCount = createdCount + 1
      local objId = string.format('@0x%x', createdCount)
      local ref = {id = objId, recordId = recordId, position = slot.position, cell = cell, valid = true, enabled = true}
      return {ref = ref, objectId = objId}, nil
    end,
    removeObject = function(ref)
      ref.valid = false
      return true, nil
    end,
  }
  local tokens, outputs = {}, {}
  for i, id in ipairs(manifest.actionIds) do
    local action = manifest.actionsById[id]
    local ctx = {
      frame = i, opId = 'op:' .. tostring(i), actionId = action.id, targetId = 'cell:balmora',
      ledger = ledger, world = worldAdapter, placementOps = placementOps,
    }
    local token = assert(runtime.capture(action.program, cell, ctx))
    local res = runtime.apply(action.program, cell, token, ctx)
    expect(res.status == 'pending' and #res.outputs == 1, 'coincident placement apply did not spawn output')
    ctx.token = token
    ctx.frame = i + 1
    local adv = runtime.advance(res.pending, cell, ctx)
    expect(adv.status == 'applied' and #adv.outputs == 1, 'coincident placement advance did not finish')
    tokens[i] = token
    outputs[i] = adv.outputs[1]
  end
  local first, second = live[outputs[1]], live[outputs[2]]
  expect(outputs[1] ~= outputs[2] and first ~= second and first.valid and second.valid
      and first.position.x == second.position.x and createdCount == 2,
    'coincident placements reused a logical or physical output')
  local rev = runtime.revert(tokens[1], cell, {
    frame = 10, opId = 'op:1', actionId = manifest.actionIds[1], targetId = 'cell:balmora',
    ledger = ledger, world = worldAdapter, placementOps = placementOps,
  })
  expect(rev.status == 'applied' and not first.valid and second.valid and second.enabled,
    'reverting one instance removed or disabled its coincident neighbor')
end

local function listsShareSourceDiscovery()
  local path = 'scripts/variationframework/leveled_creatures/data/list.yaml'
  local found = false
  for _, directory in ipairs(translator.configDirs) do
    if directory == 'scripts/variationframework/leveled_creatures/data' then found = true end
  end
  local actions, handled = translator.translateSource({path = path,
    config = {injections = {{list = 'animals', add = {{id = 'rat', level = 1}}}}}})
  expect(found and translator.matchesPath(path) and handled and #actions == 1
      and actions[1].spec.leveled.operations[1].op == 'merge_by_id'
      and actions[1].familyInput == nil,
    'list sources bypassed shared discovery or ordinary action translation')
end

function M.run()
  return support.runCases('pure VFR placement identity', {
    {'stable independent placement identities', stableIndependentInstances},
    {'duplicate permanent IDs still reject', duplicateIdsStillReject},
    {'ordinary keyed placements share native and imported identity', publicAndPrivateAdmission},
    {'coincident outputs apply and revert independently', coincidentOutputsStayIndependent},
    {'leveled-list sources use shared discovery and actions', listsShareSourceDiscovery},
  })
end
return M
