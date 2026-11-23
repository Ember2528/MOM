-- Tests the version-0 config format independently of compiler internals.
-- Both tuple and direct-payload forms pass through the shared variant/source
-- boundary.
local M = {}

package.preload['openmw.core'] = package.preload['openmw.core'] or function()
  return {contentFiles = {list = {}}}
end
package.preload['openmw.vfs'] = package.preload['openmw.vfs'] or function()
  return {
    fileExists = function() return true end,
    pathsWithPrefix = function() return function() return nil end end,
  }
end

local canonical = require('scripts.mom.contracts.canonical')
local cell_identity = require('scripts.mom.domain.cell.identity')
local extension_registry = require('scripts.mom.compiler.extension_registry')
local source_action_contract = require('scripts.mom.compiler.source_action_contract')
local source_preprocess = require('scripts.mom.compiler.source_preprocess')
local source_lowering = require('scripts.mom.compiler.source_lowering')
local source_ir = require('scripts.mom.compiler.source_ir')
local selection_plan = require('scripts.mom.compiler.selection_plan')
local compile_manifest = require(
  'scripts.mom.compiler.compile_manifest'
)
local variant_resolver = require('scripts.mom.compiler.variant_resolver')
local sss = require('scripts.mom.compat.sss.translator')

local test_support = require('pure.test_support')
local expect = test_support.expect
local unpackValues = table.unpack or unpack

local function actionCompiler(path)
  local compiler = require(path)
  return {
    publicFields = compiler.publicFields,
    prepareAction = compiler.prepareAction,
    compileAction = compiler.compileAction,
    validateProgram = compiler.validateProgram,
    outputTypeEnvelope = compiler.outputTypeEnvelope,
  }
end

local ACTION_CATALOG = {
  actions = {
    byId = {
      modify_ref = {
        module = actionCompiler('scripts.mom.actions.modify_ref.compile'),
      },
      kill_actor = {
        module = actionCompiler('scripts.mom.actions.kill_actor.compile'),
      },
      modify_inventory = {
        module = actionCompiler('scripts.mom.actions.modify_inventory.compile'),
      },
      place_ref = {
        module = actionCompiler('scripts.mom.actions.place_ref.compile'),
      },
    },
  },
}

local GUARD_REGISTRY = {
  byId = {
    time = {module = require('scripts.mom.guards.time')},
    weather = {module = require('scripts.mom.guards.weather')},
    quest_stage = {module = require('scripts.mom.guards.quest_stage')},
  },
}

local RECORD_TYPES = {
  ['ab_ex_dwrvsteamstackrod_a'] = 'Activator',
  ['ajira'] = 'NPC',
  ['barrel_01'] = 'Container',
  ['com_sack_01'] = 'Container',
  ['common_ring_01'] = 'Clothing',
  ['common_robe_05_a'] = 'Clothing',
  ['crate_01'] = 'Container',
  ['crate_01_foo'] = 'Container',
  ['dremora'] = 'Creature',
  ['ex_dwrv_steamstack00'] = 'Activator',
  ['expensive_amulet_02'] = 'Clothing',
  ['exquisite_robe_01'] = 'Clothing',
  ['furn_de_signpost_02'] = 'Static',
  ['fighters guild'] = 'Faction',
  ['galbedir'] = 'NPC',
  ['gold_001'] = 'Miscellaneous',
  ['ingred_enchanted_seeds_elayne_u'] = 'Ingredient',
  ['iron dagger'] = 'Weapon',
  ['iron_dagger'] = 'Weapon',
  ['kwama forager'] = 'Creature',
  ['light_de_lantern_01'] = 'Light',
  ['light_de_paper_lantern_off'] = 'Light',
  ['misc_com_bottle_07'] = 'Miscellaneous',
  ['misc_de_pot_green_01'] = 'Miscellaneous',
  ['mudcrab'] = 'Creature',
  ['potion_cyro_brandy_01'] = 'Potion',
  ['rat'] = 'Creature',
  ['urn_01'] = 'Container',
}

local function recordContext()
  return {
    modelRecordTypeOrder = {
      'Activator',
      'Container',
      'Creature',
      'Light',
      'Miscellaneous',
      'NPC',
      'Static',
      'Weapon',
    },
    recordExists = function(recordId, accepted)
      local typeName = RECORD_TYPES[tostring(recordId):lower()]
      if typeName == nil then return false, 'invalid_record_id' end
      if accepted ~= nil and accepted[typeName] ~= true then
        return false, 'wrong_record_type', typeName
      end
      return true, nil, typeName
    end,
    resolveLiveRefType = function(recordId)
      local typeName = RECORD_TYPES[tostring(recordId):lower()]
      if typeName == nil then return nil, 'invalid record id' end
      return typeName, nil
    end,
    resolveMeshTypes = function(model)
      local normalized = tostring(model):lower():gsub('\\', '/')
      if normalized == 'meshes/f/furn_de_signpost_02.nif' then
        return {Static = {'furn_de_signpost_02'}}, nil
      end
      if normalized == 'meshes/f/furn_de_tapestry_04.nif' then
        return {Static = {'furn_de_tapestry_04'}}, nil
      end
      if normalized == 'meshes/f/furn_de_signpost_04.nif' then
        return {Static = {'furn_de_signpost_04'}}, nil
      end
      if normalized == 'meshes/f/furn_de_tapestry_03.nif' then
        return {Static = {'furn_de_tapestry_03'}}, nil
      end
      if normalized == 'meshes/c/rat.nif' then
        return {Creature = {'rat'}}, nil
      end
      return {}, 'mesh path is unknown'
    end,
  }
end

