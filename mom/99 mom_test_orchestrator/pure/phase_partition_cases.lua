local M = {}
package.preload['openmw.core'] = package.preload['openmw.core'] or function() return {contentFiles = {list = {}}} end
local support = require('pure.test_support')
local expect = support.expect
local partition = require('scripts.mom.compiler.phase_partition')
local collect = require('scripts.mom.compiler.source_variant_actions').collect
local canonical = require('scripts.mom.contracts.canonical')
local resolver = require('scripts.mom.compiler.variant_resolver')

local function modelAction()
  return {select = {type = 'Static'}, disableOriginal = true,
    attach = {{'*', 'source', 'meshes/target.nif'}}}
end
local function recordAction()
  return {record = {type = 'Static', id = 'source', patch = {model = 'meshes/target.nif'}}}
end
local function runtimeAction()
  return {select = {cell = 'Balmora'}, modify = {scale = {to = 2}}}
end
local function selected(variant, phase, extra)
  local opts = {phase = phase, sourcePath = 'scripts/mom/config/mixed.yaml', adapterId = 'native'}
  for key, value in pairs(extra or {}) do opts[key] = value end
  return collect('test', variant, opts)
end
local function withContentFiles(files, callback)
  local core = require('openmw.core')
  local previous = core.contentFiles
  core.contentFiles = files
  local ok, result = pcall(callback)
  core.contentFiles = previous
  if not ok then error(result, 0) end
  return result
end
local function contentApi(properties)
  -- Stock LuaJIT can supply the userdata form too; native sandboxes that do
  -- not expose newproxy exercise the same read-only indexing contract.
  local proxy = type(newproxy) == 'function' and newproxy(true) or setmetatable({}, {})
  getmetatable(proxy).__index = properties
  return proxy
end

