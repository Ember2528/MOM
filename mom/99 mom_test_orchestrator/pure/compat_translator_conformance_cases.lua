package.preload['openmw.core'] = package.preload['openmw.core'] or function()
  return {contentFiles = {list = {}}}
end
package.preload['openmw.vfs'] = package.preload['openmw.vfs'] or function()
  return {pathsWithPrefix = function() return function() end end}
end
package.preload['openmw.markup'] = package.preload['openmw.markup'] or function()
  return {}
end

local canonical = require('scripts.mom.contracts.canonical')
local cell_identity = require('scripts.mom.domain.cell.identity')
local cell_predicate = require('scripts.mom.domain.cell.predicate')
local cell_selection = require('scripts.mom.compiler.cell_selection')
local selection_plan = require('scripts.mom.compiler.selection_plan')
local compat_registry = require('scripts.mom.compat.registry')
local bootstrap = require('scripts.mom.compiler.bootstrap_config')
local config_sources = require('scripts.mom.compiler.config_sources')
local extension_registry = require('scripts.mom.compiler.extension_registry')
local plain_data = require('scripts.mom.contracts.plain_data')
local source_action_contract = require('scripts.mom.compiler.source_action_contract')
local source_ir = require('scripts.mom.compiler.source_ir')
local dor = require('scripts.mom.compat.dor.translator')
local sss = require('scripts.mom.compat.sss.translator')
local strings = require('scripts.mom.common.strings')

local M = {}

local test_support = require('pure.test_support')
local expect = test_support.expect

local function sourceHash(document)
  return assert(canonical.hash(document, {path = 'compatSource'}))
end

local function expectValid(document, adapterId)
  local valid, errors = source_action_contract.validateSourceActions(document, {adapterId = adapterId})
  expect(valid == true, 'invalid ' .. tostring(adapterId) .. ' source output: '
    .. table.concat(errors or {}, ' | '))
  expect(plain_data.validate(document) == true, 'compat source output is not plain data')
end

local function sssConfig()
  return {
    replace_names = {'Balmora'},
    exterior_cells = {{x = -3, y = -2}},
    replace_meshes = {
      ['f\\Furn_DE_signpost_02.nif'] = 'f\\Furn_De_Tapestry_04.NIF',
      ['f\\Furn_DE_signpost_04.nif'] = 'f\\Furn_De_Tapestry_03.NIF',
    },
    ignore_records = {'furn_de_signpost_02'},
  }
end

local function dorConfig(targetOne, chanceOne)
  return {
    objectToReplace1 = {
      oldObject = 'misc_de_goblet_08',
      newObjects = {
        newObject2 = {
          newObject = 'misc_com_bottle_05',
          replaceChance = 1,
          excludedCell = {{cellName = 'Balmora, Eight Plates'}},
        },
        newObject1 = {
          newObject = targetOne or 'misc_com_bottle_07',
          replaceChance = chanceOne or 1,
          specificCell = {{cellName = 'Balmora, Eight Plates'}},
        },
      },
    },
  }
end

