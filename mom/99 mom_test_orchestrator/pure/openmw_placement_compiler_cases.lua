local type_capabilities = require('scripts.mom.actions.place_ref.type_capabilities')
local place_runtime = require('scripts.mom.actions.place_ref.runtime')
local test_support = require('pure.test_support')

local M = {}
local expect = test_support.expect

local function tupleRecords(tuples)
  local out = {}
  for i = 1, #tuples do out[i] = {values = tuples[i], sourceIndex = i} end
  return out
end
local function compilePrepared(compiler, input, ctx)
  input.payload = tupleRecords(input.payload)
  local prepared, errors = compiler.prepareAction(input, {recordIds = {}, meshPathTypes = {}}, ctx)
  if not prepared then return nil, errors end
  return compiler.compileAction(prepared, ctx)
end

local function makeRelativeProgram(opts)
  opts = opts or {}
  return {
    mode = 'relative',
    disableOriginal = opts.disableOriginal,
    objects = {{
      slot = 'r:1',
      sourceKeyKind = 'record_id',
      sourceRecordId = opts.sourceRecordId or 'source_static',
      inferredType = opts.inferredType or 'Static',
      targetKind = opts.targetKind or 'record_id',
      targetValue = opts.targetValue or 'target_lamp',
      targetType = opts.targetType or 'Static',
      position = {x = 0, y = 0, z = 0},
    }},
  }
end

local function compilerCarriesResolvedOutputType()
  package.preload['openmw.vfs'] = package.preload['openmw.vfs'] or function()
    return {
      fileExists = function() return true end,
      pathsWithPrefix = function() return function() return nil end end,
    }
  end
  local compiler = require('scripts.mom.actions.place_ref.compile')
  local lowered, errors = compilePrepared(compiler, {
    id = 'absolute-placement',
    select = {cell = 'Balmora'},
    verb = 'place', payloadKind = 'tuples', payload = {{'target_lamp', {1, 2, 3}, {yaw = 0}}},
  }, {
    recordCtx = {
      recordExists = function(id) return id == 'target_lamp', nil end,
      resolveLiveRefType = function(id)
        if id == 'target_lamp' then return 'Static', nil end
        return nil, 'missing'
      end,
    },
  })
  expect(lowered ~= nil, table.concat(errors or {}, ' | '))
  expect(lowered[1].kind == 'mom-family-program'
      and lowered[1].spec.program.objects[1].targetType == 'Static',
    'placement compiler discarded resolved output type')
end

local function compilerCarriesRelativeDirectTargets()
  local compiler = require('scripts.mom.actions.place_ref.compile')
  local lowered, errors = compilePrepared(compiler, {
    id = 'relative-placement',
    select = {cell = 'Balmora, Eight Plates'},
    verb = 'attach', payloadKind = 'tuples', payload = {{
      'source_rope, (1680.0, 800.0, -311.0)',
      'target_static',
    }},
    options = {disableOriginal = true},
  }, {
    recordCtx = {
      recordExists = function(id)
        return id == 'source_rope' or id == 'target_static', nil
      end,
      resolveLiveRefType = function(id)
        if id == 'source_rope' or id == 'target_static' then return 'Static', nil end
        return nil, 'missing'
      end,
    },
  })
  expect(lowered ~= nil, table.concat(errors or {}, ' | '))
  local direct = lowered[1].directTargets
  local entry = direct and direct.entries and direct.entries[1] or nil
  expect(direct and direct.expectedCount == 1 and entry
      and entry.recordId == 'source_rope'
      and entry.sourcePosition.x == 1680
      and entry.sourcePosition.y == 800
      and entry.sourcePosition.z == -311,
    'relative placement compiler did not narrow discovery to its keyed source')
end

