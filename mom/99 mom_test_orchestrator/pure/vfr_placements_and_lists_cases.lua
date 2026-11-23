local support = require('pure.test_support')
local expect = support.expect
local placements = require('scripts.mom.compat.vfr.placements')
local lists = require('scripts.mom.compat.vfr.leveled_creatures')
local translator = require('scripts.mom.compat.vfr.translator')
local frontend = require('scripts.mom.compiler.action_frontend')
local backend = require('scripts.mom.compiler.content.compile')
local plain = require('scripts.mom.contracts.plain_data')
local M = {}
local P = 'scripts/variationframework/placements/data/decor.yaml'
local L = 'scripts/variationframework/leveled_creatures/data/'
local ACTIVE = {['morrowind.esm'] = true}
local function placement(id)
  return {id = id or 'example.decoration', record = 'deco', interior = 'Balmora, Eight Plates',
    position = {x = 11, y = 22, z = 33}, rotation = {x = 12, y = 24, z = 48}, scale = 1.25}
end
local function normalized(actions, path, active)
  local attempts, errors = frontend.normalize({{status = 'resolved', path = path or P, actions = actions}},
    {activeContent = active or ACTIVE})
  expect(attempts, errors and table.concat(errors, ' | '))
  return attempts[1].actions
end
local function translated(raw)
  local actions, err = placements.translate(raw, P)
  expect(actions, tostring(err))
  return actions