local function abiAndOwnershipContract()
  expect(compat_registry.idForPath('scripts/mom/compat/dor/translator.lua') == 'dor',
    'compat translator path was not discovered')
  expect(compat_registry.idForPath('scripts/mom/compat/source_contract.lua') == nil,
    'compat support file was treated as a translator')
  expect(compat_registry.idForPath('scripts/mom/compat/dor/loader.lua') == nil,
    'nested compat support file was treated as a translator')

  for _, mod in ipairs({dor, sss}) do
    expect(type(mod.id) == 'string' and mod.id ~= '', 'compat module id missing')
    expect(mod.abiVersion == 1, tostring(mod.id) .. ' ABI version mismatch')
    expect(type(mod.behaviorVersion) == 'number', tostring(mod.id) .. ' behavior version missing')
    expect(type(mod.translateSource) == 'function', tostring(mod.id) .. ' source translation hook missing')
  end
  expect(type(dor.matchesPath) == 'function' and dor.claims == nil,
    'DOR did not declare path-only ownership')
  expect(type(sss.claims) == 'function' and sss.matchesPath == nil,
    'SSS did not declare content-only ownership')

  local registry = assert(extension_registry.build('compat', {
    {path = 'scripts/mom/compat/dor/translator.lua', module = dor},
    {path = 'scripts/mom/compat/sss/translator.lua', module = sss},
  }, {
    supportedAbiVersion = 1,
    requiredMethods = {'translateSource'},
    exclusiveMethods = {'matchesPath', 'claims'},
  }))
  local sssClaim = assert(extension_registry.claim(registry, {
    path = 'scripts/staticSwitcher/data/test.yaml',
    config = sssConfig(),
  }, {method = 'claims'}))
  expect(sssClaim.id == 'sss', 'SSS source was claimed by the wrong translator')
  local dorClaim = assert(extension_registry.claim(
    registry,
    'MWSE/mods/_OR_/_OR_test.lua',
    {method = 'matchesPath'}
  ))
  expect(dorClaim.id == 'dor', 'DOR source was claimed by the wrong translator')
  local unclaimed, errors = extension_registry.claim(registry, {
    path = 'scripts/mom/config/native.yaml',
    config = {version = 0, actions = {}},
  }, {method = 'claims', allowUnclaimed = true})
  expect(unclaimed == nil and errors == nil, 'native source was claimed as compat')

  local dualRegistry, dualErrors = extension_registry.build('compat', {{
    path = 'compat/dual.lua',
    module = {
      id = 'dual',
      abiVersion = 0,
      behaviorVersion = 0,
      matchesPath = function() return false end,
      claims = function() return false end,
      translateSource = function() return nil, false end,
    },
  }}, {
    requiredMethods = {'translateSource'},
    exclusiveMethods = {'matchesPath', 'claims'},
  })
  expect(dualRegistry == nil
      and dualErrors[1].code == 'extension_method_choice_invalid',
    'compat registry accepted two ownership hooks')

  local ownerlessRegistry, ownerlessErrors = extension_registry.build('compat', {{
    path = 'compat/ownerless.lua',
    module = {
      id = 'ownerless',
      abiVersion = 0,
      behaviorVersion = 0,
      translateSource = function() return nil, false end,
    },
  }}, {
    requiredMethods = {'translateSource'},
    exclusiveMethods = {'matchesPath', 'claims'},
  })
  expect(ownerlessRegistry == nil
      and ownerlessErrors[1].code == 'extension_method_choice_invalid',
    'compat registry accepted no ownership hook')
end

local function sourceAdmissionContract()
  local path = 'MWSE/mods/_OR_/_OR_Balmora.lua'
  local actions = assert(dor.translateSource({path = path, config = dorConfig()}))
  local before = sourceHash(actions)
  local mod = {
    id = 'dor', abiVersion = 0, behaviorVersion = 0,
    matchesPath = function(candidate) return candidate == path end,
    load = function() return {} end,
    translateSource = function() return actions, true end,
  }
  local registry = assert(extension_registry.build('compat', {{path = 'compat/dor.lua', module = mod}}))
  local sources = config_sources.fromPaths({path}, registry)
  local input = bootstrap.loadAggregated({configSources = sources}, {
    catalog = {compat = registry},
  })
  local attempt = input.sourceAttempts[1]
  expect(attempt.status == 'resolved' and #attempt.actions == #actions,
    'bootstrap did not admit shared compatibility source actions')
  expect(sourceHash(actions) == before, 'source admission mutated translator output')
  local action = attempt.actions[1]
  expect(action.kind == 'mom-source-action' and action.spec.disableOriginal == true
      and action.priority == actions[1].priority
      and action.conflict.mode == 'durable-exclusive'
      and action.source.adapterId == 'dor' and action.source.file == path
      and table.concat(action.source.path, '/') == table.concat(actions[1].source.path, '/'),
    'shared source admission lost compatibility semantics or provenance')
  local edited = assert(dor.translateSource({path = path, config = dorConfig('misc_com_bottle_10', 0.5)}))
  expect(action.diagnosticId == edited[1].diagnosticId,
    'compatibility payload edit changed the diagnostic label')
  local target = action.spec.attach[1][3]
  actions[1].spec.attach[1][3] = 'mutated-after-admission'
  actions[1].conflict.mode = 'mutated-after-admission'
  expect(action.spec.attach[1][3] == target and action.conflict.mode == 'durable-exclusive',
    'source admission retained translator-owned mutable data')