local function sourceTypeCapabilityMatrix()
  local staticClaims = assert(type_capabilities.claimsForProgram(makeRelativeProgram({disableOriginal = true})))
  expect(#staticClaims == 2 and staticClaims[1] == 'output.existence'
      and staticClaims[2] == 'ref.enabled',
    'base-record source compiled the wrong claim union')

  local containerProgram = makeRelativeProgram({
    disableOriginal = true,
    sourceRecordId = 'container_source',
    inferredType = 'Container',
    targetType = 'Container',
  })
  local containerClaims = assert(type_capabilities.claimsForProgram(containerProgram))
  expect(#containerClaims == 4 and containerClaims[1] == 'output.existence'
      and containerClaims[2] == 'ref.enabled'
      and containerClaims[3] == 'ref.inventory'
      and containerClaims[4] == 'ref.lock',
    'container source did not compile its conservative transfer claim union')

  containerProgram.disableOriginal = nil
  local invalid, reason = type_capabilities.claimsForProgram(containerProgram)
  expect(invalid == nil and reason:find('requires disableOriginal', 1, true),
    'container clone without source handoff was accepted')
  containerProgram.disableOriginal = true
  containerProgram.objects[1].targetType = 'Static'
  invalid, reason = type_capabilities.claimsForProgram(containerProgram)
  expect(invalid == nil and reason:find('requires a Container output', 1, true),
    'container transfer into a non-container was accepted')

  local lightProgram = makeRelativeProgram({
    disableOriginal = true,
    inferredType = 'Light',
    targetType = 'Light',
  })
  invalid, reason = type_capabilities.claimsForProgram(lightProgram)
  expect(invalid == nil and reason:find('item-bearing', 1, true),
    'item-bearing light clone was accepted without item-data transfer')
  expect(type_capabilities.classify('NPC').kind == 'unsupported'
      and type_capabilities.classify('Door').kind == 'unsupported',
    'actor or door source was not classified as unsupported')

  -- Verify runtime capture rejects unsupported NPC sources and skips scripted Activators.
  local baseCtx = {
    opId = 'op:1', targetId = 'content:000001:morrowind.esm',
    refOps = {
      read = function()
        return {
          enabled = true, scale = 1,
          cell = {id = 'Balmora', key = 'balmora', isExterior = false},
          position = {x = 0, y = 0, z = 0},
          rotation = {yaw = 0, pitch = 0, roll = 0},
        }, nil
      end,
    },
    placementOps = {
      sourceRecordInfo = function(typeName)
        if typeName == 'Activator' then return {mwscript = 'unsafe_script'}, nil end
        return {isRespawning = typeName == 'Container'}, nil
      end,
    },
  }
  baseCtx.targetFacts = {recordId = 'source_static', typeName = 'NPC', position = {x = 0, y = 0, z = 0}}
  local npcTok, npcErr = place_runtime.capture(
    makeRelativeProgram({disableOriginal = true, inferredType = 'NPC'}), {}, baseCtx
  )
  expect(npcTok == nil and tostring(npcErr):find('unsupported', 1, true),
    'authoritative actor source was not rejected during capture')

  baseCtx.targetFacts = {recordId = 'source_static', typeName = 'Activator', position = {x = 0, y = 0, z = 0}}
  local actTok = assert(place_runtime.capture(
    makeRelativeProgram({disableOriginal = true, inferredType = 'Activator'}), {}, baseCtx
  ))
  expect(actTok.noop == true, 'scripted activator was not skipped during capture')

  -- Respawning container capture is pure read-only and never resolves inventory.
  baseCtx.targetFacts = {recordId = 'container_source', typeName = 'Container', position = {x = 0, y = 0, z = 0}}
  local contTok = assert(place_runtime.capture(makeRelativeProgram({
    disableOriginal = true,
    sourceRecordId = 'container_source',
    inferredType = 'Container',
    targetType = 'Container',
  }), {}, baseCtx))
  expect(not contTok.noop and contTok.slots[1].transferKind == 'container'
      and contTok.slots[1].sourceRespawning == true,
    'respawning container capture failed to prepare transfer slot read-only')
end