local function cellIndex(extraExteriors)
  local entries = {}
  local index = {
    entries = entries,
    byKey = {},
    byId = {},
    byName = {},
    byDisplayName = {},
    byExteriorWorldspace = {},
    byRegion = {},
    byWorldspace = {},
  }
  local function append(id)
    local key = id:lower()
    local entry = {
      key = key,
      id = id,
      idLower = key,
      name = id,
      nameLower = key,
      displayName = id,
      displayNameLower = key,
      interiorKey = key,
      isExterior = false,
    }
    entries[#entries + 1] = entry
    index.byKey[key] = entry
    index.byId[key] = {entry}
    index.byName[key] = {entry}
    index.byDisplayName[key] = {entry}
  end
  local function appendExterior(id, gridX, gridY, region, worldspace)
    local idLower = id:lower()
    local worldspaceKey = tostring(worldspace or 'sys::default'):lower()
    local regionKey = tostring(region):lower()
    local packedCellKey = assert(cell_identity.packedCellKeyForCoords(gridX, gridY))
    local key = assert(cell_identity.exteriorKey(worldspaceKey, gridX, gridY))
    local entry = {
      key = key,
      id = id,
      idLower = idLower,
      name = id,
      nameLower = idLower,
      displayName = id,
      displayNameLower = idLower,
      isExterior = true,
      gridX = gridX,
      gridY = gridY,
      regionKey = regionKey,
      worldspaceKey = worldspaceKey,
      packedCellKey = packedCellKey,
    }
    entries[#entries + 1] = entry
    index.byKey[key] = entry
    index.byId[idLower] = {entry}
    index.byName[idLower] = {entry}
    index.byDisplayName[idLower] = {entry}
    index.byExteriorWorldspace[worldspaceKey]
      = index.byExteriorWorldspace[worldspaceKey] or {}
    index.byExteriorWorldspace[worldspaceKey][packedCellKey] = {entry}
    index.byRegion[worldspaceKey] = index.byRegion[worldspaceKey] or {}
    index.byRegion[worldspaceKey][regionKey]
      = index.byRegion[worldspaceKey][regionKey] or {}
    index.byRegion[worldspaceKey][regionKey][
      #index.byRegion[worldspaceKey][regionKey] + 1
    ] = entry
    index.byWorldspace[worldspaceKey] = index.byWorldspace[worldspaceKey] or {}
    index.byWorldspace[worldspaceKey][#index.byWorldspace[worldspaceKey] + 1] = entry
  end
  append('Balmora')
  append('Balmora, Eight Plates')
  append('Balmora, Guild of Mages')
  append('Ebernanit, Shrine')
  append('Vivec, Aurane Frernis: Apothecary')
  appendExterior('Wilderness -3, -2', -3, -2, 'West Gash Region')
  appendExterior('Wilderness 0, 0', 0, 0, 'Ascadian Isles Region')
  for i = 1, #(extraExteriors or {}) do
    appendExterior(unpackValues(extraExteriors[i]))
  end
  return index
end

local function resolve(config, opts)
  opts = opts or {}
  return variant_resolver.resolve(config, {
    activeContent = opts.activeContent or {},
    sourcePath = opts.sourcePath or 'scripts/mom/config/authored_v0_freeze.yaml',
    adapterId = opts.adapterId or 'native',
    guardRegistry = opts.guardRegistry or GUARD_REGISTRY,
  })
end

local function lowerResolved(resolved)
  local prepared, _, prepareErrors = source_lowering.prepareActions(
    resolved.actions,
    ACTION_CATALOG
  )
  if not prepared then return nil, prepareErrors end
  local lowered, lowerErrors = source_lowering.lowerActions(prepared, {
    cellIndex = cellIndex(),
    recordCtx = recordContext(),
  }, ACTION_CATALOG)
  if not lowered then return nil, lowerErrors end
  return lowered, nil, prepared
end

local function resolveAndLower(config, opts)
  local resolved, resolveError = resolve(config, opts)
  if not resolved then
    return nil, {resolveError and resolveError.message or 'source resolution failed'}
  end
  return lowerResolved(resolved)
end

local function guardedKeyedSourceCompilesAtomically()
  local sourcePath =
    'scripts/mom/config/balmora_guard_conflict_example.yaml'
  local resolved, resolveError = resolve({
    version = 0,
    variants = {
      balmora_guard_conflict_example = {
        guards = {
          {
            when = {
              {'time', 'hour', 'range', 20, 24, 'exclusive'},
            },
            actions = {
              {
                modify = {
                  {
                    'Balmora, Eight Plates',
                    'misc_com_bottle_07, (-101.395, 663.972, -168.985)',
                    {enabled = false},
                  },
                },
              },
              {
                modify = {
                  {
                    'Balmora, Eight Plates',
                    'misc_com_bottle_07, (-101.395, 663.972, -168.985)',
                    {enabled = false, scale = 0.8},
                  },
                },
              },
            },
          },
        },
      },
    },
  }, {sourcePath = sourcePath})
  expect(resolved ~= nil, 'guarded keyed source fixture did not resolve: '
    .. tostring(resolveError and resolveError.message))

  local prepared, _, prepareErrors = source_lowering.prepareActions(
    resolved.actions,
    ACTION_CATALOG
  )
  expect(prepared ~= nil, 'guarded keyed source fixture did not prepare: '
    .. table.concat(prepareErrors or {}, ' | '))
  local context = {
    cellIndex = cellIndex(),
    recordCtx = recordContext(),
  }
  local normalized, lowerErrors = source_lowering.lowerActions(
    prepared,
    context,
    ACTION_CATALOG
  )
  expect(normalized ~= nil, 'guarded keyed source fixture did not lower: '
    .. table.concat(lowerErrors or {}, ' | '))
  expect(#normalized.actions == 2,
    'guarded keyed source lost one conflicting action during lowering')
  for i = 1, #normalized.actions do
    local matchPlan = normalized.actions[i].program.matchPlan
    local record = matchPlan and matchPlan.records and matchPlan.records[1]
    expect(matchPlan and matchPlan.entryCount == 1
        and record.recordId == 'misc_com_bottle_07'
        and record.typeName == 'Miscellaneous',
      'resolved keyed entry lost its exact record/type identity')
  end

  local actionRegistry = assert(extension_registry.build('action', {
    {
      path = 'scripts/mom/actions/modify_ref.lua',
      module = require('scripts.mom.actions.modify_ref'),
    },
  }, {
    requiredMethods = {'compileAction', 'validateProgram'},
    requireProgramVersion = true,
  }))
  local guardRegistry = assert(extension_registry.build('guard', {
    {
      path = 'scripts/mom/guards/time.lua',
      module = require('scripts.mom.guards.time'),
    },
  }, {
    requiredMethods = {'compileProgram'},
    requireProgramVersion = true,
  }))
  local catalog = {
    kind = 'mom-extension-catalog',
    actions = actionRegistry,
    guards = guardRegistry,
    compat = assert(extension_registry.build('compat', {}, {})),
  }

  local sourceManifest, sourceErrors =
    compile_manifest.compileOwned(
      normalized,
      context,
      catalog
    )
  expect(sourceManifest ~= nil,
    'guarded keyed source failed aggregate manifest validation: '
      .. table.concat(sourceErrors or {}, ' | '))
  expect(#sourceManifest.actionIds == 2 and #sourceManifest.ownerIds == 1,
    'atomic aggregate lost guarded conflict candidates')
end

local function directTargetSelectionRetainsFiniteCellsAndRecoveryRoutes()
  local normalized, errors = resolveAndLower({version = 0, variants = {routing = {
    actions = {
      {modify = {{'Balmora, Guild of Mages', 'crate_01, (1, 2, 3)', {enabled = false}}}},
      {modify = {{'Balmora, Guild of Mages', 'crate_01', {
        relocate = {cell = 'Balmora, Eight Plates', position = {to = {4, 5, 6}}},
      }}}},
    },
  }}})
  expect(normalized ~= nil, 'direct routing fixture did not lower: '
    .. table.concat(errors or {}, ' | '))
  local node = normalized.actions[1]
  expect(node.resolvedSelection ~= nil, 'direct routing fixture lacks resolved facts')
  local catalog = {
    kind = 'mom-extension-catalog',
    actions = assert(extension_registry.build('action', {{
      path = 'scripts/mom/actions/modify_ref.lua',
      module = require('scripts.mom.actions.modify_ref'),
    }}, {requireProgramVersion = true})),
    guards = assert(extension_registry.build('guard', {}, {})),
    compat = assert(extension_registry.build('compat', {}, {})),
  }
  local manifest, manifestErrors = compile_manifest.compileOwned(
    normalized, {cellIndex = cellIndex(), recordCtx = recordContext()}, catalog)
  expect(manifest ~= nil, 'direct routing manifest failed: '
    .. table.concat(manifestErrors or {}, ' | '))
  expect(node.resolvedSelection == nil,
    'manifest compilation retained its resolved-selection transport record')
  local directId, relocationId
  expect(#manifest.actionIds == 2, 'direct routing fixture lost an action')
  for _, actionId in ipairs(manifest.actionIds) do
    local selection = manifest.actionsById[actionId].selection
    local universe = selection.cell and selection.cell.universe
    expect(universe ~= nil and universe.kind == 'finite'
        and #universe.entries == 1
        and universe.entries[1].key == 'balmora, guild of mages',
      'direct target or relocation discarded its finite source-cell universe')
    if #(selection.directTargets.entries or {}) == 1 then directId = actionId end
    if #selection.queryCells == 1 then relocationId = actionId end
  end
  local routes = manifest.indexes.staticByCell
  local source = routes['interior:balmora, guild of mages']
  local destination = routes['interior:balmora, eight plates']
  expect(directId and relocationId and source and #source == 2
      and ((source[1] == directId and source[2] == relocationId)
        or (source[2] == directId and source[1] == relocationId))
      and destination and #destination == 1 and destination[1] == relocationId,
    'direct target source or relocation destination was omitted from manifest wakeup routes')
end

local function mixedCellSelectionRetainsItsOpenArm()
  local status, selection, errors = selection_plan.compile({
    id = 'mixed-open-cell-universe',
    candidateTypes = {'Container'},
    predicates = {},
    directTargets = {
      expectedCount = 1,
      entries = {{
        key = 'future-crate',
        typeName = 'Container',
        recordId = 'crate_01',
        sourcePosition = {x = 1, y = 2, z = 3},
        sourcePositionKey = '1.000,2.000,3.000',
      }},
    },
  }, {
    cell = {
      exact = {'Balmora'},
      match = 'Balmora, *',
    },
    recordId = 'crate_01',
  }, {
    cellIndex = cellIndex(),
    recordCtx = recordContext(),
  }, {
    scope = 'ref',
    requireExplicitCellSelection = true,
  })
  expect(status == 'ok' and selection ~= nil,
    'mixed exact/match selection failed to compile: '
      .. table.concat(errors or {}, ' | '))
  local universe = selection.cell and selection.cell.universe
  local keys = {}
  for i = 1, #(universe and universe.entries or {}) do
    keys[universe.entries[i].key] = true
  end
  expect(universe ~= nil
      and universe.kind == 'open'
      and keys.balmora
      and keys['balmora, eight plates']
      and keys['balmora, guild of mages'],
    'mixed exact/match selection mislabeled finite seeds as a closed universe')
end

local function routeFixtureContext()
  return {
    cellIndex = cellIndex({{'Other Wilderness', 2, 1, 'West Gash Region', 'A_WORLD'}}),
    workspace = {cellSelectionPlans = {}},
    metrics = {},
  }
end

local function compileFixtureCell(cellSpec, context, requiredUniverse)
  local status, selection, errors, facts = selection_plan.compile({
    id = 'cell-route-fixture', candidateTypes = {'Container'}, predicates = {},
    directTargets = requiredUniverse and {entries = {{
      key = 'fixture-crate', typeName = 'Container', recordId = 'crate_01',
      sourcePosition = {x = 1, y = 2, z = 3}, sourcePositionKey = '1.000,2.000,3.000',
    }}} or nil,
  }, {cell = cellSpec}, context, {scope = 'ref', requireExplicitCellSelection = true})
  expect(status == 'ok', 'cell route fixture failed: ' .. table.concat(errors or {}, ' | '))
  return selection.cell, facts
end

local function cellRoutesRetainCanonicalShapesAndIndependentFacts()
  local exteriors = {
    {worldspaceKey = 'a_world', packedCellKeys = {'2,1'}},
    {worldspaceKey = 'sys::default', packedCellKeys = {'-3,-2', '0,0'}},
  }
  local previsit = {
    {worldspaceKey = 'a_world', packedCellKey = '2,1', gridX = 2, gridY = 1},
    {worldspaceKey = 'sys::default', packedCellKey = '-3,-2', gridX = -3, gridY = -2},
    {worldspaceKey = 'sys::default', packedCellKey = '0,0', gridX = 0, gridY = 0},
  }
  local exteriorSeeds = {'a_world|2,1', 'sys::default|-3,-2', 'sys::default|0,0'}
  local exact = {'Wilderness 0, 0', 'OTHER WILDERNESS', 'Wilderness -3, -2', 'wilderness 0, 0'}
  local cases = {
    {
      label = 'two exterior cells', cell = {coords = {{0, 0}, {-3, -2}, {0, 0}}},
      route = {kind = 'exact', interiorKeys = {}, exteriors = {exteriors[2]}},
      previsit = {previsit[2], previsit[3]}, seeds = {exteriorSeeds[2], exteriorSeeds[3]},
    },
    {
      label = 'mixed interior and exterior cells',
      cell = {exact = {'Balmora', exact[1], exact[2], exact[3], 'balmora'}},
      route = {kind = 'exact', interiorKeys = {'balmora'}, exteriors = exteriors},
      previsit = previsit, seeds = {'a_world|2,1', 'balmora', 'sys::default|-3,-2', 'sys::default|0,0'},
    },
    {
      label = 'exterior footprint', cell = {exact = exact}, footprint = true,
      route = {kind = 'footprint', exteriors = exteriors}, previsit = previsit, seeds = exteriorSeeds,
    },
    {
      label = 'region buckets',
      cell = {region = {'West Gash Region', 'Ascadian Isles Region', 'west gash region'},
        worldspace = {'SYS::DEFAULT', 'A_WORLD', 'sys::default'}},
      route = {kind = 'region', worldspaces = {
        {worldspaceKey = 'a_world', regionKeys = {'west gash region'}},
        {worldspaceKey = 'sys::default', regionKeys = {'ascadian isles region', 'west gash region'}},
      }}, seeds = exteriorSeeds,
    },
    {
      label = 'worldspace buckets', cell = {worldspace = {'SYS::DEFAULT', 'A_WORLD', 'sys::default'}},
      route = {kind = 'worldspace', worldspaceKeys = {'a_world', 'sys::default'}}, seeds = exteriorSeeds,
    },
    {
      label = 'exact and open union', cell = {exact = {'Balmora'}, match = 'Balmora, *'}, open = true,
      route = {kind = 'union', routes = {
        {kind = 'exact', interiorKeys = {'balmora'}, exteriors = {}}, {kind = 'deferred'},
      }}, seeds = {'balmora', 'balmora, eight plates', 'balmora, guild of mages'},
    },
    {
      label = 'footprint and open union', cell = {exact = exact, match = 'Balmora, *'},
      open = true, footprint = true,
      route = {kind = 'union', routes = {{kind = 'footprint', exteriors = exteriors}, {kind = 'deferred'}}},
      previsit = previsit,
      seeds = {'a_world|2,1', 'balmora, eight plates', 'balmora, guild of mages',
        'sys::default|-3,-2', 'sys::default|0,0'},
    },
    {label = 'unbounded cells', cell = '*', route = {kind = 'deferred'}, open = true, seeds = {}},
  }
  for i = 1, #cases do
    local case, context = cases[i], routeFixtureContext()
    local cell, facts = compileFixtureCell(case.cell, context, true)
    if case.footprint then
      local route = cell.route.kind == 'union' and cell.route.routes[1] or cell.route
      local expected = case.route.kind == 'union' and case.route.routes[1] or case.route
      expect(type(route.key) == 'string' and #route.key > 0, case.label .. ' lost its footprint identity')
      expected.key = route.key -- The identity is opaque; its exact value is not a shape contract.
    end
    expect(canonical.encode(cell.route) == canonical.encode(case.route),
      case.label .. ' changed its canonical route shape, ordering, or deduplication')
    local seeds = {}
    for j = 1, #cell.universe.entries do seeds[j] = cell.universe.entries[j].key end
    expect(cell.universe.kind == (case.open and 'open' or 'finite')
        and canonical.encode(seeds) == canonical.encode(case.seeds),
      case.label .. ' lost its independently resolved cell universe')
    expect(canonical.encode(facts.previsitEntries) == canonical.encode(case.previsit),
      case.label .. ' changed concrete previsit cells while choosing a route')
    local ordinary, ordinaryFacts = compileFixtureCell(case.cell, context, false)
    expect(ordinary.universe == nil
        and canonical.encode(ordinaryFacts.previsitEntries) == canonical.encode(case.previsit),
      case.label .. ' coupled universe retention to previsit planning')
  end
end

local function cachedCellSelectionsRemainIndependentlyOwned()
  local context = routeFixtureContext()
  local cellSpec = {
    exact = {'Wilderness 0, 0', 'Other Wilderness', 'Wilderness -3, -2'},
    match = 'Balmora, *',
  }
  local first = compileFixtureCell(cellSpec, context, true)
  local sibling, siblingFacts = compileFixtureCell(cellSpec, context, true)
  local expected, expectedFacts = canonical.encode(sibling), canonical.encode(siblingFacts)
  local ordinary = compileFixtureCell(cellSpec, context, false)
  expect(context.metrics.cellSelectionPlansBuilt == 2 and context.metrics.cellSelectionCacheHits == 1,
    'ownership fixture did not exercise a cache hit and both universe requirements')
  first.route.routes[1].exteriors[1].packedCellKeys[1] = '99,99'
  first.routeIndex.exteriorKeys.a_world['2,1'] = nil
  first.predicate.query.exact[1] = 'unrelated cell'
  first.predicateIndex.exact['wilderness 0, 0'] = nil
  first.universe.entries[1].key = 'unrelated cell'
  expect(canonical.encode(sibling) == expected and canonical.encode(siblingFacts) == expectedFacts,
    'mutating one published cell selection changed its sibling or previsit facts')
  local later, laterFacts = compileFixtureCell(cellSpec, context, true)
  expect(canonical.encode(later) == expected and canonical.encode(laterFacts) == expectedFacts
      and context.metrics.cellSelectionCacheHits == 2,
    'mutating a published cell selection poisoned a later compile from the shared cache')
  local laterOrdinary = compileFixtureCell(cellSpec, context, false)
  expect(ordinary.universe == nil and laterOrdinary.universe == nil
      and canonical.encode(ordinary) == canonical.encode(laterOrdinary)
      and context.metrics.cellSelectionCacheHits == 3,
    'cached universe retention leaked between ordinary and direct-target selections')
end

local function expectInvalidConfig(config, expected)
  local resolved, resolveError = resolve(config)
  expect(resolved == nil and resolveError
      and resolveError.kind == 'invalid-config-shape'
      and resolveError.message:find(expected, 1, true),
    'expected authored rejection containing "' .. tostring(expected)
      .. '", got ' .. tostring(resolveError and resolveError.message))
end

local function expectInvalidLowering(action, expected)
  local lowered, errors = resolveAndLower({
    version = 0,
    variants = {fixture = {actions = {action}}},
  })
  expect(lowered == nil and table.concat(errors or {}, ' | '):find(expected, 1, true),
    'expected lowering rejection containing "' .. tostring(expected)
      .. '", got ' .. table.concat(errors or {}, ' | '))
end

local function semanticNode(node)
  return {
    family = node.family,
    program = node.program,
    select = node.select,
    predicates = node.predicates,
    candidateTypes = node.candidateTypes,
    directTargets = node.directTargets,
    chance = node.chance,
    previsit = node.previsit,
  }
end

local function actionByDiagnosticId(actions, diagnosticId)
  for i = 1, #(actions or {}) do
    if actions[i].diagnosticId == diagnosticId then return actions[i] end
  end
  return nil
end

local function permanentAuthoringPaths()
  local tuple = {
    modify = {
      {'Balmora', 'crate_01', {enabled = false}, {'upright', 25}},
      {'Ald-ruhn', 'crate_02', {enabled = true}},
    },
    chance = 0.5,
  }
  local selected = {
    select = {
      recordId = 'crate_01',
      cell = 'Balmora',
    },
    filters = {
      {'exclude', 'crate_02'},
    },
    modify = {
      scale = {to = 1.25},
    },
  }
  local resolved, resolveError = variant_resolver.resolve({
    version = 0,
    name = 'authored-v0-contract',
    description = 'Both authoring paths are permanent.',
    variants = {
      z_tuple = {
        actions = {tuple},
      },
      a_selected = {
        actions = {selected},
      },
    },
  }, {
    activeContent = {},
    sourcePath = 'scripts/mom/config/authored_v0_contract.yaml',
    adapterId = 'native',
  })
  expect(resolved ~= nil, 'valid authored v0 document failed: '
    .. tostring(resolveError and resolveError.message))
  expect(resolved.version == nil and #resolved.actions == 2,
    'resolver copied the authored compatibility version into process-local IR')

  local first = resolved.actions[1]
  local second = resolved.actions[2]
  expect(first.diagnosticId == 'variant:a_selected.actions[1]'
      and second.diagnosticId == 'variant:z_tuple.actions[1]',
    'variants no longer apply in lexicographic variant-id order')
  expect(first.family == 'modify_ref' and first.spec.select.recordId == 'crate_01'
      and first.spec.modify.scale.to == 1.25,
    'select-block direct payload changed during source collection')
  expect(second.family == 'modify_ref' and second.spec.modify[1][1] == 'Balmora'
      and second.spec.modify[2][1] == 'Ald-ruhn'
      and second.spec.chance == 0.5,
    'tuple payload or tuple ordering changed during source collection')
  expect(first.source.file == 'scripts/mom/config/authored_v0_contract.yaml'
      and first.source.variant == 'a_selected'
      and first.source.path[1] == 'actions' and first.source.path[2] == 1,
    'source IR lost authored object origin')
  expect(second.source.variant == 'z_tuple'
      and second.source.path[1] == 'actions' and second.source.path[2] == 1,
    'source IR lost authored tuple origin')
end

local function authoredTupleCountHasNoCeiling()
  local tupleCount = 513
  local tuples = {}
  for i = 1, tupleCount do
    tuples[i] = {
      'Balmora',
      'light_de_lantern_01',
      {i, i * 2, i * 3},
      {yaw = i % 360, pitch = 0, roll = 0},
    }
  end

  local resolved, resolveError = resolve({
    version = 0,
    variants = {
      broad = {
        actions = {{
          place = tuples,
        }},
      },
    },
  })
  expect(resolved ~= nil,
    'broad authored tuple array failed source resolution: '
      .. tostring(resolveError and resolveError.message))
  expect(#resolved.actions == 1
      and #resolved.actions[1].spec.place == tupleCount,
    'source resolution capped or truncated a broad authored tuple array')

  local lowered, lowerErrors = lowerResolved(resolved)
  expect(lowered ~= nil,
    'broad authored tuple array failed lowering: '
      .. table.concat(lowerErrors or {}, ' | '))
  expect(#lowered.actions == 1
      and #lowered.actions[1].program.objects == tupleCount
      and lowered.actions[1].program.objects[tupleCount].slot
        == 'a:' .. tostring(tupleCount),
    'compiler lowering capped, truncated, or renumbered authored tuples')

  local actionRegistry = assert(extension_registry.build('action', {{
    path = 'scripts/mom/actions/place_ref.lua',
    module = require('scripts.mom.actions.place_ref'),
  }}, {
    requiredMethods = {'compileAction', 'validateProgram'},
    requireProgramVersion = true,
  }))
  local manifest, manifestErrors = compile_manifest.compileOwned(
    lowered,
    {cellIndex = cellIndex(), recordCtx = recordContext()},
    {
      kind = 'mom-extension-catalog',
      actions = actionRegistry,
      guards = assert(extension_registry.build('guard', {}, {})),
      compat = assert(extension_registry.build('compat', {}, {})),
    }
  )
  local compiledAction = manifest and manifest.actionsById[manifest.actionIds[1]]
  expect(manifest ~= nil
      and #manifest.actionIds == 1
      and #compiledAction.program.objects == tupleCount,
    'final manifest compilation capped a broad authored tuple array: '
      .. table.concat(manifestErrors or {}, ' | '))
end

local function documentedActionFamilyForms()
  local config = {
    version = 0,
    name = 'Documented action forms',
    description = 'Locks the exact public examples before family lowering.',
    variants = {
      documented = {
        actions = {
          {
            place = {{
              'Balmora, Guild of Mages',
              'light_de_lantern_01',
              {0, 0, 128},
              {yaw = 0, pitch = 0, roll = 0},
            }},
          },
          {
            attach = {{
              'Balmora, Guild of Mages',
              'ex_dwrv_steamstack00',
              'ab_ex_dwrvsteamstackrod_a',
              {-128, 0, 1536},
              {yaw = 0, pitch = 0, roll = 0},
            }},
            disableOriginal = true,
          },
          {
            modify = {{
              'Balmora, Eight Plates',
              'crate_01_foo',
              {enabled = false},
            }},
          },
          {
            modify = {{
              'Balmora, Eight Plates',
              'crate_01_foo, (128, 64, 0)',
              {scale = {to = 0.9}},
            }},
          },
          {
            inventory = {
              owners = {
                {'Balmora, Guild of Mages', 'ajira'},
                {'Balmora, Guild of Mages', 'galbedir'},
              },
              items = {
                gold_001 = {'add', 100},
                iron_dagger = {'equip'},
              },
            },
          },
          {
            inventory = {{
              'Balmora, Guild of Mages',
              'ajira',
              {gold_001 = {'add', 100}},
            }},
          },
          {
            kill = {{
              'Balmora, Eight Plates',
              'mudcrab',
              {},
            }},
          },
        },
      },
    },
  }
  local resolved, resolveError = resolve(config)
  expect(resolved ~= nil, 'documented family forms failed source resolution: '
    .. tostring(resolveError and resolveError.message))
  local expectedFamilies = {
    'place_ref',
    'place_ref',
    'modify_ref',
    'modify_ref',
    'modify_inventory',
    'modify_inventory',
    'kill_actor',
  }
  expect(#resolved.actions == #expectedFamilies,
    'documented action form count changed')
  for i = 1, #expectedFamilies do
    expect(resolved.actions[i].family == expectedFamilies[i],
      'documented verb-to-family mapping changed at action ' .. tostring(i))
  end
  expect(resolved.actions[1].spec.place[1][1] == 'Balmora, Guild of Mages'
      and resolved.actions[2].spec.disableOriginal == true
      and resolved.actions[3].spec.modify[1][3].enabled == false
      and resolved.actions[4].spec.modify[1][2]
        == 'crate_01_foo, (128, 64, 0)'
      and resolved.actions[5].spec.inventory.owners[2][2] == 'galbedir'
      and resolved.actions[6].spec.inventory[1][3].gold_001[2] == 100
      and resolved.actions[7].spec.kill[1][2] == 'mudcrab'
      and next(resolved.actions[7].spec.kill[1][3]) == nil,
    'documented family tuple or owners/items payload shape changed')

  local lowered, lowerErrors, prepared = lowerResolved(resolved)
  expect(lowered ~= nil, 'documented family forms failed lowering: '
    .. table.concat(lowerErrors or {}, ' | '))
  expect(#prepared == #expectedFamilies and #lowered.actions == #expectedFamilies,
    'documented family lowering changed action cardinality')
  expect(lowered.actions[1].program.mode == 'absolute'
      and lowered.actions[2].program.mode == 'relative'
      and lowered.actions[2].program.disableOriginal == true
      and lowered.actions[2].program.objects[1].rotation.yaw == 0
      and lowered.actions[3].program.basePatch.enabled == false
      and lowered.actions[4].program.matchPlan.entryCount == 1
      and lowered.actions[4].directTargets.entries[1].sourcePosition.x == 128
      and #lowered.actions[5].program.ownerGroups == 2
      and lowered.actions[6].program.ownerGroups[1].objects[1].count == 100
      and lowered.actions[7].program.matchPlan.records[1].recordId == 'mudcrab',
    'documented action forms no longer lower through their established programs')
end

local function keyedSelectorForms()
  local resolved = assert(resolve({
    version = 0,
    variants = {
      keyed = {
        actions = {
          {
            attach = {{
              'Balmora, Eight Plates',
              'meshes/f/furn_de_signpost_02.nif, (1, 2, 3)',
              'meshes/f/furn_de_tapestry_04.nif',
            }},
            disableOriginal = true,
          },
          {
            modify = {{
              'Balmora, Eight Plates',
              'meshes/f/furn_de_signpost_02.nif, (4, 5, 6)',
              {enabled = false},
            }},
          },
          {
            kill = {{
              'Balmora, Eight Plates',
              'meshes/c/rat.nif, (7, 8, 9)',
            }},
          },
        },
      },
    },
  }))
  local lowered, lowerErrors = lowerResolved(resolved)
  expect(lowered ~= nil, 'documented mesh keyed forms failed lowering: '
    .. table.concat(lowerErrors or {}, ' | '))
  local attach, modify, kill = unpackValues(lowered.actions)
  expect(attach.program.objects[1].sourceKeyKind == 'model_path'
      and attach.program.objects[1].sourcePosition.x == 1
      and attach.directTargets.entries[1].expandedFromModelPath == true
      and attach.directTargets.entries[1].sourcePosition.z == 3,
    'attach mesh/position keyed selector changed')
  expect(modify.program.matchPlan.entryCount == 1
      and modify.directTargets.entries[1].sourceKeyKind == 'record_id'
      and modify.directTargets.entries[1].sourcePosition.y == 5
      and modify.directTargets.entries[1].sourcePosition.z == 6,
    'modify mesh/position keyed selector changed')
  expect(kill.program.matchPlan.entryCount == 1
      and kill.directTargets.entries[1].sourceKeyKind == 'record_id'
      and kill.directTargets.entries[1].sourcePosition.x == 7
      and kill.directTargets.entries[1].sourcePosition.z == 9,
    'kill mesh/position keyed selector changed')
end

local function selectBlockAndDirectPayloadForms()
  local resolved = assert(resolve({
    version = 0,
    variants = {
      direct = {
        actions = {
          {
            select = {
              cell = 'Balmora, Eight Plates',
              recordId = 'crate_01_foo',
            },
            modify = {
              enabled = false,
              scale = {to = 0.9},
            },
          },
          {
            select = {
              cell = 'Balmora, Guild of Mages',
              recordId = 'ajira',
            },
            inventory = {
              gold_001 = {'add', 100},
              iron_dagger = {'equip'},
            },
          },
          {
            select = {
              cell = 'Balmora, Eight Plates',
              recordId = 'mudcrab',
            },
            kill = {},
          },
        },
      },
    },
  }))
  local lowered, lowerErrors = lowerResolved(resolved)
  expect(lowered ~= nil, 'documented direct payload forms failed lowering: '
    .. table.concat(lowerErrors or {}, ' | '))
  local modify, inventory, kill = unpackValues(lowered.actions)
  expect(modify.family == 'modify_ref'
      and modify.select.recordId == 'crate_01_foo'
      and modify.program.basePatch.enabled == false
      and modify.program.basePatch.scale.mode == 'set'
      and modify.program.basePatch.scale.value == 0.9,
    'direct modify payload changed')
  expect(inventory.family == 'modify_inventory'
      and inventory.select.recordId == 'ajira'
      and inventory.program.ownerGroups == nil
      and #inventory.program.itemOps == 2,
    'direct inventory payload changed')
  expect(kill.family == 'kill_actor'
      and kill.select.recordId == 'mudcrab'
      and kill.program.matchPlan == nil,
    'direct kill payload changed')
end

local function documentedPatchAndInventoryOperations()
  local resolved = assert(resolve({
    version = 0,
    variants = {
      payloads = {
        actions = {
          {
            select = {
              cell = 'Balmora, Eight Plates',
              recordId = 'crate_01',
            },
            modify = {
              enabled = true,
              owner = {
                factionId = 'fighters guild',
                factionRank = 2,
              },
              position = {by = {1, 2, 3}},
              rotation = {to = {yaw = 90, pitch = 5, roll = 0}},
              scale = {by = 1.1},
            },
          },
          {
            modify = {{
              'Balmora, Eight Plates',
              'crate_01',
              {
                relocate = {
                  cell = 'Balmora, Guild of Mages',
                  position = {to = {65.937, 262.079, -51.524}},
                  rotation = {yaw = 0, pitch = 0, roll = 45},
                },
              },
            }},
          },
          {
            select = {
              cell = 'Balmora, Guild of Mages',
              recordId = 'ajira',
            },
            inventory = {
              common_robe_05_a = {'replace', 'exquisite_robe_01', 'equip'},
              misc_de_pot_green_01 = {'replace', 'gold_001'},
              expensive_amulet_02 = {'remove', 1},
              potion_cyro_brandy_01 = {'remove'},
              gold_001 = {'add', 100},
              common_ring_01 = {'add', 1, 'equip'},
              iron_dagger = {'equip'},
              exquisite_robe_01 = {'unequip'},
            },
          },
          {
            select = {
              cell = 'Balmora, Eight Plates',
              recordId = 'crate_01',
            },
            modify = {
              owner = {recordId = 'ajira'},
              position = {4, 5, 6},
              rotation = {by = {yaw = 5, pitch = 0, roll = 0}},
              scale = 0.8,
            },
          },
          {
            select = {
              cell = 'Balmora, Eight Plates',
              recordId = 'crate_01',
            },
            modify = {owner = {clear = true}},
          },
        },
      },
    },
  }))
  local lowered, lowerErrors = lowerResolved(resolved)
  expect(lowered ~= nil, 'documented patch/inventory payloads failed lowering: '
    .. table.concat(lowerErrors or {}, ' | '))
  local patch = lowered.actions[1].program.basePatch
  expect(patch.enabled == true
      and patch.owner.factionId == 'fighters guild'
      and patch.owner.factionRank == 2
      and patch.position.mode == 'move'
      and patch.position.x == 1
      and patch.rotation.mode == 'set'
      and patch.rotation.yaw == 90
      and patch.scale.mode == 'scaleBy'
      and patch.scale.value == 1.1,
    'documented modify patch fields changed')
  local relocate = lowered.actions[2].program.basePatch.relocate
  expect(relocate.cell.id == 'Balmora, Guild of Mages'
      and relocate.position.x == 65.937
      and relocate.rotation.roll == 45,
    'documented relocate payload changed')
  local relocationAction = lowered.actions[2]
  expect((relocationAction.directTargets == nil
        or #(relocationAction.directTargets.entries or {}) == 0)
      and #relocationAction.queryCells == 1,
    'broadcast relocation did not retain its production query-cell shape')
  local relocationStatus, relocationSelection, relocationErrors = selection_plan.compile(
    relocationAction,
    relocationAction.select,
    {
      cellIndex = cellIndex(),
      recordCtx = recordContext(),
    },
    {
      scope = 'ref',
      requireExplicitCellSelection = true,
    }
  )
  expect(relocationSelection ~= nil,
    'broadcast relocation selection failed to compile: '
      .. table.concat(relocationErrors or {}, ' | '))
  local relocationUniverse =
    relocationSelection.cell and relocationSelection.cell.universe
  expect(relocationUniverse ~= nil
      and relocationUniverse.kind == 'finite'
      and #relocationUniverse.entries == 1
      and relocationUniverse.entries[1].key == 'balmora, eight plates'
      and #relocationSelection.queryCells == 1
      and relocationSelection.queryCells[1].key
        == 'balmora, guild of mages',
    'broadcast relocation lost its source universe or recovery cell')

  local operations = {}
  for i = 1, #lowered.actions[3].program.itemOps do
    local op = lowered.actions[3].program.itemOps[i]
    operations[op.op] = operations[op.op] or {}
    operations[op.op][op.sourceRecordId] = op
  end
  expect(operations.replace.common_robe_05_a.targetRecordId
        == 'exquisite_robe_01'
      and operations.replace.common_robe_05_a.equip == true
      and operations.replace.misc_de_pot_green_01.targetRecordId == 'gold_001'
      and operations.replace.misc_de_pot_green_01.equip == nil
      and operations.remove.expensive_amulet_02.limit == 1
      and operations.remove.potion_cyro_brandy_01.limit == nil
      and operations.add.gold_001.count == 100
      and operations.add.common_ring_01.equip == true
      and operations.equip.iron_dagger ~= nil
      and operations.unequip.exquisite_robe_01 ~= nil,
    'documented inventory operation tuple forms changed')
  local alternate = lowered.actions[4].program.basePatch
  expect(alternate.owner.recordId == 'ajira'
      and alternate.position.mode == 'set'
      and alternate.position.z == 6
      and alternate.rotation.mode == 'rotate'
      and alternate.rotation.yaw == 5
      and alternate.scale.mode == 'set'
      and alternate.scale.value == 0.8
      and lowered.actions[5].program.basePatch.owner.clear == true,
    'alternate documented position/rotation/scale/owner forms changed')
end

local function childActionAndInheritanceForms()
  local resolved = assert(resolve({
    version = 0,
    variants = {
      children = {
        actions = {
          {
            place = {{
              'Balmora, Eight Plates',
              'light_de_paper_lantern_off',
              {1018, 850, -311},
              {yaw = 0, pitch = 0, roll = 0},
            }},
            actions = {
              {modify = {scale = {to = 1.2}}},
              {inventory = {gold_001 = {'add', 7}}},
              {kill = {}},
              {modify = {relocate = {cell = 'Balmora, Guild of Mages',
                position = {10, 20, 30}}}},
            },
          },
          {
            place = {{
              'Balmora, Eight Plates',
              'barrel_01',
              {1040, 870, -311},
              {yaw = 0, pitch = 0, roll = 0},
            }},
            actions = {
              {modify = {{{scale = {to = 0.9}}}}},
              {
                select = {recordId = 'barrel_01'},
                inventory = {{
                  {gold_001 = {'add', 100}},
                  {'exclude', 'urn_01'},
                }},
              },
              {kill = {{{}}}},
            },
          },
          {
            attach = {{
              'Balmora, Eight Plates',
              'ex_dwrv_steamstack00',
              'ab_ex_dwrvsteamstackrod_a',
            }},
            disableOriginal = true,
            actions = {
              {modify = {enabled = false}},
            },
          },
        },
      },
    },
  }))
  expect(#resolved.actions == 3
      and #resolved.actions[1].children == 4
      and #resolved.actions[2].children == 3
      and #resolved.actions[3].children == 1,
    'parent-owned child action tree changed')
  expect(resolved.actions[1].children[1].source.path[1] == 'actions'
      and resolved.actions[1].children[1].source.path[2] == 1
      and resolved.actions[1].children[1].source.path[3] == 'actions'
      and resolved.actions[1].children[1].source.path[4] == 1,
    'child source origin lost its structural path')

  local lowered, lowerErrors, prepared = lowerResolved(resolved)
  expect(lowered ~= nil, 'documented child forms failed lowering: '
    .. table.concat(lowerErrors or {}, ' | '))
  expect(#prepared == 3 and #prepared[1].children == 4
      and #prepared[2].children == 3
      and #prepared[3].children == 1
      and #lowered.actions[1].children == 4
      and #lowered.actions[2].children == 3
      and #lowered.actions[3].children == 1,
    'child preprocessing or lowering flattened dependency edges')
  local direct = lowered.actions[1].children
  local compact = lowered.actions[2].children
  expect(direct[1].program.basePatch.scale.mode == 'set'
      and direct[1].program.basePatch.scale.value == 1.2
      and next(direct[1].select or {}) == nil
      and direct[2].program.itemOps[1].count == 7
      and next(direct[2].select or {}) == nil
      and direct[3].program.matchPlan == nil
      and next(direct[3].select or {}) == nil
      and next(direct[4].select or {}) == nil
      and direct[4].program.basePatch.relocate.cell.key == 'balmora, guild of mages'
      and #direct[4].queryCells == 1
      and direct[4].queryCells[1].key == 'balmora, guild of mages',
    'direct child payloads stopped inheriting parent targets')
  expect(compact[1].program.basePatch.scale.mode == 'set'
      and compact[1].program.basePatch.scale.value == 0.9
      and compact[2].select.recordId == 'barrel_01'
      and compact[2].predicates[1].kind == 'record_id_exclude'
      and compact[3].program.matchPlan == nil,
    'compact or narrowed child payload lowering changed')
  expect(lowered.actions[3].program.mode == 'relative'
      and lowered.actions[3].children[1].program.basePatch.enabled == false
      and next(lowered.actions[3].children[1].select or {}) == nil,
    'attach parent stopped supplying inherited child targets')
end

local function nestedAbsolutePlaceDestinations()
  local lowered, errors = resolveAndLower({version = 0, variants = {nested = {
    actions = {{
      place = {{'Balmora, Eight Plates', 'barrel_01', {1, 2, 3}, {yaw = 0}}},
      actions = {{
        place = {{
          {exact = {'Balmora, Guild of Mages', 'Ebernanit, Shrine'}},
          'light_de_lantern_01', {4, 5, 6}, {yaw = 90},
        }},
        actions = {{modify = {scale = {to = 0.8}}}},
      }},
    }},
  }}})
  expect(lowered ~= nil, 'nested absolute placement failed lowering: '
    .. table.concat(errors or {}, ' | '))
  local parent = lowered.actions[1]
  expect(#parent.children == 2
      and parent.children[1].program.destinationCellKey == 'balmora, guild of mages'
      and parent.children[2].program.destinationCellKey == 'ebernanit, shrine'
      and parent.children[1].select == nil and parent.children[2].select == nil,
    'nested placement did not compile all destination cells independently')
  local actionRegistry = assert(extension_registry.build('action', {
    {path = 'scripts/mom/actions/place_ref.lua', module = require('scripts.mom.actions.place_ref')},
    {path = 'scripts/mom/actions/modify_ref.lua', module = require('scripts.mom.actions.modify_ref')},
  }, {requiredMethods = {'compileAction', 'validateProgram'}, requireProgramVersion = true}))
  local manifest, manifestErrors = compile_manifest.compileOwned(lowered,
    {cellIndex = cellIndex(), recordCtx = recordContext()}, {
      kind = 'mom-extension-catalog', actions = actionRegistry,
      guards = assert(extension_registry.build('guard', {}, {})),
      compat = assert(extension_registry.build('compat', {}, {})),
    })
  expect(manifest ~= nil, 'nested absolute placement failed manifest compilation: '
    .. table.concat(manifestErrors or {}, ' | '))
  local children, grandchildren = {}, 0
  for _, id in ipairs(manifest.actionIds) do
    local action = manifest.actionsById[id]
    if action.parentId ~= nil and action.family == 'place_ref' then
      children[#children + 1] = action
    elseif action.parentId ~= nil and action.family == 'modify_ref' then
      grandchildren = grandchildren + 1
    end
  end
  expect(#children == 2 and grandchildren == 2 and children[1].id ~= children[2].id
      and children[1].scope == 'ref' and children[2].scope == 'ref'
      and children[1].selection.cell == nil and children[2].selection.cell == nil,
    'nested destination actions did not retain independent ref-scoped identities')
end

local function abbreviatedChildAttachGrammar()
  local function parent(child)
    return {place = {{'Balmora', 'furn_de_signpost_02', {1, 2, 3}, {yaw = 0}}},
      actions = {child}}
  end
  local function config(child)
    return {version = 0, variants = {fixture = {actions = {parent(child)}}}}
  end
  local firstLowered, firstErrors = resolveAndLower(config({attach = {{'furn_de_signpost_02'}}}))
  expect(firstLowered ~= nil, 'single-field attachment failed lowering: '
    .. table.concat(firstErrors or {}, ' | '))
  local lowered, errors = resolveAndLower(config({attach = {
    {'light_de_lantern_01', {0, 0, 32}, {yaw = 90}, {'exclude', 'barrel_01'}},
  }}))
  expect(lowered ~= nil, 'abbreviated attachments failed lowering: '
    .. table.concat(errors or {}, ' | '))
  local children = lowered.actions[1].children
  expect(#children == 1, 'abbreviated attachment did not produce one child action')
  local first = firstLowered.actions[1].children[1].program.objects[1]
  local second = children[1].program.objects[1]
  expect(first.targetValue == 'furn_de_signpost_02' and first.position.x == 0
      and first.position.y == 0 and first.position.z == 0
      and second.targetValue == 'light_de_lantern_01' and second.position.z == 32
      and second.rotation.yaw == 90,
    'abbreviated attachment changed target, default offset, or explicit transform')
  expect(children[1].predicates and children[1].predicates[1].kind == 'record_id_exclude'
      and (firstLowered.actions[1].children[1].predicates == nil
        or #firstLowered.actions[1].children[1].predicates == 0),
    'abbreviated attachment lost or leaked a tuple-local predicate')

  local filtered, filteredErrors = resolveAndLower(config({
    attach = {{'light_de_lantern_01', {'exclude', 'barrel_01'}}},
  }))
  expect(filtered ~= nil and filtered.actions[1].children[1].predicates[1].kind == 'record_id_exclude'
      and filtered.actions[1].children[1].program.objects[1].position.z == 0,
    'predicate without an offset was mistaken for an offset: '
      .. table.concat(filteredErrors or {}, ' | '))

  local narrowed, narrowErrors = resolveAndLower(config({
    select = {recordId = 'furn_de_signpost_02'},
    filters = {{'exclude', 'barrel_01'}},
    attach = {{'light_de_lantern_01', {0, 0, 3}}},
  }))
  expect(narrowed ~= nil and narrowed.actions[1].children[1].select.recordId == 'furn_de_signpost_02'
      and narrowed.actions[1].children[1].predicates[1].kind == 'record_id_exclude',
    'abbreviated attachment lost shared selection: ' .. table.concat(narrowErrors or {}, ' | '))

  local full, fullErrors = resolveAndLower(config({
    attach = {{'Balmora', 'furn_de_signpost_02', 'light_de_lantern_01', {0, 0, 5}}},
  }))
  expect(full ~= nil and full.actions[1].children[1].program.inheritedSource == true,
    'ordinary child tuple was misclassified: ' .. table.concat(fullErrors or {}, ' | '))
  local fullObjectCell, objectCellErrors = resolveAndLower(config({
    attach = {{{exact = {'Balmora'}}, 'furn_de_signpost_02', 'light_de_lantern_01'}},
  }))
  expect(fullObjectCell ~= nil and fullObjectCell.actions[1].children[1].program.inheritedSource == true,
    'ordinary child tuple with an object cell was misclassified: '
      .. table.concat(objectCellErrors or {}, ' | '))

  local invalid = {
    {attach = {target = 'furn_de_signpost_02'}},
    {attach = {{'furn_de_signpost_02', {0, 0}}}},
    {attach = {{'furn_de_signpost_02', {0, 0, 1}, {yaw = 'bad'}}}},
    {attach = {{'furn_de_signpost_02', {yaw = 90}}}},
    {attach = {{'Balmora', 'furn_de_signpost_02'}}},
    {attach = {{'furn_de_signpost_02'}, {'Balmora', 'furn_de_signpost_02', 'light_de_lantern_01'}}},
  }
  for _, action in ipairs(invalid) do
    local value, rejection = resolve(config(action))
    expect(value == nil and rejection ~= nil,
      'malformed child attach was accepted or misclassified')
  end
  local standalone, rejection = resolve({version = 0, variants = {fixture = {
    actions = {{attach = {{'furn_de_signpost_02', {0, 0, 32}}}}},
  }}})
  expect(standalone == nil and rejection ~= nil,
    'abbreviated attachment was accepted without a parent')
end

local function abbreviatedAttachPreparedRepresentation()
  local function prepare(rows)
    local source = source_ir.sourceAction({
      filters = {{'exclude', 'barrel_01'}}, attach = rows,
    }, {family = 'place_ref', diagnosticId = 'child'})
    return assert(source_preprocess.preprocess(source, {isChild = true}))[1]
  end
  local single = prepare({{'light_de_lantern_01', {'exclude', 'crate_01'}}})
  local batch = prepare({
    {'light_de_lantern_01', {'exclude', 'crate_01'}},
    {'furn_de_signpost_02'},
  })
  expect(single.input.payloadKind == 'inherited_tuples'
      and batch.input.payloadKind == 'inherited_tuples'
      and #single.input.payload == 1 and #batch.input.payload == 2
      and single.input.payload[1].values[1] == batch.input.payload[1].values[1],
    'single and multiple abbreviated rows did not share the prepared representation')
  expect(#single.selectPredicates == 2
      and single.selectPredicates[1].excludedIds.barrel_01
      and single.selectPredicates[2].excludedIds.crate_01
      and single.input.payload[1].predicates == nil
      and #batch.selectPredicates == 1
      and batch.input.payload[1].predicates[1].excludedIds.crate_01
      and batch.input.payload[2].predicates == nil,
    'single-row selection or batch-local predicate ownership changed')

  local config = {version = 0, variants = {fixture = {actions = {{
    place = {{'Balmora', 'furn_de_signpost_02', {1, 2, 3}, {yaw = 0}}},
    actions = {{attach = {{'light_de_lantern_01', {0, 0, 32}, {yaw = 90}}}}},
  }}}}}
  local tupleSource = assert(resolve(config))
  local directSource = assert(resolve(config))
  local legacyChild = assert(resolve(config)).actions[1].children[1]
  legacyChild.spec = nil
  legacyChild.familyInput = {verb = 'attach', payloadKind = 'direct',
    payload = {target = 'light_de_lantern_01', offset = {0, 0, 32},
      rotation = {yaw = 90}, sourceIndex = 1}}
  local bypass, bypassErrors = source_preprocess.preprocess(legacyChild, {isChild = true})
  expect(bypass == nil and table.concat(bypassErrors or {}, ' | '):find('familyInput', 1, true),
    'translator-prepared payload bypass was retained')
  local tupleLowered = assert(lowerResolved(tupleSource))
  local directLowered = assert(lowerResolved(directSource))
  expect(assert(canonical.encode(tupleLowered)) == assert(canonical.encode(directLowered)),
    'single abbreviated row changed the original direct-input program or action identity')
  local tupleAction = tupleLowered.actions[1].children[1]
  local entry = tupleAction.program.objects[1]
  expect(entry.sourceKeyKind == 'record_id' and entry.sourceRecordId == 'inherited'
      and entry.slot == 'r:inherited:1' and entry.filters == nil,
    'single-row inherited attachment lost its existing fast-path program')
  local discovery = require('scripts.mom.actions.place_ref').prepareTargetFilters({tupleAction})
  expect(discovery[tupleAction.id] == nil,
    'single abbreviated row acquired an unexpected choice target filter')
  local registry = assert(extension_registry.build('action', {{
    path = 'scripts/mom/actions/place_ref.lua', module = require('scripts.mom.actions.place_ref'),
  }}, {requiredMethods = {'compileAction', 'validateProgram'}, requireProgramVersion = true}))
  local catalog = {kind = 'mom-extension-catalog', actions = registry,
    guards = assert(extension_registry.build('guard', {}, {})),
    compat = assert(extension_registry.build('compat', {}, {}))}
  local function manifest(lowered)
    return assert(compile_manifest.compileOwned(lowered,
      {cellIndex = cellIndex(), recordCtx = recordContext()}, catalog))
  end
  expect(assert(canonical.encode(manifest(tupleLowered)))
      == assert(canonical.encode(manifest(directLowered))),
    'single abbreviated row changed compiled manifest identity')

  local filteredConfig = {version = 0, variants = {fixture = {actions = {{
    place = {{'Balmora', 'furn_de_signpost_02', {1, 2, 3}, {yaw = 0}}},
    actions = {{filters = {{'exclude', 'barrel_01'}}, attach = {{
      'light_de_lantern_01', {'exclude', 'crate_01'},
    }}}},
  }}}}}
  local filteredPublic = assert(resolveAndLower(filteredConfig)).actions[1].children[1]
  expect(#filteredPublic.predicates == 2
      and filteredPublic.predicates[1].excludedIds.barrel_01
      and filteredPublic.predicates[2].excludedIds.crate_01
      and filteredPublic.program.objects[1].filters == nil,
    'lowered single-row predicates did not retain selection order and fast path')

  local filteredSource = assert(resolve(config))
  local filteredChild = filteredSource.actions[1].children[1]
  filteredChild.spec = {attach = {
    {'light_de_lantern_01', {'exclude', 'crate_01'}},
    {'light_de_lantern_01', {0, 0, 1}, {'exclude', 'crate_01'}},
  }}
  local filteredLowered = assert(lowerResolved(filteredSource))
  local filteredAction = filteredLowered.actions[1].children[1]
  local filteredEntry = filteredAction.program.objects[1]
  expect(filteredEntry.sourceKeyKind == 'inherited'
      and filteredEntry.filters[1].excludedIds.crate_01,
    'filtered ordinary row lost parent-output matching')
  local place_ref = require('scripts.mom.actions.place_ref')
  expect(place_ref.matchesTarget(filteredAction.program, {}, {recordId = 'crate_01', typeName = 'Static'}, {}) == false
      and place_ref.matchesTarget(filteredAction.program, {}, {recordId = 'furn_de_signpost_02', typeName = 'Static'}, {}) == true,
    'filtered ordinary row did not filter excluded record pre-claim')
end

local function abbreviatedAttachRowsShareOneOperation()
  local function config(parentRecord, child)
    return {version = 0, variants = {fixture = {actions = {{
      place = {{'Balmora', parentRecord, {1, 2, 3}, {yaw = 0}}},
      actions = {child},
    }}}}}
  end
  local lowered, errors = resolveAndLower(config('furn_de_signpost_02', {
    attach = {
      {'furn_de_signpost_02', {1, 0, 0}, {'exclude', 'barrel_01'}},
      {'light_de_lantern_01', {2, 0, 0}, {'exclude', 'crate_01'}},
    },
    disableOriginal = true,
  }))
  expect(lowered ~= nil, 'abbreviated batch did not compile: '
    .. table.concat(errors or {}, ' | '))
  local children = lowered.actions[1].children
  expect(#children == 1, 'abbreviated rows became separate child operations')
  local program = children[1].program
  expect(program.disableOriginal == true and #program.objects == 2
      and program.objects[1].slot ~= program.objects[2].slot
      and program.objects[1].targetValue == 'furn_de_signpost_02'
      and program.objects[2].targetValue == 'light_de_lantern_01'
      and program.objects[1].position.x == 1 and program.objects[2].position.x == 2,
    'abbreviated rows lost their shared operation, targets, transforms, or distinct slots')
  expect(program.objects[1].filters and program.objects[2].filters
      and program.objects[1].filters[1].kind == 'record_id_exclude'
      and program.objects[2].filters[1].kind == 'record_id_exclude'
      and program.objects[1].filters[1].excludedIds.barrel_01 == true
      and program.objects[2].filters[1].excludedIds.crate_01 == true,
    'abbreviated batch lost or merged row-local predicates')

  local unsafe, unsafeErrors = resolveAndLower(config('barrel_01', {
    attach = {{'barrel_01'}, {'crate_01'}}, disableOriginal = true,
  }))
  expect(unsafe == nil and table.concat(unsafeErrors or {}, ' | '):lower():find('container', 1, true),
    'multiple abbreviated rows bypassed container transfer safety')

  local function nestedChild(selection)
    return {attach = {{'furn_de_signpost_02'}, {'barrel_01'}}, actions = {{
      select = selection,
      attach = {{'furn_de_signpost_02'}},
    }}}
  end
  local unnarrowed, unionErrors = resolveAndLower(config('furn_de_signpost_02', nestedChild(nil)))
  expect(unnarrowed == nil and table.concat(unionErrors or {}, ' | '):lower():find('container', 1, true),
    'a later batch row was omitted from the descendant type envelope')
  local narrowed, narrowErrors = resolveAndLower(config('furn_de_signpost_02',
    nestedChild({recordId = 'furn_de_signpost_02'})))
  expect(narrowed ~= nil, 'descendant selection could not narrow batched output types: '
    .. table.concat(narrowErrors or {}, ' | '))
end

local function inheritedAttachTypesAndClaims()
  local function config(parentEntries, child)
    return {version = 0, variants = {nested_attach = {actions = {{
      place = parentEntries,
      actions = {child},
    }}}}}
  end
  local static = {'Balmora', 'furn_de_signpost_02', {1, 2, 3}, {yaw = 0}}
  local container = {'Balmora', 'barrel_01', {4, 5, 6}, {yaw = 0}}
  local child = {
    attach = {{'meshes/f/replacement.nif', {0, 0, 2}}},
    disableOriginal = true,
    actions = {{attach = {{'meshes/f/second.nif'}}, disableOriginal = true}},
  }
  local lowered, errors = resolveAndLower(config({static, container}, child))
  expect(lowered ~= nil, 'inherited attach did not compile proven output types: '
    .. table.concat(errors or {}, ' | '))
  local children = lowered.actions[1].children
  expect(#children == 2, 'mixed parent did not produce typed inherited attach actions')
  local found = {}
  for _, action in ipairs(children) do
    local entry = action.program.objects[1]
    found[entry.inferredType] = action
    expect(action.program.inheritedAnchor == true and #action.children == 2,
      'nested inherited model replacement lost its source envelope')
  end
  local containerClaims = table.concat(found.Container.claims.keys, ',')
  expect(found.Static ~= nil and found.Container ~= nil
      and containerClaims:find('ref.inventory', 1, true)
      and containerClaims:find('ref.lock', 1, true)
      and containerClaims:find('ref.enabled', 1, true),
    'container inherited attach omitted durable transfer claims')
  local rejected, rejectErrors = resolveAndLower(config({container}, {
    attach = {{'furn_de_signpost_02'}},
  }))
  expect(rejected == nil and table.concat(rejectErrors or {}, ' | '):find('Container', 1, true),
    'unsafe container child attachment was not rejected')

  local selected, selectionErrors = resolveAndLower(config({static, container}, {
    select = {recordId = 'furn_de_signpost_02'},
    attach = {{'meshes/f/replacement.nif'}},
    actions = {{attach = {{'meshes/f/second.nif'}}}},
  }))
  expect(selected ~= nil, 'inherited exact selection failed lowering: '
    .. table.concat(selectionErrors or {}, ' | '))
  expect(#selected.actions[1].children == 1
      and selected.actions[1].children[1].program.objects[1].inferredType == 'Static'
      and #selected.actions[1].children[1].children == 1
      and selected.actions[1].children[1].children[1].program.objects[1].inferredType == 'Static',
    'exact selection did not narrow child and grandchild output types')
  local registry = assert(extension_registry.build('action', {{
    path = 'scripts/mom/actions/place_ref.lua', module = require('scripts.mom.actions.place_ref'),
  }}, {requiredMethods = {'compileAction', 'validateProgram'}, requireProgramVersion = true}))
  local manifest, manifestErrors = compile_manifest.compileOwned(selected,
    {cellIndex = cellIndex(), recordCtx = recordContext()}, {
      kind = 'mom-extension-catalog', actions = registry,
      guards = assert(extension_registry.build('guard', {}, {})),
      compat = assert(extension_registry.build('compat', {}, {})),
    })
  expect(manifest ~= nil, 'inherited exact selection failed manifest compilation: '
    .. table.concat(manifestErrors or {}, ' | '))

  local unknown = source_ir.sourceAction({modify = {}}, {
    family = 'unknown_parent', diagnosticId = 'unknown-parent',
    children = {source_ir.sourceAction({attach = {{'furn_de_signpost_02'}}}, {
      family = 'place_ref', diagnosticId = 'unknown-child',
    })},
  })
  local catalog = {actions = {byId = {place_ref = ACTION_CATALOG.actions.byId.place_ref,
    unknown_parent = {module = {
      publicFields = {'modify'}, prepareAction = function(input) return input end,
      compileAction = function() return {} end,
    }},
  }}}
  local prepared, _, prepareErrors = source_lowering.prepareActions({unknown}, catalog)
  expect(prepared ~= nil, 'unknown family fixture failed preparation: '
    .. table.concat(prepareErrors or {}, ' | '))
  local unavailable, envelopeErrors = source_lowering.lowerActions(prepared, {
    cellIndex = cellIndex(), recordCtx = recordContext(),
  }, catalog)
  expect(unavailable == nil and table.concat(envelopeErrors or {}, ' | '):find(
      'does not declare a safe output type envelope', 1, true),
    'unknown parent silently bypassed inherited attach type admission')
end

local function inheritedAttachSkipsMissingParentPlacements()
  local diagnostics = require('scripts.mom.diagnostics.compile_diagnostics')
  local function compile(withChild)
    local action = {place = {
      {'Balmora', '__missing_place_target', {0, 0, 0}, {}},
      {'Balmora', 'furn_de_signpost_02', {1, 2, 3}, {}},
    }}
    if withChild then action.actions = {{attach = {{'furn_de_signpost_02'}}}} end
    local source = assert(resolve({version = 0, variants = {ordering = {actions = {action}}}}))
    local prepared = assert(source_lowering.prepareActions(source.actions, ACTION_CATALOG))
    local collector = diagnostics.new()
    local result, errors = source_lowering.lowerActions(prepared, {
      recordCtx = recordContext(), cellIndex = cellIndex(), diagnosticCollector = collector,
    }, ACTION_CATALOG)
    expect(result, table.concat(errors or {}, ' | '))
    return result, diagnostics.forCompile(collector).summary.diagnostics
  end
  local ordinary, ordinaryDiagnostics = compile(false)
  local nested, nestedDiagnostics = compile(true)
  expect(#ordinary.actions[1].program.objects == 1
      and #nested.actions[1].program.objects == 1
      and #nested.actions[1].children == 1
      and nested.actions[1].children[1].program.objects[1].inferredType == 'Static'
      and ordinaryDiagnostics.total == 1 and nestedDiagnostics.total == 1
      and ordinaryDiagnostics.samples[1].code == nestedDiagnostics.samples[1].code,
    'inherited attach changed missing placement skip behavior or diagnostics')
end

local function inheritedTupleAttachPreservesSourceSelectors()
  local lowered, errors = resolveAndLower({version = 0, variants = {nested = {actions = {{
    place = {{'Balmora', 'furn_de_signpost_02', {0, 0, 0}, {}}},
    actions = {
      {attach = {{'Balmora', 'furn_de_signpost_02', 'furn_de_signpost_02'}}},
      {attach = {{'Balmora', 'f/custom_only_generated.nif', 'furn_de_signpost_02'}}},
    },
  }}}}})
  expect(lowered, table.concat(errors or {}, ' | '))
  local record, mesh = lowered.actions[1].children[1], lowered.actions[1].children[2]
  expect(record.program.inheritedSource == true
      and record.program.inheritedAnchor == nil
      and record.program.objects[1].sourceKeyKind == 'record_id'
      and record.resolvedSelection.exactIds[1] == 'furn_de_signpost_02'
      and mesh.program.inheritedSource == true
      and mesh.program.objects[1].sourceKeyKind == 'model_path'
      and mesh.program.objects[1].sourceRecordId == 'meshes/f/custom_only_generated.nif'
      and mesh.candidateTypes.Static and mesh.resolvedSelection == nil
      and mesh.directTargets == nil,
    'tuple child lost keyed source semantics or generated-model type envelope')
  local registry = assert(extension_registry.build('action', {{
    path = 'scripts/mom/actions/place_ref.lua', module = require('scripts.mom.actions.place_ref'),
  }}, {requiredMethods = {'compileAction', 'validateProgram'}, requireProgramVersion = true}))
  local manifest, manifestErrors = compile_manifest.compileOwned(lowered,
    {cellIndex = cellIndex(), recordCtx = recordContext()}, {
      kind = 'mom-extension-catalog', actions = registry,
      guards = assert(extension_registry.build('guard', {}, {})),
      compat = assert(extension_registry.build('compat', {}, {})),
    })
  expect(manifest, table.concat(manifestErrors or {}, ' | '))
  local mixed = {version = 0, variants = {nested = {actions = {{
    place = {
      {'Balmora', 'furn_de_signpost_02', {0, 0, 0}, {}},
      {'Balmora', 'barrel_01', {1, 0, 0}, {}},
    },
    actions = {{
      attach = {{'Balmora', 'f/generated_parent.nif', 'f/replacement.nif'}},
      disableOriginal = true,
    }},
  }}}}}
  local typed, typedErrors = resolveAndLower(mixed)
  expect(typed, table.concat(typedErrors or {}, ' | '))
  local claimsByType = {}
  for _, child in ipairs(typed.actions[1].children) do
    claimsByType[child.program.objects[1].inferredType] = table.concat(child.claims.keys, ',')
  end
  expect(claimsByType.Static and claimsByType.Container
      and claimsByType.Container:find('ref.inventory', 1, true)
      and claimsByType.Container:find('ref.lock', 1, true),
    'generated mesh tuple omitted an inherited type or container claims')
  mixed.variants.nested.actions[1].actions[1].disableOriginal = nil
  local unsafe = resolveAndLower(mixed)
  expect(unsafe == nil, 'unsafe inherited container mesh tuple was accepted')
end

local function sharedSelectionAndTupleComposition()
  local resolved = assert(resolve({
    version = 0,
    variants = {
      composition = {
        actions = {
          {
            chance = 0.5,
            filters = {'upright', 25},
            modify = {
              {
                'Balmora',
                'crate_01',
                {enabled = false},
                {'facing', 'north', 15},
                {'exclude', 'urn_01'},
              },
              {
                'Ald-ruhn',
                'crate_02',
                {enabled = true},
              },
            },
          },
          {
            previsit = true,
            chance = 1,
            modify = {{
              {
                coords = {-3, -2},
                kind = 'exterior',
                region = 'West Gash Region',
              },
              'furn_de_signpost_02, (-22512.762, -13476.332, 645.224)',
              {enabled = false},
            }},
          },
          {
            select = {
              recordId = {'crate_01', 'urn_01'},
              cell = {
                exact = {'Balmora', 'Balmora, Eight Plates'},
                match = 'Balmora, *',
                kind = 'interior',
                worldspace = 'sys::default',
                region = 'West Gash Region',
                coords = {{-3, -2}, {0, 0}},
                exclude = {match = 'Balmora, Guild*'},
              },
            },
            filters = {
              {'upright'},
              {'exclude', 'crate_02'},
            },
            modify = {scale = {to = 1.25}},
          },
        },
      },
    },
  }))
  local prepared, _, prepareErrors = source_lowering.prepareActions(
    resolved.actions,
    ACTION_CATALOG
  )
  expect(prepared ~= nil, 'shared composition preprocessing failed: '
    .. table.concat(prepareErrors or {}, ' | '))
  expect(#prepared == 4
      and prepared[1].input.select.cell == 'Balmora'
      and prepared[2].input.select.cell == 'Ald-ruhn'
      and prepared[1].input.chance == 0.5
      and prepared[2].input.chance == 0.5,
    'multi-cell tuple splitting or shared chance propagation changed')
  expect(prepared[1].selectPredicates[1].kind == 'orientation'
      and prepared[1].selectPredicates[1].mode == 'upright'
      and prepared[1].input.payload[1].predicates[1].kind == 'orientation'
      and prepared[1].input.payload[1].predicates[1].mode == 'facing'
      and prepared[1].input.payload[1].predicates[2].kind == 'record_id_exclude'
      and prepared[2].selectPredicates[1].mode == 'upright',
    'sibling or tuple-local predicates left the shared predicate channel')
  expect(prepared[3].input.previsit == true
      and prepared[3].input.select.cell.coords[1] == -3
      and prepared[4].input.select.recordId[2] == 'urn_01'
      and prepared[4].input.select.cell.exclude.match == 'Balmora, Guild*'
      and #prepared[4].selectPredicates == 2,
    'previsit, select-block, or filter syntax changed during preprocessing')
end

local function documentedCellPredicateAndPrevisitForms()
  local cellForms = {
    '*',
    {exact = {'Balmora', 'Ald-ruhn'}},
    {match = 'Balmora, *'},
    {kind = 'exterior'},
    {kind = 'interior'},
    {kind = 'exterior', region = 'West Gash Region'},
    {worldspace = 'sys::default'},
    {kind = 'exterior', coords = {-3, -2}},
    {exclude = {match = 'Balmora, *'}},
  }
  local directions = {
    45,
    'north',
    'east',
    'south',
    'west',
    'northeast',
    'southeast',
    'southwest',
    'northwest',
  }
  local filters = {
    {'upright'},
    {'upright', 25},
    {'exclude', 'urn_01', 'crate_02'},
  }
  for i = 1, #directions do
    filters[#filters + 1] = {'facing', directions[i]}
  end
  filters[#filters + 1] = {'facing', 'north', 15}

  local actions = {}
  for i = 1, #cellForms do
    actions[#actions + 1] = {
      select = {
        cell = cellForms[i],
        recordId = i == 1 and {'crate_01', 'crate_02'} or 'crate_01',
      },
      filters = i == 1 and filters or nil,
      chance = i == 1 and 0.5 or nil,
      modify = {enabled = false},
    }
  end
  local previsitForms = {
    'Wilderness -3, -2',
    {kind = 'exterior', coords = {-3, -2}},
    {kind = 'exterior', region = 'West Gash Region'},
    {worldspace = 'sys::default'},
  }
  for i = 1, #previsitForms do
    actions[#actions + 1] = {
      select = {
        cell = previsitForms[i],
        recordId = 'crate_01',
      },
      previsit = true,
      modify = {enabled = false},
    }
  end

  local lowered, lowerErrors = resolveAndLower({
    version = 0,
    variants = {
      documented = {actions = actions},
    },
  })
  expect(lowered ~= nil,
    'documented cell/filter/previsit forms failed lowering: '
      .. table.concat(lowerErrors or {}, ' | '))
  expect(#lowered.actions == #cellForms + #previsitForms,
    'documented cell selector forms changed action cardinality')
  expect(lowered.actions[1].chance == 0.5
      and lowered.actions[1].select.recordId[2] == 'crate_02'
      and #lowered.actions[1].predicates == #filters,
    'documented recordId array, chance, or predicate forms changed')
  for i = #cellForms + 1, #lowered.actions do
    expect(lowered.actions[i].previsit == true,
      'documented previsit form was not retained at action '
        .. tostring(i - #cellForms))
  end
end

local function guardAndVariantConditionSurface()
  local resolved = assert(resolve({
    version = 0,
    variants = {
      active_guard = {
        description = 'All documented condition lists and guard families.',
        requires = {'Morrowind.esm'},
        requiresAny = {'Tribunal.esm', 'Bloodmoon.esm'},
        requiresNot = {'Conflict.esp'},
        guards = {
          {
            when = {
              {'time', 'hour', 'eq', 12},
              {'time', 'hour', 'range', 18, 6, 'inclusive'},
              {'time', 'hour', 'range', 9, 17},
              {'time', 'hour', 'range', 9, 17, 'exclusive'},
              {'time', 'month', 'min', 4},
              {'time', 'day', 'max', 20},
              {'time', 'dayOfWeek', 'any', {1, 7}},
              {'time', 'yearDay', 'not', {1, 2, 3}},
              {'time', 'season', 'eq', 'summer'},
              {'time', 'season', 'any', {'spring', 'summer'}},
              {'time', 'date', 'eq', {month = 4, day = 12}},
              {
                'time',
                'date',
                'any',
                {
                  {month = 4, day = 12},
                  {month = 4, day = 13},
                },
              },
              {
                'time',
                'date',
                'range',
                {month = 4, day = 1},
                {month = 4, day = 30},
                'inclusive',
              },
              {'time', 'flags.isWeekend', true},
              {'weather', 'Bitter Coast Region', 'eq', 1},
              {'weather', 'Bitter Coast Region', 'any', {1, 2, 3}},
              {'weather', 'Molag Amur Region', 'not', {4}},
              {'quest_stage', 'A1_1_FindSpymaster', 'eq', 10},
              {'quest_stage', 'A1_1_FindSpymaster', 'min', 10},
              {'quest_stage', 'A1_1_FindSpymaster', 'max', 50},
              {'quest_stage', 'A1_1_FindSpymaster', 'any', {10, 20}},
              {'quest_stage', 'A1_1_FindSpymaster', 'not', {0}},
              {'quest_stage', 'A1_1_FindSpymaster', 'range', 10, 50, 'inclusive'},
            },
            actions = {
              {
                kill = {{
                  'Balmora, Eight Plates',
                  'mudcrab',
                }},
              },
            },
          },
        },
      },
      skipped_forbidden = {
        requiresNot = {'Morrowind.esm'},
        actions = {{kill = {{'Balmora', 'rat'}}}},
      },
      skipped_missing_any = {
        requiresAny = {'MissingA.esp', 'MissingB.esp'},
        actions = {{kill = {{'Balmora', 'rat'}}}},
      },
    },
  }, {
    activeContent = {
      ['morrowind.esm'] = true,
      ['bloodmoon.esm'] = true,
    },
  }))
  expect(#resolved.actions == 1,
    'variant condition activation changed')
  local action = resolved.actions[1]
  local guards = action.guardOwner and action.guardOwner.when or {}
  expect(action.guardOwner.id == 'variant:active_guard.guards[1]'
      and #guards == 23
      and guards[1].type == 'time'
      and guards[14].type == 'time'
      and guards[15].type == 'weather'
      and guards[17].type == 'weather'
      and guards[18].type == 'quest_stage'
      and guards[23].type == 'quest_stage',
    'compact time/weather/quest guard families changed')
  expect(action.source.variant == 'active_guard'
      and action.source.path[1] == 'guards'
      and action.source.path[2] == 1
      and action.source.path[3] == 'actions'
      and action.source.path[4] == 1,
    'guard-owned action source origin changed')
end

local function nativeCompatEquivalenceAndOrigin()
  local compatPath = 'scripts/staticSwitcher/data/Balmora.yaml'
  local document = assert(sss.translateSource({
    path = compatPath,
    config = {
      replace_names = {'Balmora'},
      exterior_cells = {{x = -3, y = -2}},
      replace_meshes = {
        ['f\\Furn_DE_signpost_02.nif'] = 'f\\Furn_De_Tapestry_04.NIF',
      },
      ignore_records = {'furn_de_signpost_02'},
    },
  }))
  expect(source_action_contract.validateSourceActions(document, {adapterId = 'sss'}),
    'SSS output is not shared source IR')
  local compatActions = document
  local translated = document[1].spec
  local native = assert(resolve({
    version = 0,
    variants = {
      native_equivalent = {
        actions = {
          {
            attach = translated.attach,
            disableOriginal = translated.disableOriginal,
            filters = translated.filters,
            previsit = translated.previsit,
          },
        },
      },
    },
  }, {
    sourcePath = 'scripts/mom/config/native_sss_equivalent.yaml',
  }))
  expect(canonical.assertHash(compatActions[1].spec)
      == canonical.assertHash(native.actions[1].spec),
    'compat translation stopped producing the public native action semantics')
  expect(compatActions[1].source.adapterId == 'sss'
      and compatActions[1].source.file == compatPath
      and compatActions[1].source.path[1] == 'replace_meshes'
      and native.actions[1].source.adapterId == 'native'
      and native.actions[1].source.file
        == 'scripts/mom/config/native_sss_equivalent.yaml'
      and native.actions[1].source.variant == 'native_equivalent',
    'native or compat source origin changed')

  local compatLowered = assert(lowerResolved({actions = compatActions}))
  local nativeLowered = assert(lowerResolved(native))
  expect(canonical.assertHash(semanticNode(compatLowered.actions[1]))
      == canonical.assertHash(semanticNode(nativeLowered.actions[1])),
    'equivalent native/SSS actions diverged after the shared family compiler')
end

local function variantConditionsRemainAdditive()
  local resolved = assert(variant_resolver.resolve({
    version = 0,
    variants = {
      c_forbidden = {
        requiresNot = {'Morrowind.esm'},
        actions = {{kill = {{'Balmora', 'rat_01'}}}},
      },
      b_any = {
        requiresAny = {'Tribunal.esm', 'Bloodmoon.esm'},
        actions = {{kill = {{'Balmora', 'rat_02'}}}},
      },
      a_all = {
        requires = {'Morrowind.esm'},
        actions = {{kill = {{'Balmora', 'rat_03'}}}},
      },
    },
  }, {
    activeContent = {
      ['morrowind.esm'] = true,
      ['bloodmoon.esm'] = true,
    },
    sourcePath = 'conditions.yaml',
    adapterId = 'native',
  }))
  expect(#resolved.actions == 2,
    'satisfied variants stopped composing additively')
  expect(actionByDiagnosticId(
    resolved.actions,
    'variant:a_all.actions[1]'
  ) ~= nil, 'requires variant was not applied')
  expect(actionByDiagnosticId(
    resolved.actions,
    'variant:b_any.actions[1]'
  ) ~= nil, 'requiresAny variant was not applied')
  expect(actionByDiagnosticId(
    resolved.actions,
    'variant:c_forbidden.actions[1]'
  ) == nil, 'requiresNot variant was incorrectly applied')
end

local function publicShapeStaysStrict()
  local _, missingVersion = variant_resolver.resolve({variants = {}})
  expect(missingVersion and missingVersion.kind == 'invalid-config-shape'
      and missingVersion.message:find('version: expected', 1, true),
    'missing authored version became valid')

  local _, topLevelActions = variant_resolver.resolve({
    version = 0,
    variants = {},
    actions = {},
  })
  expect(topLevelActions and topLevelActions.message:find(
    'actions/guards: top-level fields are not allowed',
    1,
    true
  ), 'top-level actions became valid')

  local actionError = source_action_contract.validate({
    id = 'authored-id-is-forbidden',
    modify = {{'Balmora', 'crate_01', {enabled = false}}},
  }, 'variant:fixture.actions[1]')
  expect(type(actionError) == 'string'
      and actionError:find('.id: is not allowed', 1, true),
    'authored action id became public')

  local _, renamedVariants = variant_resolver.resolve({
    version = 0,
    fragments = {},
    variants = {},
  })
  expect(renamedVariants and renamedVariants.message:find(
    'config.fragments: is not allowed',
    1,
    true
  ), 'an alternate public variants name was accidentally accepted')
end

local function invalidAuthoredShapesStayInvalid()
  local invalidActions = {
    {
      action = {
        modify = {enabled = false},
        kill = {},
      },
      expected = 'multiple verb keys found',
    },
    {
      action = {chance = 1},
      expected = 'no verb key found',
    },
    {
      action = {
        type = 'modify_ref',
        modify = {enabled = false},
      },
      expected = '.type: is not allowed',
    },
    {
      action = {
        id = 'authored-id',
        modify = {enabled = false},
      },
      expected = '.id: is not allowed',
    },
    {
      action = {
        match = '*',
        modify = {enabled = false},
      },
      expected = '.match: is not allowed',
    },
    {
      action = {
        __internal = true,
        modify = {enabled = false},
      },
      expected = '.__internal: is not allowed',
    },
    {
      action = {
        previsit = 'yes',
        modify = {enabled = false},
      },
      expected = '.previsit: expected boolean',
    },
    {
      action = {
        select = {type = 'UnsupportedType'},
        modify = {enabled = false},
      },
      expected = 'unsupported reference type',
    },
    {
      action = {
        select = {
          recordId = {},
        },
        modify = {enabled = false},
      },
      expected = '.select.recordId: expected non-empty array',
    },
    {
      action = {
        select = {
          cell = {
            exclude = {
              exclude = {match = 'Balmora*'},
            },
          },
        },
        modify = {enabled = false},
      },
      expected = '.select.cell.exclude.exclude: is not allowed',
    },
    {
      action = {
        place = {{
          '*',
          'light_de_lantern_01',
          {0, 0, 0},
          {yaw = 0},
        }},
      },
      expected = 'wildcard or match cell selections cannot be used as place destinations',
    },
    {
      action = {
        place = {{
          'Balmora',
          'light_de_lantern_01',
          {0, 0, 0},
          {yaw = 0},
          {'upright'},
        }},
      },
      expected = 'trailing predicates are not supported',
    },
    {
      action = {attach = {}},
      expected = '.attach: expected non-empty tuple array',
    },
    {
      action = {
        inventory = {
          owner = {'Balmora', 'ajira'},
          items = {gold_001 = {'add', 1}},
        },
      },
      expected = '.inventory.owner: is not allowed; use owners',
    },
    {
      action = {
        inventory = {
          owners = {{'Balmora', 'ajira'}},
        },
      },
      expected = '.inventory.items: expected inventory payload object',
    },
    {
      action = {
        kill = {reason = 'unsupported'},
      },
      expected = '.kill.reason: is not allowed',
    },
    {
      action = {
        modify = {enabled = false},
        actions = {{kill = {}}},
      },
      expected = '.actions: only place and attach actions can own child actions',
    },
    {
      action = {
        place = {{
          'Balmora',
          'light_de_lantern_01',
          {0, 0, 0},
          {yaw = 0},
        }},
        actions = {{
          attach = {{
            'Balmora',
            'light_de_lantern_01',
            42,
          }},
        }},
      },
      expected = 'replacement target string',
    },
  }
  for i = 1, #invalidActions do
    expectInvalidConfig({
      version = 0,
      variants = {
        invalid = {actions = {invalidActions[i].action}},
      },
    }, invalidActions[i].expected)
  end

  expectInvalidConfig({
    version = 0,
    variants = {
      invalid_guard = {
        guards = {{
          when = {type = 'time'},
          actions = {{kill = {{'Balmora', 'rat'}}}},
        }},
      },
    },
  }, '.when: expected array')
  expectInvalidConfig({
    version = 0,
    variants = {
      invalid_guard = {
        guards = {{
          select = {cell = 'Balmora'},
          when = {{'time', 'hour', 'eq', 12}},
          actions = {{kill = {{'Balmora', 'rat'}}}},
        }},
      },
    },
  }, '.select: is not allowed')
  expectInvalidConfig({
    version = 0,
    variants = {
      invalid_variant = {
        actions = {},
        transition = true,
      },
    },
  }, 'variants.invalid_variant.transition: is not allowed')
  expectInvalidConfig({
    version = 0,
  }, 'variants: is required')
  expectInvalidConfig({
    version = 0,
    name = {},
    variants = {},
  }, 'name: expected string')
  expectInvalidConfig({
    version = 0,
    variants = {
      invalid_variant = {
        requires = 'Morrowind.esm',
      },
    },
  }, 'variants.invalid_variant.requires: expected array')

  expectInvalidLowering({
    select = {
      cell = 'Balmora',
      recordId = 'crate_01',
    },
    modify = {teleport = true},
  }, '.modify.teleport: is not allowed')
  expectInvalidLowering({
    inventory = {{
      'Balmora',
      'meshes/f/furn_de_signpost_02.nif',
      {gold_001 = {'add', 1}},
    }},
  }, 'mesh-path keyed selectors are not supported here')
  expectInvalidLowering({
    kill = {{
      'Balmora',
      'rat',
      {resurrect = true},
    }},
  }, '.kill[1][2].resurrect: is not allowed')
  expectInvalidLowering({
    place = {{
      'Balmora',
      'meshes/f/furn_de_signpost_02.nif',
      {0, 0, 0},
      {yaw = 0},
    }},
  }, 'absolute placement requires a placed record id, not a mesh path')
  expectInvalidLowering({
    filters = {'upright'},
    place = {{
      'Balmora',
      'light_de_lantern_01',
      {0, 0, 0},
      {yaw = 0},
    }},
  }, 'absolute place_ref only supports cell selection')
  expectInvalidLowering({
    select = {recordId = 'ex_dwrv_steamstack00'},
    attach = {{
      'Balmora',
      'ex_dwrv_steamstack00',
      'ab_ex_dwrvsteamstackrod_a',
    }},
  }, 'attach infers exact anchor record ids from source keys')
  expectInvalidLowering({
    modify = {
      {'Balmora', 'crate_01', {enabled = false}},
      {'Balmora', 'crate_01, (1, 2, 3)', {enabled = true}},
    },
  }, 'cannot mix broadcast and keyed targets in one action')
  expectInvalidLowering({
    modify = {
      {'Balmora', 'crate_01', {enabled = false}},
      {'Balmora', 'crate_01_foo', {enabled = true}},
    },
  }, 'multiple broadcast tuples in one action')
  expectInvalidLowering({
    modify = {{
      'Balmora',
      'crate_01, (1, 2, 3)',
      {
        relocate = {
          cell = 'Balmora, Guild of Mages',
          position = {to = {4, 5, 6}},
        },
      },
    }},
  }, '.relocate: is not allowed')
  expectInvalidLowering({
    select = {
      cell = 'Balmora',
      recordId = 'crate_01',
    },
    modify = {
      owner = {factionRank = 1},
    },
  }, '.owner.factionRank: requires factionId')
  expectInvalidLowering({
    modify = {
      {
        'Balmora',
        'crate_01, (1, 2, 3)',
        {enabled = false},
      },
      {
        'Balmora, Eight Plates',
        'crate_01, (7, 8, 9)',
        {enabled = true},
      },
      {
        'Balmora',
        'crate_01, (4, 5, 6)',
        {owner = {factionRank = 1}},
      },
    },
  }, '.modify[3][2].owner.factionRank: requires factionId')
  expectInvalidLowering({
    select = {
      cell = 'Balmora',
      recordId = 'ajira',
    },
    inventory = {
      potion_cyro_brandy_01 = {'equip'},
    },
  }, 'equipment operation requires Armor, Clothing, Light, or Weapon')
end

local function compilerStageOutcomes()
  local target_lowering = require('scripts.mom.compiler.target_lowering')
  local context = {cellIndex = cellIndex(), recordCtx = recordContext()}
  local outcomes = {
    {status = 'ok', select = {cell = 'Balmora', recordId = 'crate_01'}},
    {status = 'skip', select = {cell = 'Balmora', recordId = '__missing_record'}},
    {status = 'error', select = {cell = 'Balmora', type = 'Container'}},
  }
  for i = 1, #outcomes do
    local outcome = outcomes[i]
    local status, selection, errors, details = selection_plan.compile(
      {id = 'stage-outcome'}, outcome.select, context, {scope = 'ref'})
    expect(status == outcome.status and (selection ~= nil) == (status == 'ok')
        and (errors ~= nil) == (status == 'error')
        and (details ~= nil) == (status == 'ok'),
      'selection construction confused success, omission, and invalid source')
  end
  local targetOutcomes = {
    {status = 'ok', entries = {{sourceRecordId = 'crate_01'}}},
    {status = 'skip', entries = {}},
    {status = 'error', entries = {{sourceRecordId = '__missing_record'}}},
  }
  for i = 1, #targetOutcomes do
    local outcome = targetOutcomes[i]
    local loweredSpec = {id = 'target-outcome'}
    local status, resolved, errors, entries, metadata = target_lowering.finalizeResolvedEntries(
      nil, {}, {}, {
        recordCtx = context.recordCtx, entries = outcome.entries,
        lowered = loweredSpec, attachDirectTargetPlan = false,
      })
    expect(status == outcome.status and (resolved ~= nil) == (status == 'ok')
        and (errors ~= nil) == (status == 'error'),
      'target stage confused success, omission, and invalid source')
    if status == 'ok' then
      expect(resolved == loweredSpec and #entries == 1
          and metadata.candidateTypes.Container == true
          and resolved.select.recordId == nil
          and metadata.resolvedSelection.exactIds[1] == 'crate_01',
        'target stage copied its owned spec or lost resolved metadata')
    end
  end
end

local function resolvedTargetFactsAreConsumedDirectly()
  local targets = require('scripts.mom.compiler.target_lowering')
  local lookupCount = 0
  local context = {
    cellIndex = cellIndex(),
    recordCtx = {resolveLiveRefType = function(id)
      lookupCount = lookupCount + 1
      return 'Container'
    end},
  }
  local entries = {
    {sourceKeyKind = 'record_id', sourceRecordId = 'crate_01', inferredType = 'Container'},
    {sourceKeyKind = 'record_id', sourceRecordId = 'crate_01', inferredType = 'Container'},
  }
  local resolved = targets.resolvedSelection(entries, {}, context.recordCtx)
  local node = {id = 'resolved-selection', candidateTypes = {Container = true}, resolvedSelection = resolved}
  local status, selection, errors, facts = selection_plan.compile(
    node, {cell = 'Balmora'}, context, {scope = 'ref'})
  expect(status == 'ok' and errors == nil and lookupCount == 0
      and #selection.exactIds == 1 and selection.exactIds == resolved.exactIds
      and selection.exactIdQueries == resolved.exactIdQueries
      and selection.exactIdQueries[1].typeName == 'Container'
      and facts.specificity == 1110,
    'resolved target handoff repeated inference or copied final arrays')
  expect(targets.resolvedSelection(entries, {recordId = {'urn_01'}}, context.recordCtx) == nil,
    'explicit authored IDs were replaced with family target IDs')
  local explicitStatus, explicit = selection_plan.compile(
    {id = 'explicit-selection', candidateTypes = {Container = true}},
    {cell = 'Balmora', recordId = {'urn_01'}}, context, {scope = 'ref'})
  expect(explicitStatus == 'ok' and lookupCount == 1 and explicit.exactIds[1] == 'urn_01',
    'explicit authored IDs lost their existing type intersection or retained-ID semantics')
  local modelContext = {resolveLiveRefType = function() return false, 'ambiguous_record_type' end}
  local ambiguous = targets.resolvedSelection({{
    sourceRecordId = 'ambiguous', inferredType = 'Container', sourceExpandedFromModelPath = true,
  }}, {}, modelContext)
  local ambiguousStatus = selection_plan.compile({
    id = 'ambiguous-model', candidateTypes = {Container = true}, resolvedSelection = ambiguous,
  }, {cell = 'Balmora'}, context, {scope = 'ref'})
  expect(ambiguousStatus == 'skip', 'model expansion bypassed global record-ID ambiguity')

  local catalog = {
    kind = 'mom-extension-catalog',
    actions = assert(extension_registry.build('action', {{
      path = 'scripts/mom/actions/modify_ref.lua', module = require('scripts.mom.actions.modify_ref'),
    }}, {requireProgramVersion = true})),
    guards = assert(extension_registry.build('guard', {}, {})),
    compat = assert(extension_registry.build('compat', {}, {})),
  }
  local mixed = targets.resolvedSelection({
    {sourceKeyKind = 'record_id', sourceRecordId = 'crate_01', inferredType = 'Container'},
    {sourceKeyKind = 'record_id', sourceRecordId = 'ajira', inferredType = 'NPC'},
  }, {}, recordContext())
  local node = {
    kind = 'action', id = 'extension-narrowing', family = 'modify_ref',
    sourceRef = 'extension-narrowing.yaml#actions[1]',
    select = {cell = 'Balmora'}, program = {basePatch = {enabled = false}},
    claims = {keys = {'ref.enabled'}}, reversible = true, children = {},
    candidateTypes = {Container = true}, resolvedSelection = mixed,
  }
  local plain = require('scripts.mom.contracts.plain_data')
  local inferredNode = assert(plain.detach(node))
  inferredNode.resolvedSelection = nil
  inferredNode.select.recordId = {'ajira', 'crate_01'}
  local context = {cellIndex = cellIndex(), recordCtx = recordContext()}
  local manifest, errors = compile_manifest.compileOwned({actions = {node}}, context, catalog)
  expect(manifest ~= nil, table.concat(errors or {}, ' | '))
  local inferred = assert(compile_manifest.compileOwned({actions = {inferredNode}}, context, catalog))
  local action = manifest.actionsById[manifest.actionIds[1]]
  expect(#action.selection.exactIds == 2 and #action.selection.exactIdQueries == 1
      and action.selection.exactIdQueries[1].typeName == 'Container'
      and canonical.encode(manifest) == canonical.encode(inferred),
    'extension type narrowing changed manifest identity, exact IDs, or queried excluded types')
end

local function familyPreparationParsesSelectorsOnce()
  local keyed = require('scripts.mom.compiler.keyed_targets')
  local config = {version = 0, variants = {prepared = {actions = {
    {modify = {{'Balmora', 'crate_01, (1, 2, 3)', {enabled = false}, {'upright'}}}},
    {kill = {{'Balmora', 'rat', {}}}},
    {inventory = {{'Balmora', 'ajira', {gold_001 = {'add', 1}}}}},
    {attach = {{'Balmora', 'furn_de_signpost_02', 'light_de_lantern_01'}}},
    {place = {{'Balmora', 'light_de_lantern_01', {1, 2, 3}, {yaw = 0}}}},
  }}}}
  local source = assert(resolve(config))
  local original, parseCount = keyed.parseSelectorKey, 0
  keyed.parseSelectorKey = function(...)
    parseCount = parseCount + 1
    return original(...)
  end
  local ok, message = pcall(function()
    local prepared, queries, errors = source_lowering.prepareActions(source.actions, ACTION_CATALOG)
    expect(prepared ~= nil, table.concat(errors or {}, ' | '))
    expect(parseCount == 4 and queries.recordIds.crate_01 and queries.recordIds.rat
        and queries.recordIds.ajira and queries.recordIds.gold_001 and queries.recordIds.light_de_lantern_01,
      'family preparation did not collect queries from exactly-once parsed selectors')
    for i = 1, #prepared do
      local row = prepared[i].input.payload[1]
      expect(row.values == nil and row.sourceIndex == 1 and prepared[i].spec == nil,
        'prepared family payload retained a superseded tuple/spec representation')
    end
    expect(prepared[1].input.payload[1].predicates[1].mode == 'upright',
      'tuple-local predicate was separated from its parsed target')
    local plain = require('scripts.mom.contracts.plain_data')
    local before = assert(plain.detach(prepared))
    local normalized, errors = source_lowering.lowerActions(prepared, {
      cellIndex = cellIndex(), recordCtx = recordContext(),
    }, ACTION_CATALOG)
    expect(normalized ~= nil and #normalized.actions == 5 and parseCount == 4
        and normalized.actions[1].program.basePatch == nil,
      table.concat(errors or {'family lowering reparsed selectors or lost actions'}, ' | '))
    expect(plain.equalValidated(before, prepared),
      'lowering mutated a prepared payload shared by parent cell splits')
  end)
  keyed.parseSelectorKey = original
  expect(ok, message)
end

local function preparedSelectorErrorsRespectSkippedBranches()
  local compile_diagnostics = require('scripts.mom.diagnostics.compile_diagnostics')
  local function lowerWithDiagnostics(action)
    local source = assert(resolve({version = 0, variants = {ordering = {actions = {action}}}}))
    local prepared = assert(source_lowering.prepareActions(source.actions, ACTION_CATALOG))
    local collector = compile_diagnostics.new()
    local result, errors = source_lowering.lowerActions(prepared, {
      recordCtx = recordContext(), cellIndex = cellIndex(), diagnosticCollector = collector,
    }, ACTION_CATALOG)
    return result, errors, compile_diagnostics.forCompile(collector).summary.diagnostics
  end
  local orderedFailures = {
    {modify = {
      {'Balmora', 'crate_01, (1, 2, 3)', {owner = {recordId = '__missing_owner'}}},
      {'Balmora', 'crate_01, (4, 5, 6)', {owner = {factionRank = 1}}},
    }},
    {inventory = {
      {'Balmora', 'ajira', {__missing_item = {'add', 1}}},
      {'Balmora', 'ajira', {gold_001 = {'wrong', 1}}},
    }},
    {kill = {{'Balmora', '__missing_actor', {}}, {'Balmora', 'rat', {damage = 1}}}},
  }
  for i = 1, #orderedFailures do
    local result, errors, diagnostics = lowerWithDiagnostics(orderedFailures[i])
    expect(result == nil and errors ~= nil and diagnostics.total == 1,
      'later prepared syntax error suppressed an earlier unresolved-target warning')
  end
  local result, errors, diagnostics = lowerWithDiagnostics({
    place = {
      {'Balmora', 'light_de_lantern_01', {1, 2, 3}, {}},
      {'Balmora, Eight Plates', 'light_de_lantern_01', {4, 5, 6}, {}},
    },
    actions = {{modify = {owner = {recordId = '__missing_owner'}}}},
  })
  expect(result ~= nil and #result.actions == 2 and errors == nil and diagnostics.total == 2
      and diagnostics.samples[1].path == diagnostics.samples[2].path,
    'shared child preparation changed per-parent lowering diagnostics')
  local inventory = require('scripts.mom.actions.modify_inventory.compile')
  -- Trusted source/family callers may supply malformed rows that the v0 reader
  -- rejects earlier. Preparation must still respect item-dependent reachability.
  for _, owner in ipairs({7, 'bad', {}}) do
    for _, itemId in ipairs({'__missing_item', 'gold_001'}) do
      local input, prepareErrors = inventory.prepareAction({
        id = 'owner-validation', verb = 'inventory', payloadKind = 'direct',
        payload = {owners = {owner}, items = {[itemId] = {'add', 1}}},
      }, {recordIds = {}, meshPathTypes = {}}, {})
      expect(input ~= nil and prepareErrors == nil,
        'standalone owner validation ran before item resolution')
      local programs, errors = inventory.compileAction(input, {recordCtx = recordContext()})
      if itemId == '__missing_item' then
        expect(programs ~= nil and #programs == 0 and errors == nil,
          'malformed standalone owner prevented unresolved-item omission')
      else
        expect(programs == nil and errors ~= nil,
          'reachable malformed standalone owner escaped validation')
      end
    end
  end
  for _, owner in ipairs({7, '', {}}) do
    local input, errors = inventory.prepareAction({
      id = 'tuple-owner-validation', verb = 'inventory', payloadKind = 'tuples',
      payload = {{sourceIndex = 1, values = {owner, {__missing_item = {'add', 1}}}}},
    }, {recordIds = {}, meshPathTypes = {}}, {})
    expect(input ~= nil and errors == nil, 'tuple owner validation failed outside lowering')
    local programs, errors = inventory.compileAction(input, {recordCtx = recordContext()})
    expect(programs == nil and errors[1]:find('expected owner selector string', 1, true),
      'tuple owner string validation moved behind item resolution')
  end
  local cases = {
    {skip = true, action = {attach = {{'Balmora', 'crate_01, (bad)', '__missing_target'}}}},
    {skip = false, action = {attach = {{'Balmora', 'crate_01, (bad)', 'light_de_lantern_01'}}}},
    {skip = true, action = {inventory = {{'Balmora', 'crate_01, (bad)', {__missing_item = {'add', 1}}}}}},
    {skip = false, action = {inventory = {{'Balmora', 'crate_01, (bad)', {gold_001 = {'add', 1}}}}}},
    {skip = true, action = {inventory = {owners = {{'Balmora', 'crate_01, (bad)'}}, items = {__missing_item = {'add', 1}}}}},
    {skip = false, action = {inventory = {owners = {{'Balmora', 'crate_01, (bad)'}}, items = {gold_001 = {'add', 1}}}}},
  }
  for i = 1, #cases do
    local case = cases[i]
    local lowered, errors = resolveAndLower({version = 0, variants = {prepared = {actions = {case.action}}}})
    if case.skip then
      expect(lowered ~= nil and #lowered.actions == 0 and errors == nil,
        'preparation promoted an unreachable selector error into rejection')
    else
      expect(lowered == nil and table.concat(errors or {}, ' | '):find('invalid keyed position suffix', 1, true),
        'lowering discarded the prepared selector error after its branch became reachable')
    end
  end
end

local function keyedPositionRequiresThreeFiniteNumbers()
  local keyed = require('scripts.mom.compiler.keyed_targets')
  local malformed = {
    'urn_01, (1,garbage,2,3)', 'urn_01, (1,,2,3)',
    'urn_01, (1,2,3,garbage)', 'urn_01, (,1,2,3)',
    'urn_01, (1,2,3,)', 'urn_01, (1,2,1e309)',
    'urn_01, (1,2,nan)', 'urn_01, (1,2)',
  }
  for i = 1, #malformed do
    local parsed, err = keyed.parseSelectorKey(malformed[i])
    expect(parsed == nil and err and err:find('invalid keyed position suffix', 1, true),
      'malformed keyed coordinates were not rejected: ' .. malformed[i])
  end
  local parsed = assert(keyed.parseSelectorKey('urn_01, ( -1.5, +2, 3e2 )'))
  expect(parsed.sourcePosition.x == -1.5 and parsed.sourcePosition.y == 2
      and parsed.sourcePosition.z == 300,
    'valid signed, fractional or exponent coordinates changed')
  for _, action in ipairs({
    {modify = {{'Balmora', malformed[2], {enabled = false}}}},
    {kill = {{'Balmora', malformed[2]}}},
    {attach = {{'Balmora', malformed[2], 'light_de_lantern_01'}}},
    {inventory = {{'Balmora', malformed[2], {gold_001 = {'add', 1}}}}},
  }) do
    local lowered, errors = resolveAndLower({version = 0, variants = {
      keyed_position = {actions = {action}},
    }})
    expect(lowered == nil and table.concat(errors or {}, ' | '):find(
      'invalid keyed position suffix', 1, true),
      'action family accepted malformed keyed coordinates')
  end
end

local function modifyPatchRejectsUnexpectedFields()
  local patch = require('scripts.mom.actions.modify_ref.patch')
  local cases = {
    {{scale = {to = 2, byy = 8}}, '.scale.byy: is not allowed'},
    {{position = {by = {1, 2, 3}, too = {4, 5, 6}}}, '.position.too: is not allowed'},
    {{rotation = {by = {yaw = 5}, too = {yaw = 9}}}, '.rotation.too: is not allowed'},
    {{enabled = true, owner = {clear = 'true'}}, '.owner.clear: expected boolean'},
    {{rotation = {by = 42}}, '.rotation.by: expected object'},
    {{position = {to = {1, 2, 3, extra = 4}}}, '.position.to: expected [x, y, z] array', true},
  }
  for i = 1, #cases do
    local value, err = patch.normalizePatch(cases[i][1], 'patch', true)
    expect(value == nil and err and err:find(cases[i][2], 1, true),
      'invalid patch did not identify its malformed field: ' .. tostring(err))
    if not cases[i][3] then
      local lowered, errors = resolveAndLower({version = 0, variants = {patch_validation = {
        actions = {{select = {cell = 'Balmora', recordId = 'crate_01'}, modify = cases[i][1]}},
      }}})
      expect(lowered == nil and table.concat(errors or {}, ' | '):find(cases[i][2], 1, true),
        'authored modify action accepted an invalid nested patch')
    end
  end
  local valid, err = patch.normalizePatch({
    enabled = true, owner = {clear = false},
    position = {by = {-1, 2, 3}}, rotation = {to = {yaw = 90}}, scale = {to = 2},
  }, 'patch', true)
  expect(valid ~= nil and err == nil and valid.position.x == -1
      and valid.rotation.yaw == 90 and valid.scale.value == 2,
    'valid patch forms were rejected')
end

local CASES = {
  {'keyed positions require exactly three finite numbers', keyedPositionRequiresThreeFiniteNumbers},
  {'modify patch validates nested fields', modifyPatchRejectsUnexpectedFields},
  {'prepared selector error reachability', preparedSelectorErrorsRespectSkippedBranches},
  {'family preparation parses selectors once', familyPreparationParsesSelectorsOnce},
  {'resolved target selection handoff', resolvedTargetFactsAreConsumedDirectly},
  {'compiler stage success, omission, and rejection', compilerStageOutcomes},
  {'permanent tuple and select authoring paths', permanentAuthoringPaths},
  {'authored tuple count has no ceiling', authoredTupleCountHasNoCeiling},
  {
    'guarded keyed source compiles atomically',
    guardedKeyedSourceCompilesAtomically,
  },
  {
    'direct targets retain finite cells and recovery routes',
    directTargetSelectionRetainsFiniteCellsAndRecoveryRoutes,
  },
  {
    'mixed cell selections retain their open arm',
    mixedCellSelectionRetainsItsOpenArm,
  },
  {'canonical cell routes retain independent planning facts', cellRoutesRetainCanonicalShapesAndIndependentFacts},
  {'cached cell selections remain independently owned', cachedCellSelectionsRemainIndependentlyOwned},
  {'documented action family forms', documentedActionFamilyForms},
  {'keyed selector forms', keyedSelectorForms},
  {'select-block direct payload forms', selectBlockAndDirectPayloadForms},
  {'documented patch and inventory operations', documentedPatchAndInventoryOperations},
  {'child action inheritance forms', childActionAndInheritanceForms},
  {'nested absolute placement destinations', nestedAbsolutePlaceDestinations},
  {'abbreviated child attach grammar', abbreviatedChildAttachGrammar},
  {'abbreviated attach prepared representation', abbreviatedAttachPreparedRepresentation},
  {'abbreviated attach rows share one operation', abbreviatedAttachRowsShareOneOperation},
  {'inherited attach type envelopes and claims', inheritedAttachTypesAndClaims},
  {'inherited attach preserves missing parent placement skips', inheritedAttachSkipsMissingParentPlacements},
  {'inherited tuple attach retains keyed selectors', inheritedTupleAttachPreservesSourceSelectors},
  {'shared selection and tuple composition', sharedSelectionAndTupleComposition},
  {'documented cell predicate and previsit forms', documentedCellPredicateAndPrevisitForms},
  {'guard and variant condition syntax', guardAndVariantConditionSurface},
  {'native and compat semantic equivalence', nativeCompatEquivalenceAndOrigin},
  {'additive variant conditions', variantConditionsRemainAdditive},
  {'strict public shape', publicShapeStaysStrict},
  {'invalid authored shapes stay invalid', invalidAuthoredShapesStayInvalid},
}

function M.run()
  return test_support.runCases('authored config v0', CASES)
end

return M
