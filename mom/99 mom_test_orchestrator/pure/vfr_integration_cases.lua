-- Exercise the real discovery, admission and compiler pipeline. Engine facts
-- are small injected stores; translators and action compilation stay real.
package.preload['openmw.core'] = package.preload['openmw.core'] or function()
  return {contentFiles = {list = {}}}
end
package.preload['openmw.vfs'] = package.preload['openmw.vfs'] or function() return {} end
package.preload['openmw.markup'] = package.preload['openmw.markup'] or function() return {} end
package.preload['openmw.types'] = package.preload['openmw.types'] or function() return {} end
package.preload['openmw.world'] = package.preload['openmw.world'] or function() return {} end

local bootstrap = require('scripts.mom.compiler.bootstrap_config')
local compiler = require('scripts.mom.compiler.compile_sources')
local catalog_api = require('scripts.mom.compiler.discover_extensions')
local record_index = require('scripts.mom.compiler.record_index')
local cell_index = require('scripts.mom.compiler.cell_index')
local plain_data = require('scripts.mom.contracts.plain_data')
local source_contract = require('scripts.mom.compiler.source_action_contract')
local vfs = require('openmw.vfs')
local markup = require('openmw.markup')
local types = require('openmw.types')
local test_support = require('pure.test_support')
local expect = test_support.expect
local M = {}

local NATIVE = 'scripts/mom/config/native.yaml'
local SSS = 'scripts/staticSwitcher/data/test.yaml'
local DOR = 'MWSE/mods/_OR_/_OR_test.lua'
local VFR = 'scripts/variationframework/plants/data/nested/test.yaml'
local EXAMPLE = 'scripts/variationframework/plants/data/nested/EXAMPLE.yaml'
local RECORD_TYPES = {
  native_source = 'Static', native_target = 'Static', sss_source = 'Static',
  dor_source = 'Static', dor_target = 'Static', vfr_static = 'Static',
  vfr_container = 'Container', vfr_container_target = 'Container',
}

local function documents()
  return {
    [NATIVE] = {version = 0, variants = {default = {actions = {{
      attach = {{'*', 'native_source', 'native_target'}}, disableOriginal = true,
    }}}}},
    [SSS] = {replace_names = {}, replace_meshes = {['c/sss_source.nif'] = 'c/sss_target.nif'}},
    [DOR] = [[return {objectToReplace1={oldObject='dor_source',newObjects={newObject1={newObject='dor_target'}}}}]],
    [VFR] = {
      variants = {['c/vfr_shared.nif'] = {meshes = {'c/vfr_target.nif'}}},
      record_variants = {vfr_container = {records = {'vfr_container_target'}}},
      weights = {default = {0, 1}},
    },
    [EXAMPLE] = {},
  }
end

local function recordContext()
  return {
    modelRecordTypeOrder = {'Static', 'Container'},
    recordExists = function(id, allowed)
      local kind = RECORD_TYPES[tostring(id):lower()]
      if not kind then return false, 'invalid_record_id' end
      if allowed and not allowed[kind] then return false, 'wrong_record_type' end
      return true, nil, kind
    end,
    resolveLiveRefType = function(id) return RECORD_TYPES[tostring(id):lower()] end,
    resolveMeshTypes = function(path)
      if path == 'meshes/c/vfr_shared.nif' then return {Static = {'vfr_static'}, Container = {'vfr_container'}} end
      if path == 'meshes/c/sss_source.nif' then return {Static = {'sss_source'}} end
      return nil, 'unknown_mesh_path'
    end,
  }
end