local function compilerPreservesLargePlacementPrograms()
  local compiler = require('scripts.mom.actions.place_ref.compile')
  local tuples = {}
  for i = 1, 257 do
    tuples[i] = {'target_lamp', {i, 0, 0}, {yaw = 0}}
  end
  local resolutionCalls = 0
  local lowered, errors = compilePrepared(compiler, {
    id = 'large-placement',
    select = {cell = 'Balmora'},
    verb = 'place', payloadKind = 'tuples', payload = tuples,
  }, {
    recordCtx = {
      recordExists = function()
        resolutionCalls = resolutionCalls + 1
        return true
      end,
      resolveLiveRefType = function()
        resolutionCalls = resolutionCalls + 1
        return 'Static'
      end,
    },
  })
  expect(lowered ~= nil and errors == nil
      and #lowered == 1
      and #lowered[1].spec.program.objects == #tuples
      and lowered[1].spec.program.objects[1].position.x == 1
      and lowered[1].spec.program.objects[#tuples].position.x == #tuples
      and resolutionCalls > 0,
    table.concat(errors or {
      'large authored placement did not compile unchanged',
    }, ' | '))

  local queries = {recordIds = {}, meshPathTypes = {}}
  local ok, collectError = pcall(compiler.prepareAction, {
    id = 'large-placement', select = {cell = 'Balmora'},
    verb = 'place', payloadKind = 'tuples', payload = tupleRecords(tuples),
  }, queries)
  expect(ok == true and type(collectError) == 'table'
      and queries.recordIds.target_lamp == true,
    'large authored placement did not complete query collection')
end

local function compilerCreatureMeshReplacement()
  local compiler = require('scripts.mom.actions.place_ref.compile')
  local ctx = {
    modelExists = function() return true end,
    recordCtx = {
      recordExists = function(id)
        return id == 'source_scamp' or id == 'other_creature'
      end,
      resolveLiveRefType = function(id)
        if id == 'source_scamp' or id == 'other_creature' then return 'Creature' end
        return nil, 'missing record'
      end,
      resolveMeshTypes = function()
        return {Creature = {'source_scamp'}}, nil
      end,
    },
  }
  local function compile(rows, disableOriginal)
    return compilePrepared(compiler, {
      id = 'creature-mesh-replacement',
      select = {cell = 'Balmora'},
      verb = 'attach', payloadKind = 'tuples', payload = rows,
      options = {disableOriginal = disableOriginal},
    }, ctx)
  end
  for _, selector in ipairs({'source_scamp', 'r/scamp.nif'}) do
    local lowered, errors = compile({{selector, 'rv/replacement.nif'}}, true)
    expect(lowered ~= nil, table.concat(errors or {}, ' | '))
    local spec = lowered[1].spec
    expect(spec.program.objects[1].inferredType == 'Creature'
        and spec.program.objects[1].targetKind == 'model_path'
        and spec.program.disableOriginal == true
        and #lowered[1].claims.keys == 2,
      'existing attach tuple failed to compile a one-for-one Creature mesh replacement')
  end

  local invalid = compile({{'source_scamp', 'other_creature'}}, true)
  expect(invalid == nil, 'Creature record replacement bypassed mesh-only policy')
  invalid = compile({{'source_scamp', 'rv/replacement.nif'}}, false)
  expect(invalid == nil, 'Creature mesh attachment without source replacement was accepted')
  invalid = compile({
    {'source_scamp', 'rv/replacement.nif'},
    {'source_scamp', 'rv/second.nif'},
  }, true)
  expect(invalid == nil, 'Creature source was allowed to produce multiple mesh outputs')

  local lowered, errors = compile({
    {'source_scamp, (10, 20, 30)', 'rv/replacement.nif'},
    {'source_scamp, (40, 50, 60)', 'rv/second.nif'},
  }, true)
  expect(lowered ~= nil and #lowered[1].spec.program.objects == 2,
    table.concat(errors or {'distinct keyed Creature replacements were rejected'}, ' | '))
end

local function recordReplacementPreservesOwnerWhenDisablingOriginal()
  local owner = {recordId = 'arrille', factionId = 'thieves guild', factionRank = 2}
  local ctx = {
    opId = 'op:owner', targetId = 'content:000001:morrowind.esm',
    targetFacts = {recordId = 'source_static', typeName = 'Static', position = {x = 0, y = 0, z = 0}},
    refOps = {
      read = function()
        return {
          enabled = true, scale = 1, owner = owner,
          cell = {id = 'Balmora', key = 'balmora', isExterior = false},
          position = {x = 1, y = 2, z = 3},
          rotation = {yaw = 0, pitch = 0, roll = 0},
        }, nil
      end,
    },
    placementOps = {
      sourceRecordInfo = function() return {model = 'meshes/orig.nif', isRespawning = false}, nil end,
    },
  }
  local replaceTok = assert(place_runtime.capture(makeRelativeProgram({
    disableOriginal = true, targetKind = 'record_id', targetValue = 'target_lamp',
  }), {}, ctx))
  expect(replaceTok.slots[1].owner ~= nil
      and replaceTok.slots[1].owner.recordId == 'arrille'
      and replaceTok.slots[1].owner.factionId == 'thieves guild'
      and replaceTok.slots[1].owner.factionRank == 2,
    'record_id replacement with disableOriginal=true dropped original ref owner')

  local attachTok = assert(place_runtime.capture(makeRelativeProgram({
    disableOriginal = false, targetKind = 'record_id', targetValue = 'target_lamp',
  }), {}, ctx))
  expect(attachTok.slots[1].owner == nil,
    'non-disabling record_id attachment unexpectedly copied source ref owner')
end

local CASES = {
  {'compiler output type', compilerCarriesResolvedOutputType},
  {'compiler relative direct targets', compilerCarriesRelativeDirectTargets},
  {'source type capability matrix', sourceTypeCapabilityMatrix},
  {'compiler large placement cardinality',
    compilerPreservesLargePlacementPrograms},
  {'compiler Creature mesh replacement', compilerCreatureMeshReplacement},
  {'record replacement preserves owner when disabling original',
    recordReplacementPreservesOwnerWhenDisablingOriginal},
}

function M.run()
  return test_support.runCases('pure OpenMW placement compiler', CASES)
end

return M
