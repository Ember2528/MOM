local M = {}
local support = require('pure.test_support')
local expect = support.expect
local frontend = require('scripts.mom.compiler.action_frontend')
local ir = require('scripts.mom.compiler.source_ir')
local canonical = require('scripts.mom.contracts.canonical')
local sampling = require('scripts.mom.domain.variation.stable')
local placements = require('scripts.mom.compat.vfr.placements')
local function native(spec)
  return ir.sourceAction(spec, {family = 'place_ref', diagnosticId = 'native action',
    source = {adapterId = 'native', file = 'native.yaml', variant = 'test', path = {}}})
end
local function normalized(actions, active)
  local attempts, errors = frontend.normalize({{status = 'resolved', path = 'input.yaml', actions = actions}},
    {activeContent = active or {['morrowind.esm'] = true}})
  expect(attempts, errors and table.concat(errors, ' | '))
  return attempts[1].actions
end
local function sampled(spec)
  local unit, draws = sampling.unit, {}
  sampling.unit = function(key, seed, salt)
    draws[#draws + 1] = {key = key, seed = seed, salt = salt}
    return unit(key, seed, salt)
  end
  local ok, result = pcall(normalized, {native(spec)})
  sampling.unit = unit
  expect(ok, result)
  return result, draws
end
function M.run()
  return support.runCases('common action frontend', {
    {'native and VFR placements have equivalent semantic declarations', function()
      local translated = assert(placements.translate({placements = {{id = 'ONE', record = 'tapestry',
        cell = 'Balmora', position = {1, 2, 3}, scale = 0.5}}}, 'foreign.yaml'))
      local direct = native({key = 'vfr:placement:one', targetTypes = {'Static', 'Activator'},
        place = {{{exact = 'Balmora', kind = 'interior'}, 'tapestry', {1, 2, 3},
          {roll = 0, pitch = 0, yaw = 0}}}})
      direct.children = {ir.sourceAction({modify = {scale = {to = 0.5}}}, {
        family = 'modify_ref', diagnosticId = 'scale', source = direct.source})}
      local a, b = normalized(translated)[1], normalized({direct})[1]
      expect(canonical.assertHash(a.spec) == canonical.assertHash(b.spec)
        and a.uniqueSourceKey == b.uniqueSourceKey
        and canonical.assertHash(a.children[1].spec) == canonical.assertHash(b.children[1].spec),
        'foreign origin changed native placement meaning')
    end},
    {'plugin conditions and sampled admission fold before placement', function()
      local result = normalized({native({requires = {'missing.esp'}, place = {}}),
        native({admission = {chance = 0, key = 'never', seed = -4}, place = {}}),
        native({requires = {'Morrowind.esm'}, requiresNot = {'missing.esp'},
          place = {{'Balmora', 'a', {0, 0, 0}, {yaw = 0}}}})})
      expect(#result == 1 and result[1].spec.requires == nil and result[1].spec.admission == nil,
        'common admission depended on source format or leaked into backend options')
    end},
    {'absolute weighted alternatives resolve without record catalogs', function()
      local first = native({key = 'one', place = {{'Balmora', {choose = {
        {{recordId = 'a'}, 1}, {{recordId = 'b'}, 4}}, seed = -9, key = 'chosen'},
        {0, 0, 0}, {yaw = 0}}}})
      local second = native(assert(require('scripts.mom.contracts.plain_data').cloneValidated(first.spec)))
      local a, b = normalized({first})[1], normalized({second})[1]
      expect(type(a.spec.place[1][2]) == 'string' and a.spec.place[1][2] == b.spec.place[1][2],
        'shared seeded placement choice was not stable')
    end},
    {'equivalent native filters and scopes use the same default admission draw', function()
      local a, first = sampled({admission = {chance = 0.5, seed = -7},
        select = {cell = {}, type = {'static'}}, filters = {'EXCLUDE', 'other'},
        attach = {{{match = '*'}, 'source', 'new.nif'}}, disableOriginal = true})
      local b, second = sampled({admission = {chance = 0.5, seed = -7},
        select = {cell = '*', type = 'Static'}, filters = {{'exclude', 'other'}},
        attach = {{'*', 'source', 'new.nif'}}, disableOriginal = true})
      expect(#first == 1 and #second == 1 and first[1].key == second[1].key
        and first[1].salt == 'condition' and second[1].salt == 'condition',
        'equivalent ordinary syntax changed the default admission key')
      expect(#a == #b and (#a == 0 or canonical.assertHash(a[1].spec) == canonical.assertHash(b[1].spec)),
        'equivalent ordinary syntax changed the admission outcome')
    end},
    {'absolute record spellings use the same default admission and alternative draws', function()
      local a, first = sampled({admission = {chance = 1, seed = -7}, place = {{'Balmora',
        {choose = {{'FIRST', 1}, {{recordId = 'Second'}, 3}}, seed = -9}, {0, 0, 0}, {yaw = 0}}}})
      local b, second = sampled({admission = {chance = 1, seed = -7}, place = {{'Balmora',
        {choose = {{{recordId = 'first'}, 1}, {'second', 3}}, seed = -9}, {0, 0, 0}, {yaw = 0}}}})
      expect(#first == 2 and #second == 2, 'absolute alternatives did not use common declaration sampling')
      for index, draw in ipairs(first) do
        expect(draw.key == second[index].key and draw.salt == second[index].salt,
          'record case or wrapper changed a default declaration sampling key')
      end
      expect(first[1].salt == 'condition' and first[2].salt == 'alternative'
        and a[1].spec.place[1][2] == b[1].spec.place[1][2],
        'equivalent absolute alternatives changed their sampled record')
    end},
    {'prepared translator payloads are rejected at the source boundary', function()
      local ok, err = pcall(ir.sourceAction, nil, {family = 'place_ref', diagnosticId = 'bypass',
        familyInput = {verb = 'attach', payloadKind = 'choice', payload = {}}})
      expect(not ok and tostring(err):find('ordinary specs', 1, true),
        'translator could bypass common action semantics')
    end},
    {'guarded appearance choices are rejected at compile normalization', function()
      local action = ir.sourceAction({
        disableOriginal = true,
        attach = {{'*', 'ex_crate', {choose = {{'meshes/a.nif', 1}, {'meshes/b.nif', 1}}}}},
      }, {
        family = 'place_ref',
        diagnosticId = 'guarded choice',
        guardOwner = {rawWhen = {{'time', 'hour', 'gte', 6}}},
        source = {adapterId = 'native', file = 'native.yaml', variant = 'test', path = {}},
      })
      local attempts, errors = frontend.normalize(
        {{status = 'resolved', path = 'input.yaml', actions = {action}}},
        {activeContent = {['morrowind.esm'] = true}}
      )
      expect(attempts == nil and type(errors) == 'table' and #errors == 1
        and errors[1]:find('appearance choice only supports unguarded static actions', 1, true),
        'guarded choice should fail during frontend normalization instead of runtime activation')
    end},
  })
end
return M