local function withSources(docs, callback)
  local previous = {paths = vfs.pathsWithPrefix, exists = vfs.fileExists, open = vfs.open,
    yaml = markup.loadYaml, records = record_index.build, cells = cell_index.build, static = types.Static}
  local paths = {
    'scripts/mom/actions/place_ref.lua',
    'scripts/mom/compat/sss/translator.lua', 'scripts/mom/compat/dor/translator.lua',
    'scripts/mom/compat/vfr/translator.lua',
  }
  for path in pairs(docs) do paths[#paths + 1] = path end
  table.sort(paths)
  vfs.pathsWithPrefix = function(prefix)
    local index = 0
    return function()
      while index < #paths do
        index = index + 1
        if paths[index]:sub(1, #prefix) == prefix then return paths[index] end
      end
    end
  end
  vfs.fileExists = function(path) return path:match('%.nif$') ~= nil or docs[path] ~= nil end
  markup.loadYaml = function(path)
    local value = docs[path]
    if type(value) ~= 'table' then error('missing fixture YAML ' .. tostring(path)) end
    return assert(plain_data.detach(value))
  end
  vfs.open = function(path)
    if type(docs[path]) ~= 'string' then return nil end
    return {read = function() return docs[path] end, close = function() end}
  end
  record_index.build = function() return recordContext() end
  cell_index.build = function()
    local entry = {key = 'balmora', id = 'Balmora', idLower = 'balmora', interiorKey = 'balmora',
      nameLower = 'balmora', isExterior = false}
    return {entries = {entry}, byKey = {balmora = entry}, byId = {balmora = {entry}},
      byName = {balmora = {entry}}, byDisplayName = {},
      byExteriorWorldspace = {}, byRegion = {}, byWorldspace = {},
      totalCount = 1, interiorCount = 1, exteriorCount = 0}
  end
  types.Static = {records = {native_target = {id = 'native_target'}}}
  local ok, err = pcall(function()
    local catalog = catalog_api.discover()
    local plan = bootstrap.resolveInputs({}, catalog)
    callback(plan, catalog)
  end)
  vfs.pathsWithPrefix, vfs.fileExists, vfs.open = previous.paths, previous.exists, previous.open
  markup.loadYaml, record_index.build, cell_index.build = previous.yaml, previous.records, previous.cells
  types.Static = previous.static
  if not ok then error(err, 0) end
end

local function compiled(plan, catalog)
  local input = bootstrap.loadAggregated(plan, {catalog = catalog})
  local attempts = assert(plain_data.detach(input.sourceAttempts))
  local result = compiler.compile(input, catalog)
  expect(result.status == 'accepted', 'mixed source compilation rejected: '
    .. tostring(result.fatal and result.fatal.message))
  return result, {sourceAttempts = attempts}
end

local function discoveryAndCompile()
  withSources(documents(), function(plan, catalog)
    expect(#catalog.compat.ids == 3 and catalog.compat.byId.vfr, 'VFR was not discovered beside SSS/DOR')
    expect(#plan.configSources == 5, 'discovery lost native, foreign or nested example sources')
    local result, input = compiled(plan, catalog)
    local counts, choices = {}, {}
    for _, attempt in ipairs(input.sourceAttempts) do
      counts[attempt.adapterId] = (counts[attempt.adapterId] or 0) + #attempt.actions
    end
    for _, id in ipairs(result.manifest.actionIds) do
      local action = result.manifest.actionsById[id]
      if action.program.choiceGroup then choices[#choices + 1] = action end
    end
    expect(counts.native == 1 and counts.sss == 1 and counts.dor == 1 and counts.vfr == 1,
      'shared compiler lost native or foreign source actions')
    expect(#choices == 2 and #result.manifest.actionIds == 5, 'example created executable work')
    for _, action in ipairs(choices) do
      expect(action.program.disableOriginal and action.program.choiceGroup == 'appearance'
          and #action.program.profiles == 1 and plain_data.validate(action.program),
        'choice did not become a validated native placement program with pooled spatial data')
      for _, entry in ipairs(action.program.objects) do
        expect(entry.sourceKeyKind == 'record_id' and #entry.choices >= 1, 'mesh source did not become exact native routing')
        for _, choice in ipairs(entry.choices) do
          expect(choice.profile == nil and choice.profileIndex == 1,
            'choice duplicated its profile or lost the installed pool reference')
        end
        if entry.sourceRecordId == 'vfr_container' then
          expect(#entry.choices == 2 and entry.choices[1].sourceKind == 'record_id'
              and entry.choices[1].keepStops and entry.choices[2].sourceKind == 'model_path',
            'exact-record routing did not precede the overlapping mesh rule')
        end
      end
    end
    expect(input.sourceAttempts[#input.sourceAttempts].status == 'resolved', 'source attempt lost its disposition')
  end)
end

local function emptyExamples()
  withSources({[EXAMPLE] = {}}, function(plan, catalog)
    local result, input = compiled(plan, catalog)
    expect(#input.sourceAttempts == 1 and #input.sourceAttempts[1].actions == 0
        and #result.manifest.actionIds == 0, 'example-only installation was not an intentional no-op')
  end)
end

local function publicFieldsRemainStrict()
  for _, field in ipairs({'familyInput', 'choice', 'choiceGroup', 'profile'}) do
    local docs = documents()
    docs[NATIVE].variants.default.actions[1][field] = {rules = {}}
    withSources(docs, function(plan, catalog)
      local result = compiler.compile(bootstrap.loadAggregated(plan, {catalog = catalog}), catalog)
      expect(result.status == 'rejected' and result.fatal.code == 'source_set_rejected',
        'internal choice field leaked into native public action grammar: ' .. field)
    end)
  end
end

local function oneInvalidSourceRejectsSet()
  local docs = documents()
  docs[VFR].weights.default = {0, 1, 0}
  withSources(docs, function(plan, catalog)
    local input = bootstrap.loadAggregated(plan, {catalog = catalog})
    local result = compiler.compile(input, catalog)
    expect(result.status == 'rejected' and result.manifest == nil and result.diagnostics.summary.sources.failed == 1,
      'invalid foreign profile produced partial activation or hid other sources')
  end)
end

local function strictInternalAdmission()
  local actions = assert(require('scripts.mom.compat.vfr.translator').translateSource({
    path = VFR, config = documents()[VFR],
  }))
  actions[1].familyInput = {verb = 'attach', payloadKind = 'choice', payload = {rules = {}}}
  local valid, errors = source_contract.validateSourceActions(actions, {adapterId = 'vfr'})
  expect(not valid and table.concat(errors or {}, ' | '):find('familyInput', 1, true),
    'translator-supplied prepared payload crossed ordinary source admission')
end

local function canonicalCollisionRejectsSet()
  for _, field in ipairs({'regions', 'interiors', 'climate_overrides'}) do
    local docs = documents()
    local values = field == 'regions' and {REGION = {1, 0}, region = {0, 1}}
      or (field == 'interiors' and {REGION = {w = {1, 0}}, region = {y = 0}}
        or {REGION = {wetness = 10}, region = {wetness = 90}})
    if field == 'climate_overrides' then docs[VFR][field] = values
    else docs[VFR].weights[field] = values end
    withSources(docs, function(plan, catalog)
      local input = bootstrap.loadAggregated(plan, {catalog = catalog})
      local result = compiler.compile(input, catalog)
      local details = table.concat(result.fatal and result.fatal.errors or {}, ' | ')
      expect(result.status == 'rejected' and result.manifest == nil
          and details:find('duplicate normalized name region', 1, true),
        'ambiguous canonical ' .. field .. ' names crossed atomic source admission: ' .. details)
    end)
  end
end

local function duplicatePlacementIds()
  local first = 'scripts/variationframework/placements/data/a.yaml'
  local second = 'scripts/variationframework/placements/data/b.yaml'
  withSources({
    [first] = {placements = {{id = 'global.decoration', record = 'native_target',
      interior = 'Balmora', position = {1, 2, 3}}}},
    [second] = {placements = {{id = 'GLOBAL.DECORATION', record = 'native_target',
      interior = 'Balmora', position = {4, 5, 6}}}},
  }, function(plan, catalog)
    local result = compiler.compile(bootstrap.loadAggregated(plan, {catalog = catalog}), catalog)
    local details = table.concat(result.fatal and result.fatal.errors or {}, ' | ')
    expect(result.status == 'rejected' and result.manifest == nil
        and details:find('duplicate source key', 1, true),
      'two placement files claimed one global ID at different positions: '
        .. tostring(details))
  end)
end

local function compatErrorPolicySkipQuarantinesCompatOnly()
  -- 1. Broken VFR file (translate error) is quarantined under compatErrorPolicy='skip'
  --    while native, SSS, DOR, and valid VFR sources still compile and activate!
  local docs = documents()
  local badVfr = 'scripts/variationframework/placements/data/unsupported_draft.yaml'
  docs[badVfr] = {
    placements = {{
      id = 'draft.one', record_draft = {type = 'Static', template = 'native_target', model = 'x.nif'},
      interior = 'Balmora', position = {1, 2, 3},
    }},
  }
  local badVfrCategory = 'scripts/variationframework/plants/data/bad_weights.yaml'
  docs[badVfrCategory] = {
    variants = {['c/vfr_shared.nif'] = {meshes = {'c/vfr_target.nif'}}},
    weights = {default = {0, 1, 0}}, -- wrong length: fails during translate/compile!
  }
  withSources(docs, function(plan, catalog)
    local input = bootstrap.loadAggregated(plan, {catalog = catalog, compatErrorPolicy = 'skip'})
    local result = compiler.compile(input, catalog)
    expect(result.status == 'accepted' and result.manifest ~= nil,
      'compatErrorPolicy=skip failed to compile remaining valid sources: '
        .. tostring(result.fatal and result.fatal.message))
    expect(#result.manifest.actionIds == 5,
      'compatErrorPolicy=skip dropped valid native/compat actions: got ' .. tostring(#result.manifest.actionIds))
    local skipWarnings = 0
    for _, diag in ipairs(result.diagnostics.summary.diagnostics.samples or {}) do
      if diag.code == 'compat_source_skipped' and diag.severity == 'warn' then
        skipWarnings = skipWarnings + 1
      end
    end
    expect(skipWarnings == 2,
      'expected 2 compat_source_skipped warnings, got ' .. tostring(skipWarnings))
  end)

  -- 2. Duplicate placement key across two compat files: first succeeds, second is quarantined!
  local first = 'scripts/variationframework/placements/data/a_first.yaml'
  local second = 'scripts/variationframework/placements/data/b_second.yaml'
  withSources({
    [NATIVE] = documents()[NATIVE],
    [first] = {placements = {{id = 'dup.id', record = 'native_target', interior = 'Balmora', position = {1, 2, 3}}}},
    [second] = {placements = {{id = 'DUP.ID', record = 'native_target', interior = 'Balmora', position = {4, 5, 6}}}},
  }, function(plan, catalog)
    local input = bootstrap.loadAggregated(plan, {catalog = catalog, compatErrorPolicy = 'skip'})
    local result = compiler.compile(input, catalog)
    expect(result.status == 'accepted' and #result.manifest.actionIds == 2,
      'duplicate compat placement key was not quarantined under compatErrorPolicy=skip: '
        .. tostring(result.fatal and result.fatal.message))
  end)

  -- 3. Native errors remain strictly fatal even when compatErrorPolicy='skip'!
  local badNative = documents()
  badNative[NATIVE].variants.default.actions[1].familyInput = {rules = {}}
  withSources(badNative, function(plan, catalog)
    local input = bootstrap.loadAggregated(plan, {catalog = catalog, compatErrorPolicy = 'skip'})
    local result = compiler.compile(input, catalog)
    expect(result.status == 'rejected' and result.manifest == nil,
      'compatErrorPolicy=skip silenced a fatal native configuration error')
  end)
end

function M.run()
  return test_support.runCases('pure VFR integration', {
    {'mixed source discovery and compile', discoveryAndCompile}, {'example-only no-op', emptyExamples},
    {'public action grammar stays strict', publicFieldsRemainStrict},
    {'source-set activation remains atomic', oneInvalidSourceRejectsSet},
    {'internal source admission is exclusive', strictInternalAdmission},
    {'canonical profile names stay unambiguous', canonicalCollisionRejectsSet},
    {'placement IDs stay unique across files', duplicatePlacementIds},
    {'compatErrorPolicy=skip quarantines compat errors while keeping native atomic', compatErrorPolicySkipQuarantinesCompatOnly},
  })
end

return M