end

local function stagedOwnershipContract()
  local calls = {
    pathMatches = 0,
    contentClaims = 0,
    translations = 0,
  }
  local contentMatches = false
  local function document(adapterId, path)
    return {source_ir.sourceActionOwned({attach = {{'*', 'fixture_old', 'fixture_new'}}}, {
      family = 'place_ref', diagnosticId = adapterId .. ':fixture',
      source = {adapterId = adapterId, file = path, path = {'fixture'}},
    })}
  end
  local pathOwned = {
    id = 'path_owned',
    abiVersion = 0,
    behaviorVersion = 0,
    matchesPath = function(path)
      calls.pathMatches = calls.pathMatches + 1
      return path == 'compat/path-owned.lua'
    end,
    load = function()
      return {}, nil
    end,
    translateSource = function(source)
      calls.translations = calls.translations + 1
      return document('path_owned', source.path), true
    end,
  }
  local contentOwned = {
    id = 'content_owned',
    abiVersion = 0,
    behaviorVersion = 0,
    claims = function()
      calls.contentClaims = calls.contentClaims + 1
      return contentMatches
    end,
    translateSource = function(source)
      calls.translations = calls.translations + 1
      return document('content_owned', source.path), true
    end,
  }
  local registry = assert(extension_registry.build('compat', {
    {path = 'compat/content_owned.lua', module = contentOwned},
    {path = 'compat/path_owned.lua', module = pathOwned},
  }, {
    requiredMethods = {'translateSource'},
    exclusiveMethods = {'matchesPath', 'claims'},
  }))

  local sources = config_sources.fromPaths({'compat/path-owned.lua'}, registry)
  expect(#sources == 1 and sources[1].compat == true
      and type(sources[1].compatClaim) == 'table',
    'config discovery did not carry the selected compatibility entry')
  local preliminaryAdapterId, adapterError =
    config_sources.adapterId(sources[1], registry)
  local rawConfig, loadError = config_sources.loadRaw(sources[1], registry)
  local translated, handled, err, adapterId = config_sources.translateSource(
    sources[1], rawConfig, registry)
  expect(translated ~= nil and handled == true and err == nil
      and adapterId == 'path_owned'
      and preliminaryAdapterId == 'path_owned' and adapterError == nil
      and rawConfig ~= nil and loadError == nil
      and calls.pathMatches == 1
      and calls.contentClaims == 1
      and calls.translations == 1,
    'staged compatibility ownership repeated or changed path/content claims')

  contentMatches = true
  local ambiguous, ambiguousHandled, ambiguousError =
    config_sources.translateSource(sources[1], rawConfig, registry)
  expect(ambiguous == nil and ambiguousHandled == false
      and ambiguousError
      and ambiguousError.kind == 'extension_source_ambiguous'
      and calls.pathMatches == 1,
    'staged path/content ownership lost ambiguity diagnostics')

  local noPathClaim, pathError = compat_registry.pathClaim(
    'compat/content-owned.yaml', registry)
  expect(noPathClaim == nil and pathError == nil,
    'content-owned compatibility source acquired path ownership')
  local contentDocument, contentHandled, contentError, contentAdapterId =
    compat_registry.translateSource({
      path = 'compat/content-owned.yaml',
      config = {},
    }, registry, noPathClaim)
  expect(contentDocument ~= nil and contentHandled == true
      and contentError == nil and contentAdapterId == 'content_owned'
      and calls.pathMatches == 2,
    'content-owned compatibility source was not selected in the content stage')
end