function M.run()
  return support.runCases('phase partition', {
    {'plugin conditions use live membership over stale list snapshots', function()
      local files = contentApi({list = {'Forbidden.esp'}, has = function(name)
        return name == 'morrowind.esm' or name == 'tribunal.esm'
      end})
      withContentFiles(files, function()
        local config = {version = 0, variants = {
          active = {requires = {'MORROWIND.ESM'}, requiresAny = {'missing.esp', 'Tribunal.esm'},
            requiresNot = {'Forbidden.esp'}, actions = {recordAction(), runtimeAction()}},
          missing = {requires = {'missing.esp'}, actions = {recordAction()}},
          missingAny = {requiresAny = {'missing.esp'}, actions = {recordAction()}},
          excluded = {requiresNot = {'Morrowind.esm'}, actions = {recordAction()}},
        }}
        local loadContext, globalContext = resolver.createContext(), resolver.createContext()
        loadContext.phase, globalContext.phase = 'LOAD', 'GLOBAL'
        local load = assert(resolver.resolve(config, loadContext))
        local global = assert(resolver.resolve(config, globalContext))
        expect(#load.actions == 1 and load.actions[1].family == 'record_content'
          and #global.actions == 1 and global.actions[1].family == 'modify_ref'
          and #load.loadInputs == 1 and #global.loadInputs == 1
          and canonical.assertHash(load.loadInputs) == canonical.assertHash(global.loadInputs),
          'stale content list changed plugin conditions or the LOAD fingerprint')
      end)
    end},
    {'plugin membership does not require an enumerable list', function()
      local files = contentApi({has = function(name) return name == 'installed.esp' end})
      withContentFiles(files, function()
        local active = resolver.createContext().activeContent
        expect(active['installed.esp'] == true and active['absent.esp'] == false,
          'membership-only API was treated as unavailable content')
      end)
      withContentFiles({list = {'INSTALLED.ESP'}}, function()
        expect(resolver.createContext().activeContent['installed.esp'] == true,
          'list-only host lost case-insensitive plugin conditions')
      end)
    end},
    {'unavailable membership cannot silently skip definitions', function()
      withContentFiles({}, function()
        local ok, err = pcall(resolver.createContext)
        expect(not ok and tostring(err):find('active content-file API is unavailable', 1, true),
          'missing content API was treated as an empty load order')
      end)
      withContentFiles({list = {'installed.esp'}, has = function() error('membership unavailable') end}, function()
        local active = resolver.createContext().activeContent
        local ok, err = pcall(function() return active['installed.esp'] end)
        expect(not ok and tostring(err):find('membership unavailable', 1, true),
          'failed authoritative query fell back to a stale snapshot')
      end)
    end},
    {'ordinary equivalent forms promote after normalization', function()
      local normalize = require('scripts.mom.compiler.action_normalization').spec
      local function placed(action)
        local value = assert(normalize(action, 'test'))
        return partition.classify(value)
      end
      local variants = {
        function(a) a.filters = {'exclude', 'other'} end,
        function(a) a.filters = {{'exclude', 'other'}} end,
        function(a) a.attach[1][4] = {'exclude', 'other'} end,
        function(a) a.attach[1][4], a.attach[1][5] = {0, 0, 0}, {'exclude', 'other'} end,
        function(a) a.attach[1][1] = {} end,
        function(a) a.attach[1][1] = {match = '*'} end,
        function(a) a.attach[1][2] = {recordId = {'source'}, type = 'Static'} end,
        function(a) a.select.recordId = {match = '*source*'} end,
        function(a) a.select.mwscript = 'installed_script' end,
        function(a) a.select.type = {'Static', 'Creature'}; a.attach[1][2] = {recordId = 'source', type = 'Static'} end,
      }
      for i, change in ipairs(variants) do
        local action = modelAction(); change(action)
        expect(placed(action) == 'LOAD', 'equivalent intent was not promoted: ' .. i)
      end
    end},
    {'constant ordinary choices share model promotion', function()
      local action = modelAction()
      action.select.type = 'Ingredient'
      action.attach[1][3] = {choose = {{'a.nif', 0}, {'b.nif', 3}}}
      expect(partition.classify(action) == 'LOAD', 'constant item model choice failed definition proof')
      action.attach[1][3] = {choose = {{'a.nif', 1}, {'b.nif', 3}}}
      expect(partition.classify(action) == 'GLOBAL', 'variable choice was promoted')
      action.attach[1][3] = {choose = {{'a.nif', 0}}, keepWeight = 1}
      expect(partition.classify(action) == 'GLOBAL', 'KEEP routing was flattened into a field write')
    end},
    {'reference restrictions retain complete runtime intent', function()
      local untyped = modelAction(); untyped.select.type = nil
      expect(partition.classify(untyped) == 'SPLIT', 'untyped uniform attach did not split across LOAD and GLOBAL')
      local mixed = modelAction(); mixed.select.type = {'Container', 'Static', 'Activator'}
      expect(partition.classify(mixed) == 'SPLIT', 'mixed VFR-style attach did not split across LOAD and GLOBAL')
      local changes = {
        function(a) a.select.type = 'Creature' end,
        function(a) a.select.type = 'Container' end,
        function(a) a.select.cell = 'Balmora' end,
        function(a) a.select.contentFile = 'Morrowind.esm' end,
        function(a) a.filters = {{'upright'}} end,
        function(a) a.chance = 0.5 end,
        function(a) a.previsit = true end,
        function(a) a.conflict = {group = 'runtime-choice'} end,
        function(a) a.attach[1][4] = {0, 0, 1} end,
        function(a) a.attach[1][5] = {} end,
        function(a) a.attach[1][3] = 'another_record' end,
        function(a) a.disableOriginal = false end,
      }
      for i, change in ipairs(changes) do
        local action = modelAction(); change(action)
        expect(partition.classify(action) == 'GLOBAL', 'reference restriction promoted: ' .. i)
      end
      expect(partition.classify(modelAction(), {guarded = true}) == 'GLOBAL', 'guarded leaf promoted')
      expect(partition.classify(modelAction(), {hasChildren = true}) == 'GLOBAL', 'dependent tree split')
      local owner, err = partition.classify(recordAction(), {guarded = true})
      expect(owner == nil and err:find('guarded', 1, true), 'guarded record definition accepted')
      local parent = {spec = modelAction(), children = {{spec = recordAction(), children = {}}}}
      local placed, errors = partition.plan({{status = 'resolved', actions = {parent}}})
      expect(placed == nil and errors[1]:find('children', 1, true), 'nested source definition reached a backend')
    end},
    {'position-specific sources retain reference intent', function()
      for _, source in ipairs({'source, (1, 2, 3)', 'meshes/source.nif, (1, 2, 3)',
          {recordId = 'source, (1, 2, 3)', type = 'Static'}}) do
        local action = modelAction(); action.attach[1][2] = source
        expect(partition.classify(action) == 'GLOBAL', 'keyed position became a definition edit')
      end
    end},
    {'common syntax errors are rejected before backend placement', function()
      local variant = {actions = {modelAction()}}
      variant.actions[1].filters = {'exclude', false}
      expect(selected(variant, 'LOAD') == nil and selected(variant, 'GLOBAL') == nil,
        'one frontend skipped invalid common predicate syntax')
      for _, phase in ipairs({'LOAD', 'GLOBAL'}) do
        expect(selected({actions = {{record = {}, modify = {}}}}, phase) == nil, 'multiple meanings accepted')
        expect(selected({guards = {{actions = {recordAction()}}}}, phase) == nil, 'guarded content accepted')
        expect(selected({actions = {{unknown = {}}}}, phase) == nil, 'unknown verb accepted')
      end
    end},
    {'selection preserves original diagnostic coordinates', function()
      local actions = assert(selected({actions = {recordAction(), runtimeAction(), runtimeAction()}}, 'GLOBAL'))
      expect(#actions == 2 and actions[1].source.path[2] == 2 and actions[2].source.path[2] == 3,
        'common placement renumbered surviving source actions')
    end},
    {'placement is derived from semantics without catalog access', function()
      local action = modelAction()
      local catalogs = {setmetatable({}, {__index = function() error('catalog queried') end}),
        {source = {model = 'other.nif'}}}
      for _, content in ipairs(catalogs) do
        expect(partition.classify(action, {content = content}) == 'LOAD', 'catalog changed semantic proof')
      end
    end},
    {'interfering runtime replacements stay in one execution layer', function()
      local normalize = require('scripts.mom.compiler.action_normalization').spec
      local function node(spec, extra)
        local out = {spec = assert(normalize(spec, 'group')), diagnosticId = 'group', children = {}}
        for key, value in pairs(extra or {}) do out[key] = value end
        return out
      end
      local first = node({select = {type = 'Static'}, disableOriginal = true,
        attach = {{'*', 'a.nif', 'b.nif'}}})
      local runtime = node({select = {type = 'Static'}, disableOriginal = true,
        attach = {{'Balmora', 'a.nif', 'c.nif'}}})
      local inputs = {{status = 'resolved', path = 'one', actions = {first}},
        {status = 'resolved', path = 'two', actions = {runtime}}}
      local plan = assert(partition.plan(inputs))
      expect(plan.owners[first] == 'GLOBAL' and plan.owners[runtime] == 'GLOBAL',
        'promotion erased a scoped replacement source')
      local before = canonical.assertHash(plan.loadInputs)
      runtime.spec.attach[1][3] = 'changed.nif'
      expect(before ~= canonical.assertHash(assert(partition.plan(inputs)).loadInputs),
        'runtime promotion dependency escaped the restart fingerprint')
      inputs[2] = nil
      expect(assert(partition.plan(inputs)).owners[first] == 'LOAD', 'removed competitor kept stale placement')
    end},
    {'model writes cannot add another runtime selector population', function()
      local first = {spec = {select = {type = 'Static'}, disableOriginal = true,
        attach = {{'*', 'a.nif', 'b.nif'}}}, children = {}}
      local runtime = {spec = {modify = {{'Balmora', 'b.nif', {scale = 2}}}}, children = {}}
      local plan = assert(partition.plan({{status = 'resolved', actions = {first, runtime}}}))
      expect(plan.owners[first] == 'GLOBAL', 'LOAD added former A records to a runtime B selector')
    end},
    {'disjoint type domains and identities do not block promotion', function()
      local first = {spec = modelAction(), children = {}}
      local runtime = {spec = {select = {type = 'Creature'}, disableOriginal = true,
        attach = {{'Balmora', 'source', 'c.nif'}}}, children = {}}
      local plan = assert(partition.plan({{status = 'resolved', actions = {first, runtime}}}))
      expect(plan.owners[first] == 'LOAD', 'different record domains were conflated')
      local before = canonical.assertHash(plan.loadInputs)
      runtime.spec.attach[1][3] = 'changed.nif'
      expect(before == canonical.assertHash(assert(partition.plan({{status = 'resolved', actions = {first, runtime}}})).loadInputs),
        'unrelated runtime edit forced a content restart')
    end},
    {'record-ID runtime edits compose with promoted visual definitions', function()
      local first = {spec = modelAction(), children = {}}
      local runtime = {spec = {modify = {{'Balmora', 'source', {scale = 2}}}}, children = {}}
      local plan = assert(partition.plan({{status = 'resolved', actions = {first, runtime}}}))
      expect(plan.owners[first] == 'LOAD' and plan.owners[runtime] == 'GLOBAL',
        'identity-preserving model edit was confused with a mesh-query dependency')
    end},
    {'ordered choice competitors preserve routing instead of becoming field conflicts', function()
      local first = {spec = modelAction(), children = {}}
      local other = {spec = modelAction(), children = {}, priority = -1}
      other.spec.attach[1][3] = {choose = {{'c.nif', 1}}, order = 'later'}
      local plan = assert(partition.plan({{status = 'resolved', actions = {first, other}}}))
      expect(plan.owners[first] == 'GLOBAL' and plan.owners[other] == 'GLOBAL',
        'ordered choice competition was converted to independent field writes')
    end},
    {'known no-op model actions do not create false interference', function()
      local first = {spec = {select = {type = 'Static'}, disableOriginal = true,
        attach = {{'*', 'a.nif', 'a.nif'}}}, children = {}}
      local runtime = {spec = {attach = {{'Balmora', 'some_record', 'c.nif'}}, disableOriginal = true}, children = {}}
      local plan = assert(partition.plan({{status = 'resolved', actions = {first, runtime}}}))
      expect(plan.owners[first] == 'LOAD', 'unchanged definition was treated as a catalog mutation')
    end},
    {'composition policy participates in LOAD authority', function()
      local node = {spec = {leveled = {type = 'CreatureLevelledList', id = 'animals',
        operations = {{op = 'merge_by_id', entries = {{id = 'rat', level = 9}}}}}}, children = {},
        compositionOrder = {1, -10, 'a.yaml', 1}}
      local inputs = {{status = 'resolved', actions = {node}}}
      local before = canonical.assertHash(assert(partition.plan(inputs)).loadInputs)
      node.compositionOrder[2] = 10
      expect(before ~= canonical.assertHash(assert(partition.plan(inputs)).loadInputs),
        'changed list composition priority escaped the LOAD fingerprint')
    end},
    {'diagnostic renaming does not change promotion authority', function()
      local node = {spec = modelAction(), diagnosticId = 'old', source = {file = 'old.yaml'}, children = {}}
      local inputs = {{status = 'resolved', path = 'old.yaml', actions = {node}}}
      local before = canonical.assertHash(assert(partition.plan(inputs)).loadInputs)
      node.diagnosticId, node.source.file, inputs[1].path = 'new', 'new.yaml', 'new.yaml'
      expect(before == canonical.assertHash(assert(partition.plan(inputs)).loadInputs),
        'diagnostic coordinates changed execution authority')
    end},
    {'catalog-exact interference prevents unrelated runtime rules from demoting LOAD writes', function()
      local sss = {spec = {disableOriginal = true,
        attach = {{'*', 'meshes/flora_tree.nif', 'meshes/flora_tree_new.nif'}}}, children = {}}
      local unrelatedRuntime = {spec = {disableOriginal = true,
        attach = {{'Balmora', 'furn_crate_01', 'meshes/crate_alt.nif'}}}, children = {}}
      local overlappingRuntime = {spec = {disableOriginal = true,
        attach = {{'Balmora', 'flora_tree_01', 'meshes/tree_alt.nif'}}}, children = {}}
      local content = {
        statics = {records = {
          flora_tree_01 = {id = 'flora_tree_01', model = 'meshes/flora_tree.nif'},
          furn_crate_01 = {id = 'furn_crate_01', model = 'meshes/furn_crate_01.nif'},
        }},
      }
      -- Without catalog, record_id + mesh_path conservatively demotes.
      local conservative = assert(partition.plan({{status = 'resolved', actions = {sss, unrelatedRuntime}}}))
      expect(conservative.owners[sss] == 'GLOBAL', 'pure conservative plan unexpectedly promoted')
      -- With real openmw.content catalog, unrelated furn_crate_01 does NOT demote sss!
      local exact = assert(partition.plan({{status = 'resolved', actions = {sss, unrelatedRuntime}}}, {content = content}))
      expect(exact.owners[sss] == 'SPLIT' and exact.owners[unrelatedRuntime] == 'GLOBAL',
        'unrelated runtime rule falsely demoted catalog-exact LOAD split')
      -- Decision receipt round-trips identically to GLOBAL without re-reading catalog.
      local replayed = assert(partition.applyDecisions({{status = 'resolved', actions = {sss, unrelatedRuntime}}}, exact.encodedDecisions))
      expect(replayed.owners[sss] == 'SPLIT' and replayed.owners[unrelatedRuntime] == 'GLOBAL'
        and canonical.assertHash(exact.loadInputs) == canonical.assertHash(replayed.loadInputs),
        'LOAD decision receipt did not replay identically in GLOBAL')
      -- A runtime rule targeting a record that ACTUALLY has flora_tree.nif MUST demote sss!
      local demoted = assert(partition.plan({{status = 'resolved', actions = {sss, overlappingRuntime}}}, {content = content}))
      expect(demoted.owners[sss] == 'GLOBAL', 'overlapping runtime rule failed to demote LOAD split')
    end},
    {'compact 2-bit decision codec round trips and rejects malformed input', function()
      local sample = {'load', 'split', 'global', 'split', 'load'}
      local encoded = assert(partition.encodeDecisions(sample))
      local decoded = assert(partition.decodeDecisions(encoded))
      expect(#decoded == #sample, 'decision count mismatch')
      for i = 1, #sample do expect(decoded[i] == sample[i], 'decision mismatch at ' .. i) end
      expect(partition.encodeDecisions({}) == '', 'empty decision list not empty string')
      expect(#assert(partition.decodeDecisions('')) == 0, 'empty receipt decode failed')
      expect(partition.decodeDecisions('1:f') == nil, 'invalid decision code accepted')
      expect(partition.decodeDecisions('1:4') == nil, 'non-zero trailing padding accepted')
      expect(partition.decodeDecisions('2:00') == nil, 'wrong hex length accepted')
    end},
  })
end
return M