end
local function exactPlacement()
  local actions = translated({placements = {placement()}})
  expect(#actions == 1, 'decoration did not translate')
  local action, tuple = actions[1], actions[1].spec.place[1]
  expect(action.familyInput == nil and tuple[1].exact == 'Balmora, Eight Plates'
      and tuple[1].kind == 'interior' and tuple[2] == 'deco'
      and tuple[3][1] == 11 and tuple[3][3] == 33
      and tuple[4].roll == 12 and tuple[4].pitch == 24 and tuple[4].yaw == 48,
    'ordinary placement changed the exact position or XYZ rotation')
  expect(action.source.path[2] == 'example.decoration'
      and action.spec.key == 'vfr:placement:example.decoration'
      and action.spec.targetTypes[1] == 'Static' and action.spec.targetTypes[2] == 'Activator'
      and action.children[1].spec.modify.scale.to == 1.25,
    'declarative identity, target policy or scale child was lost')
  local exterior = placement('exterior')
  exterior.interior, exterior.exterior = nil, true
  exterior.position = {-8193, -1, 100}
  actions = translated({placements = {exterior}})
  expect(actions[1].spec.place[1][1].coords[1] == -2
      and actions[1].spec.place[1][1].coords[2] == -1, 'negative exterior coordinates rounded incorrectly')
  exterior.exterior = {x = -1, y = -1}
  local rejected, reason = placements.translate({placements = {exterior}}, P)
  expect(not rejected and reason:find('does not lie', 1, true), 'mismatched exterior silently relocated')
end
local function deterministicChoices()
  local base = placement('case.insensitive')
  base.record = nil
  base.alternatives = {{record = 'deco', weight = 1}, {record = 'banner', weight = 2}}
  base.conditions = {chance = 0.75, require_content = 'MORROWIND.ESM', exclude_content = {'absent.esp'}}
  local declarations = translated({seed = 24680, placements = {base}})
  expect(declarations[1].spec.place[1][2].choose[1][1].recordId == 'deco'
      and declarations[1].spec.admission.requires[1] == 'morrowind.esm',
    'translator sampled or discarded ordinary admission/choice intent')
  local canonical = normalized(declarations)
  expect(#canonical == 1 and canonical[1].spec.place[1][2] == 'banner',
    'shared placement sampling differs from VFR ID/seed/salt vector')
  local negative = normalized(translated({seed = -17, placements = {base}}))
  expect(#negative == 1 and negative[1].spec.place[1][2] == 'deco', 'negative seed modulo changed')
  for i = 1, 10 do
    base.id = i % 2 == 0 and 'CASE.INSENSITIVE' or 'case.insensitive'
    local actual = normalized(translated({seed = 24680, placements = {base}}))
    expect(#actual == 1 and actual[1].spec.place[1][2] == 'banner', 'sample changed with count or ID case')
  end
  base.id, base.conditions.chance = 'example.1', 0.3
  expect(#normalized(translated({seed = 24680, placements = {base}})) == 0, 'condition salt changed')
  base.conditions.chance = 0
  expect(#normalized(translated({placements = {base}})) == 0, 'zero chance placement was admitted')
  base.conditions.chance, base.conditions.require_content = 1, 'missing.esp'
  expect(#normalized(translated({placements = {base}})) == 0, 'missing required content was admitted')
  base.conditions.require_content, base.conditions.exclude_content = nil, 'morrowind.esm'
  expect(#normalized(translated({placements = {base}})) == 0, 'excluded content was admitted')
end
local function unsupportedPlacements()
  local changes = {
    function(p) p.unrecognized = true end,
    function(p) p.conditions = {unrecognized = true} end,
    function(p) p.position.unrecognized = true end,
    function(p) p.record = nil p.alternatives = {{record = 'deco', weight = 1, unrecognized = true}} end,
    function(p) p.spawn = true end,
    function(p) p.record = nil p.record_draft = {type = 'Static', template = 'deco', model = 'x.nif'} end,
    function(p) p.scale = 0 end,
    function(p) p.rotation.x = 0 / 0 end,
    function(p) p.conditions = {chance = 2} end,
    function(p) p.record = nil p.alternatives = {{record = 'deco', weight = -1}} end,
  }
  for _, change in ipairs(changes) do
    local p = placement(); change(p)
    local actions, reason = placements.translate({placements = {p}}, P)
    expect(actions == nil and type(reason) == 'string' and reason:find(p.id, 1, true),
      'unsupported foreign syntax escaped a source diagnostic')
  end
  local p = placement()
  expect(placements.translate({placements = {p, placement(p.id:upper())}}, P) == nil,
    'duplicate ID was admitted')
  p.enabled, p.record = false, 'missing'
  expect(#translated({placements = {p}}) == 0, 'disabled placement was retained')
  p.enabled, p.record = true, 'cup'
  local ordinary = translated({placements = {p}})
  expect(ordinary[1].spec.place[1][2] == 'cup' and ordinary[1].spec.targetTypes[1] == 'Static',
    'translator decided record capabilities before common resolution')
end
local function injection(level, creature)
  return {list = 'TARGET', add = {{id = creature or 'a', level = level}}}
end
local function listFixture(modules, unsupported, active, native)
  local original = {id = 'target', creatures = {{id = 'a', level = 1}, {id = 'a', level = 7}, {id = 'base', level = 3}},
    chanceNone = 0.53, calculateFromAllLevels = true}
  local records = {target = original}
  local attempts, messages, paths = {}, {}, {}
  for path in pairs(modules) do paths[#paths + 1] = path end
  table.sort(paths, function(a, b) return a:lower() < b:lower() end)
  if native then attempts[#attempts + 1] = {status = 'resolved', path = 'native.yaml', actions = native} end
  for _, path in ipairs(paths) do
    local actions, handled, err, diagnostics = translator.translateSource({path = path, config = modules[path]})
    expect(handled and not err and actions, 'list translation failed')
    for _, message in ipairs(diagnostics or {}) do messages[#messages + 1] = message end
    attempts[#attempts + 1] = {status = 'resolved', path = path, actions = actions}
  end
  local normalizedAttempts, errors = frontend.normalize(attempts, {activeContent = active or ACTIVE})
  expect(normalizedAttempts, errors and table.concat(errors, ' | '))
  local plan
  plan, errors = backend.compile({sourceAttempts = normalizedAttempts},
    {content = unsupported and {} or {levelledCreatures = {records = records}}})
  expect(plan, errors and table.concat(errors, ' | '))
  return plan, original, messages, normalizedAttempts
end
local function listMerge()
  local plan, original = listFixture({
    [L .. 'z.yaml'] = {priority = 0, injections = {injection(3), injection(4, 'new')}},
    [L .. 'a.yaml'] = {priority = 0, injections = {injection(2)}},
    [L .. 'priority.yaml'] = {priority = 1, injections = {injection(6)}},
    [L .. 'EXAMPLE.yaml'] = {priority = 999, injections = {injection(99)}},
  })
  local entries = plan.writes[1].patch.creatures
  expect(#entries == 4 and entries[1].level == 6 and entries[2].level == 6
      and entries[3].id == 'base' and entries[3].level == 3 and entries[4].id == 'new'
      and original.chanceNone == 0.53 and original.calculateFromAllLevels == true
      and original.creatures[1].level == 1, 'shared list merge changed order, weighting or unrelated facts')
end
local function listValidation()
  local plan, _, diagnostics = listFixture({
    [L .. 'required.yaml'] = {require_content = 'missing.esp', injections = {injection(100)}},
    [L .. 'excluded.yaml'] = {exclude_content = 'MORROWIND.ESM', injections = {injection(101)}},
    [L .. 'disabled.yaml'] = {enabled = false, injections = {injection(102)}},
    [L .. 'good.yaml'] = {require_content = {'MORROWIND.ESM'}, injections = {
      {list = 'target', add = {{id = 'a', level = 9}, {id = 'bad', level = 65536}}},
      injection(8, 'good'), {list = 'missing', add = {{id = 'a', level = 5}}},
    }},
    [L .. 'unknown.yaml'] = {unrecognized = true, injections = {injection(103)}},
  })
  local entries = plan.writes[1].patch.creatures
  expect(entries[1].level == 1 and entries[4].id == 'good' and #diagnostics == 2,
    'invalid rule partially applied, inactive module entered plan or syntax diagnostics disappeared')
  local unsupported = listFixture({[L .. 'good.yaml'] = {injections = {injection(5)}}}, true)
  expect(#unsupported.writes == 0, 'optional missing list store failed or produced a write')
  expect(lists.validate({injections = {}, require_content = {[2] = 'x'}}, 'test') == nil,
    'sparse content condition was accepted')
end
local function nativeListComposition()
  local ir = require('scripts.mom.compiler.source_ir')
  local native = {ir.sourceAction({leveled = {type = 'CreatureLevelledList', id = 'target', operations = {
    {op = 'append', entries = {{id = 'wolf', level = 2}}},
    {op = 'merge_by_id', entries = {{id = 'a', level = 4}}},
    {op = 'remove', match = {id = 'base'}}}}},
    {family = 'leveled_content', diagnosticId = 'native', source = {adapterId = 'native', file = 'native.yaml'}})}
  local plan, original = listFixture({[L .. 'good.yaml'] = {priority = -10,
    injections = {injection(9), injection(4, 'new')}}}, false, nil, native)
  local entries = plan.writes[1].patch.creatures
  expect(#entries == 4 and entries[1].level == 9 and entries[2].level == 9
      and entries[3].id == 'wolf' and entries[4].id == 'new' and #original.creatures == 3,
    'negative foreign priority reordered native edits or coalesced duplicates')
end
local function declarativeConditions()
  local actions = assert(lists.translate({require_content = 'MORROWIND.ESM', exclude_content = 'forbidden.esp',
    injections = {injection(9, 'good')}}, L .. 'good.yaml'))
  expect(actions[1].familyInput == nil and actions[1].spec.admission.requires[1] == 'morrowind.esm'
      and actions[1].spec.admission.requiresNot[1] == 'forbidden.esp'
      and actions[1].spec.onMissingTarget == 'skip', 'list adapter sampled conditions or lost shared target policy')
  local before = assert(plain.detach(actions))
  normalized(actions, L .. 'good.yaml', ACTIVE)
  expect(before[1].spec.leveled.operations[1].entries[1].id == 'good', 'source action ownership failed')
end
function M.run()
  return support.runCases('VFR placements and leveled lists', {
    {'exact decorations produce ordinary actions without host facts', exactPlacement},
    {'shared seeded placement conditions and alternatives', deterministicChoices},
    {'foreign syntax rejects unsupported lifecycle without catalog decisions', unsupportedPlacements},
    {'leveled additions preserve native list semantics', listMerge},
    {'list syntax skip and common optional-target policies', listValidation},
    {'VFR additions compose with native list edits', nativeListComposition},
    {'LOAD plugin gates are ordinary declarative admission', declarativeConditions},
  })
end
return M