local function sssTranslationContract()
  local source = {
    path = 'scripts/staticSwitcher/data/Balmora.yaml',
    config = sssConfig(),
  }
  local first, translated, err = sss.translateSource(source)
  expect(first ~= nil and translated == true and err == nil, 'SSS source translation failed')
  local second = assert(sss.translateSource(source))
  expectValid(first, 'sss')
  expect(sourceHash(first) == sourceHash(second), 'SSS translation is nondeterministic')
  expect(sourceHash(first) == 'mom64:98d53bfe49327f7e',
    'unchanged legacy SSS source lowering changed its saved semantic input')

  local action = first[1]
  expect(action.diagnosticId == source.path .. '#compat:sss:sss:replace_meshes',
    'SSS diagnostic label changed')
  expect(action.spec.previsit == true, 'SSS exterior source did not request previsit')
  expect(action.spec.attach[1][2]:match('^meshes/'), 'SSS source mesh was not normalized')
  expect(action.spec.attach[1][3]:match('^meshes/'), 'SSS target mesh was not normalized')
  expect(action.spec.filters[1][1] == 'exclude', 'SSS ignore list was not preserved')
end

local function sssScopeIndex()
  local index = {entries = {}, byKey = {}, byId = {}, byName = {},
    byDisplayName = {}, byExteriorWorldspace = {['sys::default'] = {}},
    byRegion = {['sys::default'] = {}}, byWorldspace = {['sys::default'] = {}}}
  local coords = {}
  for mask = 0, 7 do
    local named = mask % 2 == 1
    local inRegion = math.floor(mask / 2) % 2 == 1
    local explicit = mask >= 4
    local entry = assert(cell_identity.fromSignature({
      id = (named and 'Balmora ' or 'Elsewhere ') .. mask,
      isExterior = true, gridX = mask, gridY = 0,
      region = inRegion and 'Ashlands Region' or 'West Gash',
    }))
    entry.nameLower = entry.idLower
    index.entries[#index.entries + 1] = entry
    index.byKey[entry.key] = entry
    index.byId[entry.idLower] = {entry}
    index.byName[entry.idLower] = {entry}
    index.byDisplayName[entry.idLower] = {entry}
    index.byExteriorWorldspace['sys::default'][entry.packedCellKey] = {entry}
    local regions = index.byRegion['sys::default']
    regions[entry.regionKey] = regions[entry.regionKey] or {}
    regions[entry.regionKey][#regions[entry.regionKey] + 1] = entry
    index.byWorldspace['sys::default'][#index.byWorldspace['sys::default'] + 1] = entry
    if explicit then coords[#coords + 1] = {x = mask, y = 0} end
  end
  return index, coords
end

local function sssScopeUnionContract()
  local index, coords = sssScopeIndex()
  for mask = 0, 7 do
    local names = mask % 2 == 1
    local regions = math.floor(mask / 2) % 2 == 1
    local grids = mask >= 4
    local config = {replace_meshes = {['f/old.nif'] = 'f/new.nif'}}
    if names then config.replace_names = {'Balmora'} end
    if regions then config.replace_regions = {'ASHLANDS REGION'} end
    if grids then config.exterior_cells = plain_data.cloneValidated(coords) end
    expect(sss.claims({config = config}), 'SSS did not claim static scope combination ' .. mask)
    local actions = assert(sss.translateSource({path = 'scope.yaml', config = config}))
    expectValid(actions, 'sss')
    local selections = {}
    local previsit = {}
    for i = 1, #actions do
      local spec = actions[i].spec
      local selection = assert(cell_selection.compile(spec.attach[1][1], 'scope', {cellIndex = index}))
      selections[#selections + 1] = selection
      if spec.previsit then
        for _, cell in ipairs(cell_selection.previsitEntries(selection) or {}) do
          local key = assert(cell_identity.exteriorKey(cell.worldspaceKey, cell.gridX, cell.gridY))
          previsit[key] = true
        end
      end
    end
    for candidate = 0, 7 do
      local cell = index.entries[candidate + 1]
      local expected = mask == 0
        or (names and candidate % 2 == 1)
        or (regions and math.floor(candidate / 2) % 2 == 1)
        or (grids and candidate >= 4)
      local matches = 0
      for _, selection in ipairs(selections) do
        if cell_predicate.matches(selection.predicate, cell) then matches = matches + 1 end
      end
      expect(matches == (expected and 1 or 0),
        'SSS scope union narrowed, widened or duplicated candidate ' .. candidate .. ' for scope ' .. mask)
      expect((previsit[cell.key] == true) == (grids and candidate >= 4),
        'SSS coordinate/region overlap lost previsit or broadened it for scope ' .. mask)
    end
  end
  local empty = assert(sss.translateSource({path = 'empty_scope.yaml', config = {
    replace_meshes = {['f/old.nif'] = 'f/new.nif'},
    replace_names = {}, replace_regions = {}, exterior_cells = {},
  }}))
  expect(#empty == 1 and empty[1].spec.attach[1][1] == '*'
      and empty[1].spec.previsit == nil,
    'valid empty static scopes did not remain global without previsit')
  local unknown = assert(sss.translateSource({path = 'unknown_region.yaml', config = {
    replace_meshes = {['f/old.nif'] = 'f/new.nif'},
    replace_regions = {'Unknown Region'},
  }}))
  local selection, errors = cell_selection.compile(unknown[1].spec.attach[1][1], 'unknown', {cellIndex = index})
  expect(selection == nil and errors[1]:find('zero cells', 1, true),
    'unknown SSS region fell back to global selection')
end

local function sssStrictStaticContract()
  local invalid = {
    function(c) c.replace_names = 'Balmora' end,
    function(c) c.replace_names = {name = 'Balmora'} end,
    function(c) c.replace_names = {'Balmora', [3] = 'Missing index'} end,
    function(c) c.replace_names = {false} end,
    function(c) c.replace_names = {''} end,
    function(c) c.replace_regions = {region = 'Ashlands'} end,
    function(c) c.replace_regions = {1} end,
    function(c) c.exterior_cells = {{x = '0', y = 0}} end,
    function(c) c.exterior_cells = {{x = 0 / 0, y = 0}} end,
    function(c) c.exterior_cells = {{x = math.huge, y = 0}} end,
    function(c) c.exterior_cells = {{x = 0.5, y = 0}} end,
    function(c) c.exterior_cells = {{x = 0, y = 0, unexpected = true}} end,
    function(c) c.ignore_records = {record = 'rat'} end,
    function(c) c.ignore_records = {true} end,
    function(c) c.instances = {} end,
    function(c) c.once = false end,
    function(c) c.priority = 'cleanup' end,
    function(c) c.priority = 1 end,
    function(c) c.require_content = {'NeverDropThisScope.esp'} end,
    function(c) c.log_name = {} end,
    function(c) c.replace_meshes = {['f/old.nif'] = false} end,
    function(c) c.replace_meshes = {[''] = 'f/new.nif'} end,
    function(c) c.replace_meshes = 'f/new.nif' end,
    function(c) c.replace_meshes = {} end,
  }
  for i, change in ipairs(invalid) do
    local config = {replace_meshes = {['f/old.nif'] = 'f/new.nif'}}
    change(config)
    expect(sss.claims({config = config}), 'malformed static source was not claimed: ' .. i)
    local actions, handled, err = sss.translateSource({path = 'bad.yaml', config = config})
    expect(actions == nil and handled == true and err and err.kind == 'invalid-sss-config',
      'malformed scope or unsupported semantics was silently imported: ' .. i)
  end
  for _, field in ipairs({'variants', 'actions'}) do
    local config = {replace_meshes = {}, [field] = {}}
    expect(not sss.claims({config = config}), 'native declaration was claimed as SSS')
  end
  local config = {replace_meshes = {['f/old.nif'] = 'f/new.nif'}, priority = 'standard', log_name = 'Example'}
  expect(sss.translateSource({path = 'standard.yaml', config = config}) ~= nil,
    'standard priority or diagnostic log name was rejected')
end

local function sssEmptyPartitionsContract()
  local index = sssScopeIndex()
  local configs = {
    -- Every region cell is an explicit grid: the region-other partition is empty.
    {replace_regions = {'Ashlands Region'}, exterior_cells = {
      {x = 2, y = 0}, {x = 3, y = 0}, {x = 6, y = 0}, {x = 7, y = 0},
    }},
    -- An absent region must not invalidate valid name/grid arms or become all cells.
    {replace_regions = {'Unknown Region'}, replace_names = {'Balmora'}},
    {replace_regions = {'Unknown Region'}, exterior_cells = {{x = 0, y = 0}}},
    {replace_regions = {'Unknown Region'}},
  }
  local expectedSkips = {2, 1, 2, 1}
  for i, config in ipairs(configs) do
    config.replace_meshes = {['f/old.nif'] = 'f/new.nif'}
    local document = assert(sss.translateSource({path = 'empty_partition.yaml', config = config}))
    expectValid(document, 'sss')
    local skipped = 0
    for j, action in ipairs(document) do
      expect(action.allowEmptyCellSelection == true,
        'new SSS partition did not request internal empty-selection handling')
      local node = {id = 'partition-' .. j, source = action.source,
        candidateTypes = {Static = true},
        allowEmptyCellSelection = action.allowEmptyCellSelection}
      local status, _, errors = selection_plan.compile(node, {
        cell = action.spec.attach[1][1],
      }, {cellIndex = index}, {scope = 'ref'})
      expect(status == 'ok' or status == 'skip',
        'valid empty SSS partition rejected other scope arms: ' .. table.concat(errors or {}, ' | '))
      if status == 'skip' then skipped = skipped + 1 end
    end
    expect(skipped == expectedSkips[i], 'empty SSS partitions were not omitted conservatively for '
      .. i .. ': expected ' .. expectedSkips[i] .. ', got ' .. skipped)
  end
  local legacy = assert(sss.translateSource({path = 'legacy.yaml', config = sssConfig()}))
  expect(legacy[1].allowEmptyCellSelection == nil,
    'legacy SSS translation changed its empty-cell compilation policy')
  local status = selection_plan.compile({id = 'native', candidateTypes = {Static = true}}, {
    cell = {region = 'Unknown Region'},
  }, {cellIndex = index}, {scope = 'ref'})
  expect(status == 'error', 'internal SSS partition policy weakened native zero-cell errors')
end

local function sssMeshAliasContract()
  local config = {replace_meshes = {
    ['F\\Old.NIF'] = 'F\\New.NIF',
    ['meshes/f/old.nif'] = 'meshes/f/new.nif',
  }}
  local actions = assert(sss.translateSource({path = 'aliases.yaml', config = config}))
  expect(#actions[1].spec.attach == 1, 'equivalent mesh aliases caused duplicate replacements')
  config.replace_meshes['meshes/f/old.nif'] = 'f/other.nif'
  local bad, handled, err = sss.translateSource({path = 'aliases.yaml', config = config})
  expect(bad == nil and handled and err.message:find('conflicting replacements', 1, true),
    'conflicting normalized mesh aliases were accepted')
  -- Assets are resolved later by the ordinary family compiler, not discarded
  -- or guessed by the translator. Their scope must survive unchanged.
  local missing = assert(sss.translateSource({path = 'missing.yaml', config = {
    replace_regions = {'Ashlands Region'},
    replace_meshes = {['missing/source.nif'] = 'missing/replacement.nif'},
  }}))
  expect(missing[1].spec.attach[1][1].region[1] == 'Ashlands Region'
      and missing[1].spec.attach[1][3] == 'meshes/missing/replacement.nif',
    'missing assets were dropped or their scope widened during translation')
end

local function identitiesByPath(document)
  local out = {}
  for i = 1, #document do
    local action = document[i]
    out[table.concat(action.source.path, '/')] = action.diagnosticId
  end
  return out
end

local function dorTranslationContract()
  local source = {
    path = 'MWSE/mods/_OR_/_OR_Balmora.lua',
    config = dorConfig(),
  }
  local first, translated, err = dor.translateSource(source)
  expect(first ~= nil and translated == true and err == nil, 'DOR source translation failed')
  local second = assert(dor.translateSource(source))
  expectValid(first, 'dor')
  expect(sourceHash(first) == sourceHash(second), 'DOR translation is nondeterministic')
  expect(#first == 2, 'DOR candidates were not preserved as stable source actions')
  for i = 1, #first do
    local action = first[i]
    expect(type(action.priority) == 'number', 'managed DOR priority is not explicit')
    expect(action.conflict and action.conflict.mode == 'durable-exclusive',
      'managed DOR conflict is not explicit')
  end

  local edited = assert(dor.translateSource({
    path = source.path,
    config = dorConfig('misc_com_bottle_10', 0.5),
  }))
  expectValid(edited, 'dor')
  local beforeIds = identitiesByPath(first)
  local afterIds = identitiesByPath(edited)
  for path, identity in pairs(beforeIds) do
    expect(afterIds[path] == identity, 'DOR payload edit changed structural identity for ' .. tostring(path))
  end
  expect(sourceHash(first) ~= sourceHash(edited), 'DOR semantic edit did not change source content')

  local detached = assert(plain_data.detach(first))
  expect(detached[1].conflict.mode == 'durable-exclusive',
    'DOR semantics were lost across a plain-data boundary')
end

local function dorDualLaneFamilyOrderingContract()
  local spacedHash = strings.hashString('a b')
  local dashedHash = strings.hashString('a-b')
  expect(#spacedHash == 16
      and #dashedHash == 16
      and spacedHash:match('^[0-9a-f]+$') ~= nil
      and dashedHash:match('^[0-9a-f]+$') ~= nil
      and spacedHash ~= dashedHash,
    'DOR family hash did not retain a distinct dual-lane hex key')
  local document = assert(dor.translateSource({
    path = 'MWSE/mods/_OR_/_OR_hash_order.lua',
    config = {
      objectToReplace2 = {
        oldObject = 'A-B',
        newObjects = {
          newObject1 = {
            newObject = 'misc_com_bottle_05',
            replaceChance = 1,
          },
        },
      },
      objectToReplace1 = {
        oldObject = 'A B',
        newObjects = {
          newObject1 = {
            newObject = 'misc_com_bottle_07',
            replaceChance = 1,
          },
        },
      },
    },
  }))
  local expectedFirst = ('a_b_' .. spacedHash) < ('a_b_' .. dashedHash)
      and 'A B' or 'A-B'
  expect(#document == 2
      and document[1].spec.attach[1][2] == expectedFirst,
    'DOR family sorting assumed the removed eight-character hash width')
end

local function diagnosticsContract()
  local badSss, sssTranslated, sssErr = sss.translateSource({
    path = 'scripts/staticSwitcher/data/bad.yaml',
    config = {replace_meshes = {}, exterior_cells = {'bad'}},
  })
  expect(badSss == nil and sssTranslated == true
      and sssErr and sssErr.kind == 'invalid-sss-config',
    'invalid SSS source did not return structured diagnostics')

  local badDor, dorTranslated, dorErr = dor.translateSource({
    path = 'MWSE/mods/_OR_/_OR_bad.lua',
    config = {},
  })
  expect(badDor == nil and dorTranslated == true
      and dorErr and dorErr.kind == 'invalid-dor-config',
    'invalid DOR source did not return structured diagnostics')
end

local function sourceContractStrictness()
  local function sourceAction()
    return source_ir.sourceActionOwned({attach = {{'*', 'old', 'new'}}}, {
      family = 'place_ref', diagnosticId = 'fixture',
      source = {adapterId = 'fixture', file = 'test.yaml', path = {'actions', 1}},
    })
  end
  local result
  local registry = assert(extension_registry.build('compat', {{
    path = 'compat/fixture.lua', module = {
      id = 'fixture', abiVersion = 0, behaviorVersion = 0,
      claims = function() return true end,
      translateSource = function() return result, true end,
    },
  }}))
  local invalid = {
    function(a) a.callback = function() end end,
    function(a) a.family = 'modify_ref' end,
    function(a) a.source.adapterId = 'other' end,
    function(a) a.children = {sourceAction()}; a.children[1].family = 'modify_ref' end,
    function(a) a.spec.actions = {} end,
    function(a) a.children = {[2] = sourceAction()} end,
    function(a) a.spec.chance = 2 end,
    function(a) a.spec.previsit = 'yes' end,
    function(a) a.conflict = setmetatable({}, {}) end,
  }
  for i = 1, #invalid do
    local action = sourceAction()
    invalid[i](action)
    result = {action}
    local actions, translated, err = compat_registry.translateSource({path = 'test.yaml', config = {}}, registry)
    expect(actions == nil and translated == true and err and err.kind == 'compat-source-invalid',
      'invalid shared translator output reached source preparation: ' .. tostring(i))
  end
  for _, value in ipairs({{}, {actions = {sourceAction()}}, {sourceAction(), sourceAction()}}) do
    if #value == 2 then value[2].source = value[1].source end
    result = value
    local actions, translated, err = compat_registry.translateSource({path = 'test.yaml', config = {}}, registry)
    expect(actions == nil and translated == true and err and err.kind == 'compat-source-invalid',
      'empty, legacy-wrapped or shared mutable translator output was accepted')
  end
end

local function sourceMetadataAndChildren()
  local child = source_ir.sourceActionOwned({modify = {enabled = false}, select = {recordId = 'child'}, chance = 0.25}, {
    family = 'modify_ref', diagnosticId = 'fixture:child',
    source = {adapterId = 'fixture', file = 'test.yaml', path = {'actions', 1, 'children', 1}},
  })
  local action = source_ir.sourceActionOwned({attach = {{'*', 'old', 'new'}}, filters = {{'exclude', 'skip'}},
    chance = 0.5, previsit = true}, {
    family = 'place_ref', diagnosticId = 'fixture:parent', priority = -2,
    conflict = {group = 'fixture', mode = 'exclusive'}, children = {child},
    source = {adapterId = 'fixture', file = 'test.yaml', path = {'actions', 1}},
  })
  expectValid({action}, 'fixture')
  local mod = {id = 'fixture', abiVersion = 0, behaviorVersion = 0,
    matchesPath = function() return true end, load = function() return {} end,
    translateSource = function() return {action}, true end}
  local registry = assert(extension_registry.build('compat', {{path = 'compat/fixture.lua', module = mod}}))
  local input = bootstrap.loadAggregated({configSources = config_sources.fromPaths({'test.yaml'}, registry)}, {
    catalog = {compat = registry},
  })
  local admitted = input.sourceAttempts[1].actions[1]
  expect(plain_data.equalValidated(admitted, action) and admitted.children[1] ~= child,
    'shared source admission changed metadata or lost child ownership')
  action.spec.chance, child.spec.modify.enabled = 1, true
  expect(admitted.spec.chance == 0.5 and admitted.children[1].spec.modify.enabled == false,
    'admission did not detach source descendants')
end

local CASES = {
  {'ABI and ownership', abiAndOwnershipContract},
  {'SSS translation', sssTranslationContract},
  {'SSS global and region scope union', sssScopeUnionContract},
  {'SSS strict static validation', sssStrictStaticContract},
  {'SSS empty partition compilation', sssEmptyPartitionsContract},
  {'SSS mesh alias validation', sssMeshAliasContract},
  {'DOR translation', dorTranslationContract},
  {'DOR dual-lane family ordering', dorDualLaneFamilyOrderingContract},
  {'source admission', sourceAdmissionContract},
  {'staged ownership', stagedOwnershipContract},
  {'structured diagnostics', diagnosticsContract},
  {'source contract strictness', sourceContractStrictness},
  {'source metadata and children', sourceMetadataAndChildren},
}

function M.run()
  return test_support.runCases('pure compat', CASES)
end

return M
