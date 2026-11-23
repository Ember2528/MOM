local category = require('scripts.mom.compat.vfr.category')
local translator = require('scripts.mom.compat.vfr.translator')
local spatial = require('scripts.mom.domain.variation.spatial')
local canonical = require('scripts.mom.contracts.canonical')
local plain_data = require('scripts.mom.contracts.plain_data')
local source_contract = require('scripts.mom.compiler.source_action_contract')
local test_support = require('pure.test_support')
local expect = test_support.expect
local M = {}

local PATH = 'scripts/variationframework/plants/data/nested/test.yaml'

local function module()
  return {
    variants = {['F\\Example.NIF'] = {meshes = {'Example/A.NIF', 'meshes/example/b.nif'}}},
    weights = {default = {0, 1, 0}},
  }
end

local function resolved(raw, name)
  local value, err = category.parse(raw, category.forName(name or 'plants'), PATH)
  if not value then return nil, err end
  -- Format translation remains declarative; the common spatial semantic
  -- builder owns validation and profile compilation.
  for _, rule in ipairs(value.rules) do
    local profile
    profile, err = spatial.compile(rule.profile, {variantCount = #rule.targets})
    if not profile then return nil, err end
    rule.profile = profile
  end
  return value
end
local function parse(raw, name)
  local value, err = resolved(raw, name)
  expect(value ~= nil, tostring(err))
  return value
end

local function rejected(raw, message)
  local value, err = resolved(raw, 'plants')
  expect(value == nil and type(err) == 'string' and err:find(message, 1, true),
    'expected ' .. message .. ', got ' .. tostring(err))
end

local function ownership()
  for _, name in ipairs({'plants', 'containers', 'clutter', 'banners', 'placements', 'leveled_creatures'}) do
    expect(translator.matchesPath('Scripts\\VariationFramework\\' .. name .. '\\data\\a\\b.YAML'), 'did not claim nested ' .. name)
  end
  for _, path in ipairs({'scripts/mom/config/test.yaml', 'scripts/staticSwitcher/data/test.yaml',
    'scripts/variationframework/unknown/data/test.yaml',
    'scripts/variationframework/plants/database/test.yaml',
    'scripts/variationframework/plants/data/test.lua'}) do
    expect(not translator.matchesPath(path), 'incorrectly claimed ' .. path)
  end
  expect(#translator.configDirs == 6 and translator.id == 'vfr' and translator.abiVersion == 1,
    'VFR extension discovery descriptor changed')
  expect(translator.sourcePolicy('scripts/variationframework/leveled_creatures/data/bad.yaml').onLoadError == 'skip'
      and translator.sourcePolicy(PATH) == nil and translator.sourcePolicy('unknown.yaml') == nil,
    'list parse skip policy broadened other sources or was hidden from common admission')
end

local function examples()
  for _, path in ipairs({'Scripts/VariationFramework/plants/data/EXAMPLE.yaml',
    'scripts/variationframework/plants/data/vfr/example.YML',
    'scripts/variationframework/plants/data/vfr/EXAMPLE.optional.yaml',
    'scripts/variationframework/placements/data/EXAMPLE.yaml'}) do
    local actions, translated, err = translator.translateSource({path = path, config = false})
    expect(type(actions) == 'table' and #actions == 0 and translated and not err,
      'shipped example was parsed or imported')
  end
  local actions, translated = translator.translateSource({path = 'scripts/mom/config/native.yaml', config = module()})
  expect(actions == nil and translated == false, 'VFR claimed native source')
end

local function defaults()
  local plants = parse(module())
  local rule = plants.rules[1]
  expect(rule.sourceKey == 'meshes/f/example.nif' and rule.sourceKind == 'model_path', 'source model was not normalized')
  expect(rule.targets[1].targetValue == 'meshes/example/a.nif' and rule.targets[2].targetValue == 'meshes/example/b.nif',
    'target models were not normalized or retained in authored order')
  expect(rule.sourceTypes.Container and rule.sourceTypes.Static and rule.sourceTypes.Activator
      and not rule.sourceTypes.Ingredient and rule.keepStops == false, 'plant category kinds/routing changed')
  expect(rule.profile.seed == 0 and rule.profile.cluster.scale == 3072
      and rule.profile.cluster.detail == 1024 and rule.profile.cluster.detailWeight == 0.30
      and rule.profile.cluster.jitter == 0.22, 'plant clustering defaults changed')
  expect(plants.priority == -1, 'default module unexpectedly superseded ordinary replacements')
  local containers = parse(module(), 'containers').rules[1]
  expect(containers.sourceTypes.Container and not containers.sourceTypes.Static, 'container kinds widened')
  local clutter = parse(module(), 'clutter')
  expect(clutter.rules[1].profile.cluster.jitter == 0.5 and clutter.transferContents == false,
    'clutter clustering or implicit transfer policy changed')
  expect(parse(module(), 'banners').rules[1].profile.cluster.jitter == 1, 'banner clustering changed')
  local raw = module()
  raw.weights = nil
  local profile = parse(raw).rules[1].profile
  expect(#profile.default == 3 and profile.default[1] == 1 and profile.default[2] == 0 and profile.default[3] == 0,
    'missing default did not keep the original')
end

local function recordRouting()
  local raw = module()
  raw.kinds = {'Container'}
  raw.record_variants = {['Flora_Exact'] = {records = {'FLORA_A', 'flora_b'}}}
  raw.ignore_records = {'Flora_Scripted', 'FLORA_EXACT'}
  raw.supersede_static_switcher = true
  local parsed = parse(raw)
  local exact, mesh = parsed.rules[1], parsed.rules[2]
  expect(exact.sourceKind == 'record_id' and exact.sourceKey == 'flora_exact' and exact.keepStops,
    'record rule did not retain authoritative keep semantics')
  expect(exact.targets[1].targetKind == 'record_id' and exact.targets[1].targetValue == 'flora_a', 'record target changed')
  expect(not mesh.keepStops and exact.ignoreRecords.flora_scripted and exact.ignoreRecords.flora_exact,
    'mesh fallback or normalized exclusions changed')
  expect(exact.sourceTypes.Container and not exact.sourceTypes.Static and parsed.priority == 1,
    'kind override or replacement priority changed')
  expect(exact.profile ~= mesh.profile and canonical.assertHash(exact.profile) == canonical.assertHash(mesh.profile)
      and exact.orderKey:sub(1, 2) == '1/' and exact.orderKey:find('/record_id/', 1, true),
    'module profile changed between sources or category ordering changed')
  expect(plain_data.validate(parsed) == true, 'translated rules are not plain data')
end

local function completeProfile()
  local raw = module()
  raw.seed = 19.9
  raw.clustering = {scale = 0, detail = -1, detail_weight = 0.4, jitter = 0.6}
  raw.weights = {
    default = {1, 0, 0}, interior_default = {0, 1, 0},
    regions = {['Mixed Region'] = {0, 0, 1}},
    cells = {{x = -1, y = 2, w = {0, 1, 0}}},
    points = {{x = 8190, y = 8190, r = 12, w = {0, 0, 1}}},
    interiors = {['Borrowed'] = {x = 2, y = -3, region = 'Mixed Region'},
      ['Pinned'] = {w = {0, 1, 0}}, ['Latitude'] = -20},
    latitude = {{y = -10, w = {1, 0, 0}}, {y = 10, w = {0, 1, 0}}},
    longitude = {{x = 0, w = {1, 0, 0}}},
    latitude_offset = {{x = 0, by = 4}}, longitude_offset = {{y = 0, by = -2}},
    wetness = {{at = 40, w = {0, 1, 0}}}, warmth = {{at = 50, w = {0, 0, 1}}},
    snow = {{at = 20, w = {1, 0, 0}}}, ash = {{at = 30, w = {0, 1, 0}}},
  }
  raw.climate_overrides = {['Mixed Region'] = {wetness = 45, warmth = 60, snow = 0, ash = 10}}
  local profile = parse(raw).rules[1].profile
  local native = assert(spatial.compile({seed = 19.9,
    cluster = {scale = 3072, detail = 1024, detailWeight = 0.4, jitter = 0.6},
    default = {1, 0, 0}, interiorDefault = {0, 1, 0},
    regions = {['Mixed Region'] = {0, 0, 1}},
    cells = {{x = -1, y = 2, weights = {0, 1, 0}}},
    points = {{x = 8190, y = 8190, radius = 12, weights = {0, 0, 1}}},
    interiors = {Borrowed = {x = 2, y = -3, region = 'Mixed Region'},
      Pinned = {weights = {0, 1, 0}}, Latitude = {y = -20}},
    gradients = {
      {axis = 'y', anchors = {{at = -10, weights = {1, 0, 0}}, {at = 10, weights = {0, 1, 0}}},
        offsetAxis = 'x', offsets = {{at = 0, value = 4}}},
      {axis = 'x', anchors = {{at = 0, weights = {1, 0, 0}}},
        offsetAxis = 'y', offsets = {{at = 0, value = -2}}},
      {axis = 'wetness', anchors = {{at = 40, weights = {0, 1, 0}}}},
      {axis = 'warmth', anchors = {{at = 50, weights = {0, 0, 1}}}},
      {axis = 'snow', anchors = {{at = 20, weights = {1, 0, 0}}}},
      {axis = 'ash', anchors = {{at = 30, weights = {0, 1, 0}}}},
    },
    climateOverrides = {['Mixed Region'] = {wetness = 45, warmth = 60, snow = 0, ash = 10}},
  }, {variantCount = 2}))
  expect(canonical.assertHash(profile) == canonical.assertHash(native), 'VFR and native spatial programs differ')
  expect(profile.seed == 19 and profile.cluster.scale == 3072 and profile.cluster.detail == 1024,
    'seed flooring or invalid cluster scale fallback changed')
  expect(#profile.gradients == 6 and profile.gradients[1].anchors[1].at == 10,
    'gradient compilation lost axes or descending ordering')
  expect(profile.pointBuckets['0,0'] and profile.pointBuckets['1,1'], 'cross-cell point lost a bucket')
  expect(profile.interiors.borrowed.region == 'mixed region' and profile.interiors.latitude.y == -20,
    'interior climate/latitude borrowing changed')
  expect(profile.climateOverrides['mixed region'].snow == 0 and profile.regions['mixed region'][3] == 1,
    'climate override or region weights changed')
end

local function noMutation()
  local raw = module()
  raw.ignore_records = {'Ignored'}
  raw.climate_overrides = {REGION = {wetness = 30}}
  local before = canonical.assertHash(raw)
  local value = parse(raw)
  expect(canonical.assertHash(raw) == before, 'translation mutated foreign input')
  raw.variants['F\\Example.NIF'].meshes[1] = 'changed'
  raw.weights.default[2] = 9
  raw.ignore_records[1] = 'changed'
  raw.climate_overrides.REGION.wetness = 90
  local rule = value.rules[1]
  expect(rule.targets[1].targetValue == 'meshes/example/a.nif' and rule.profile.default[2] == 1
      and rule.ignoreRecords.ignored and rule.profile.climateOverrides.region.wetness == 30,
    'normalized program retained mutable foreign tables')
end

local function sourceShape()
  local actions, translated, err = translator.translateSource({path = PATH, config = module()})
  expect(translated and not err and #actions == 1, 'category did not translate to one source action')
  local action = actions[1]
  expect(action.familyInput == nil and action.family == 'place_ref' and type(action.spec.attach) == 'table'
      and action.spec.disableOriginal and type(action.spec.attach[1][3].choose) == 'table'
      and action.spec.attach[1][3].profile.default[2] == 1 and action.source.adapterId == 'vfr'
      and action.source.file == PATH, 'native source input or provenance changed')
  local valid, errors = source_contract.validateSourceActions(actions, {adapterId = 'vfr'})
  expect(valid, 'native source admission rejected VFR output: ' .. table.concat(errors or {}, ' | '))
  expect(plain_data.validate(actions) == true, 'translator output is not plain data')
end

local function malformed()
  local raw = module()
  raw.weights.default = {0, 1}
  rejected(raw, 'expected 3 weights')
  raw = module(); raw.weights.default[2] = 0 / 0
  rejected(raw, 'finite')
  raw = module(); raw.weights.cells = {{x = 1.5, y = 0, w = {1, 0, 0}}}
  rejected(raw, 'integer cell coordinates')
  raw = module(); raw.weights.points = {{x = 0, y = 0, r = 0, w = {1, 0, 0}}}
  rejected(raw, 'positive finite radius')
  raw = module(); raw.weights.latitude = {{y = 1, w = {1, 0, 0}}, {y = 1, w = {0, 1, 0}}}
  rejected(raw, 'duplicate gradient anchor')
  raw = module(); raw.variants.other = {records = {'one'}}
  rejected(raw, 'same number of variants')
  raw = module(); raw.variants['f/example.nif'] = {meshes = {'one.nif', 'two.nif'}}
  rejected(raw, 'duplicate normalized source')
  raw = module(); raw.variants['F\\Example.NIF'].records = {'one', 'two'}
  rejected(raw, 'choose meshes or records')
  raw = module(); raw.kinds = {'Door'}
  rejected(raw, 'unknown kind')
  raw = module(); raw.kinds = false
  rejected(raw, 'expected array')
  raw = module(); raw.weights.interiors = {room = {}}
  rejected(raw, 'weights, coordinates or region')
end

local function unsupported()
  local raw = module(); raw.kinds = {'Ingredient'}
  expect(parse(raw).rules[1].sourceTypes.Ingredient,
    'format adapter rejected a type before common promotion/capability analysis')
  raw = module(); raw.transfer_contents = false
  local declared = parse(raw)
  expect(declared.transferContents == false and declared.rules[1].sourceTypes.Container,
    'adapter rejected Container policy before common source resolution')
  local ordinary = assert(translator.translateSource({path = PATH, config = raw}))
  expect(ordinary[1].spec.transferContents == false and ordinary[1].familyInput == nil,
    'foreign transfer intent was discarded instead of emitted as an ordinary action option')
  local defaultContainer = module()
  defaultContainer.kinds = {'Container'}
  local defaultActions = assert(translator.translateSource({
    path = PATH:gsub('/plants/', '/clutter/'), config = defaultContainer}))
  expect(defaultActions[1].spec.transferContents == false
      and defaultActions[1].spec.select.type[1] == 'Container',
    'implicit clutter Container transfer policy disappeared before shared capability validation')
  raw = module(); raw.transfer_contents = 1
  rejected(raw, 'expected boolean')
  raw = module(); raw.variants['F\\Example.NIF'].contents = {'keep', 'ingredient_variant'}
  rejected(raw, 'inventory conversion is not supported')
  raw = module(); raw.kinds = {'Static'}; raw.transfer_contents = false
  raw.variants['F\\Example.NIF'].contents = {'KEEP', ''}
  expect(parse(raw).rules[1].sourceTypes.Static, 'irrelevant transfer opt-out or explicit keep was rejected')
  local actions, claimed, err = translator.translateSource({path = PATH, config = {}})
  expect(actions == nil and claimed and err.kind == 'invalid-vfr-config' and err.message:find(PATH, 1, true),
    'unsupported module did not produce a source-local diagnostic')
end

local function canonicalProfileNames()
  local raw = module()
  raw.weights.regions = {['Bitter Coast Region'] = {1, 0, 0}, ['bitter coast region'] = {0, 1, 0}}
  rejected(raw, 'duplicate normalized name bitter coast region')
  raw = module()
  raw.weights.interiors = {Home = {w = {1, 0, 0}}, home = {region = 'wet'}}
  rejected(raw, 'duplicate normalized name home')
  raw = module()
  raw.climate_overrides = {WET = {wetness = 10}, wet = {wetness = 90}}
  rejected(raw, 'duplicate normalized name wet')
  raw = module()
  raw.weights.cells = {{x = 1, y = 2, w = {1, 0, 0}}, {x = 1, y = 2, w = {0, 1, 0}}}
  expect(parse(raw).rules[1].profile.cells['1,2'][2] == 1,
    'foreign ordered duplicate cells lost their last-entry precedence')
  raw = module(); raw.weights.latitude = false
  rejected(raw, 'dense array')
  raw = module(); raw.weights.latitude_offset = false
  rejected(raw, 'dense array')
end

function M.run()
  return test_support.runCases('pure VFR translator', {
    {'path ownership', ownership}, {'example exclusion', examples}, {'category defaults', defaults},
    {'record routing and exclusions', recordRouting}, {'complete spatial profile', completeProfile},
    {'input ownership', noMutation}, {'native source admission', sourceShape},
    {'malformed source diagnostics', malformed}, {'unsupported capability diagnostics', unsupported},
    {'canonical profile names and ordered cells', canonicalProfileNames},
  })
end

return M
