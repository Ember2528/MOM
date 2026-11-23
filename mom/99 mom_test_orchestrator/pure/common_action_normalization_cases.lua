local M = {}
local support = require('pure.test_support')
local expect = support.expect
local canonical = require('scripts.mom.contracts.canonical')
local plain = require('scripts.mom.contracts.plain_data')
local normalization = require('scripts.mom.compiler.action_normalization')
local source_ir = require('scripts.mom.compiler.source_ir')
local preprocess = require('scripts.mom.compiler.source_preprocess')
local contract = require('scripts.mom.compiler.source_action_contract')
local replacement = require('scripts.mom.contracts.replacement_choice')
local function normalize(spec)
  local value, err = normalization.spec(spec, 'test')
  expect(value ~= nil, err)
  return value
end
local function choices(spec)
  local source = source_ir.sourceAction(normalize(spec), {diagnosticId = 'shared-choice'})
  local out, errors = preprocess.preprocess(source)
  expect(out, table.concat(errors or {}, ' | '))
  return out
end
function M.run()
  return support.runCases('common action normalization', {
    {'equivalent compact predicates and selectors have equal canonical meaning', function()
      local first = normalize({select = {cell = {}, type = {'static'}}, filters = {'EXCLUDE', 'other'},
        attach = {{{match = '*'}, {recordId = {'source'}, type = {'static'}}, 'new.nif'}}, disableOriginal = true})
      local second = normalize({select = {cell = '*', type = 'Static'}, filters = {{'exclude', 'other'}},
        attach = {{'*', {recordId = 'source', type = 'Static'}, 'new.nif'}}, disableOriginal = true})
      expect(canonical.assertHash(first) == canonical.assertHash(second), 'ordinary syntax retained different promotion meaning')
    end},
    {'ordinary weighted targets compile through generic profiles', function()
      local expr = assert(replacement.normalize({choose = {{'f/A.NIF', 3}, {{recordId = 'Target'}, 1}}, keepWeight = 2}))
      local descriptor = assert(replacement.descriptor(expr))
      expect(canonical.encode(descriptor.profile.default) == canonical.encode({2, 3, 1}), 'weighted Keep/target slots changed')
      expect(descriptor.targets[1].targetKind == 'model_path' and descriptor.targets[1].targetValue == 'meshes/f/a.nif'
        and descriptor.targets[2].targetKind == 'record_id' and descriptor.targets[2].targetValue == 'target', 'target kinds changed')
      local target, result = replacement.constant(expr)
      expect(target == nil and result == 'variable', 'variable weighted pool was folded')
    end},
    {'declared profiles preserve explicit and default Keep semantics', function()
      local expr = assert(replacement.normalize({choose = {{'a.nif', 0}}, profile = {}, keep = 'continue'}))
      local descriptor = assert(replacement.descriptor(expr))
      local target, result = replacement.constant(expr)
      expect(target == nil and result == 'keep' and descriptor.keepStops == false, 'profile default Keep became a target')
      expr = assert(replacement.normalize({choose = {{'a.nif', 0}}, profile = {default = {0, 1}}}))
      target, result = replacement.constant(expr)
      expect(result == 'target' and target.targetValue == 'meshes/a.nif', 'constant profile did not prove its target')
    end},
    {'edited expressions cannot reuse a stale constant-choice proof', function()
      local expr = {choose = {{'a.nif', 1}, {'b.nif', 0}}}
      local target, result = replacement.constant(expr)
      expect(result == 'target' and target.targetValue == 'meshes/a.nif', 'initial constant choice was not recognized')
      expr.choose[2][2] = 1
      target, result = replacement.constant(expr)
      expect(target == nil and result == 'variable', 'edited weights retained stale promotion eligibility')
      expr.choose[2][2] = -1
      local descriptor, err = replacement.descriptor(expr)
      expect(descriptor == nil and type(err) == 'string', 'edited invalid weights reused accepted cached profile')
    end},
    {'native and explicitly typed targets normalize identically', function()
      local simple = assert(replacement.normalize({choose = {{'f/a.nif', 1}}}))
      local explicit = assert(replacement.normalize({choose = {{{model = 'F/A.NIF'}, 1}}}))
      expect(canonical.assertHash(simple) == canonical.assertHash(explicit), 'target spelling changed semantic expression')
      local record = assert(replacement.normalize({choose = {{{recordId = 'literal.nif'}, 1}}}))
      expect(assert(replacement.descriptor(record)).targets[1].targetKind == 'record_id', 'explicit record was reinterpreted as mesh')
    end},
    {'ordinary attachment rows retain rule ordering and exclusions', function()
      local out = choices({select = {type = 'Static'}, disableOriginal = true, filters = {'exclude', 'global'}, attach = {
        {'*', {recordId = 'source'}, {choose = {{'a.nif', 1}}, order = 'record', keep = 'stop'}, {'exclude', 'local'}},
        {'*', 'f/source.nif', {choose = {{'b.nif', 1}}, order = 'mesh', keep = 'continue'}},
      }})
      expect(#out == 1 and out[1].input.payloadKind == 'choice', 'ordinary choice rows bypassed common preparation')
      local rules = out[1].input.payload.rules
      expect(#rules == 2 and rules[1].sourceKind == 'record_id' and rules[2].sourceKind == 'model_path'
        and rules[1].keepStops and not rules[2].keepStops and rules[1].orderKey == 'record'
        and rules[1].ignoreRecords.global and rules[1].ignoreRecords['local']
        and rules[2].ignoreRecords.global and not rules[2].ignoreRecords['local'], 'choice routing or exclusion scope changed')
    end},
    {'choice source queries preserve bare action record restrictions', function()
      local out = choices({select = {recordId = {'selected'}}, disableOriginal = true,
        attach = {{'*', 'f/source.nif', {choose = {{'a.nif', 1}}}}}})
      local query = out[1].input.select.query
      expect(query and #query.recordId == 1 and query.recordId[1] == 'selected'
        and out[1].input.select.recordId == nil, 'bare record selection was dropped while preparing choices')
      out = choices({select = {type = 'Static', recordId = 'selected'}, disableOriginal = true,
        attach = {{'*', 'f/source.nif', {choose = {{'a.nif', 1}}}}}})
      query = out[1].input.select.query
      expect(query.type[1] == 'Static' and query.recordId[1] == 'selected', 'query type or record intersection was lost')
    end},
    {'choice normalization does not mutate authored sources', function()
      local raw = {attach = {{'*', 'source', {choose = {{'A.NIF', 1}}, profile = {default = {0, 1}}}}}, disableOriginal = true}
      local before = canonical.assertHash(raw)
      local normalized = normalize(raw)
      normalized.attach[1][3].profile.default[2] = 4
      expect(canonical.assertHash(raw) == before, 'normalization retained authored aliases')
    end},
    {'invalid choice and prepared source bypasses fail admission', function()
      for _, expr in ipairs({{choose = {}}, {choose = {{'x', -1}}}, {choose = {{'x', 0}}},
          {choose = {{'x', 1}}, keep = 'sometimes'}, {choose = {{{recordId = 'a', model = 'b'}, 1}}},
          {choose = {{'x', 1}}, profile = {default = {1}}}}) do
        local value, err = replacement.normalize(expr, 'bad')
        expect(value == nil and type(err) == 'string', 'invalid expression was admitted')
      end
      local valid, errors = contract.validateSourceActions({{kind = 'mom-source-action', family = 'place_ref',
        diagnosticId = 'bypass', familyInput = {verb = 'attach', payload = {}, payloadKind = 'choice'}, children = {},
        source = {adapterId = 'test', file = 'test.yaml', path = {}}}}, {adapterId = 'test'})
      expect(not valid and table.concat(errors or {}, '|'):find('familyInput', 1, true), 'prepared payload bypass remained public')
    end},
    {'absolute choices admit declarative sampling fields without evaluating them', function()
      local spec = {key = 'placement', place = {{'Balmora', {
        choose = {{{recordId = 'record_a'}, 2}, {'record_b', 1}}, seed = -8, key = 'placement', salt = 'alternative'},
        {0, 0, 0}, {yaw = 0}}}}
      expect(contract.validate(spec, 'placement') == nil, 'ordinary placement sampling could not reach common admission')
      spec.place[1][2].choose[1][2] = 0
      expect(type(contract.validate(spec, 'placement')) == 'string', 'invalid absolute choice weight passed admission')
    end},
    {'absolute choices normalize record spelling before declaration sampling', function()
      local raw = {place = {{'Balmora', {choose = {{{recordId = 'FIRST'}, 2}, {'Second', 1}}, seed = -8},
        {0, 0, 0}, {yaw = 0}}}}
      local before = canonical.assertHash(raw)
      local first = normalize(raw)
      local second = normalize({place = {{'Balmora', {choose = {{'first', 2}, {{recordId = 'second'}, 1}}, seed = -8},
        {0, 0, 0}, {yaw = 0}}}})
      expect(canonical.assertHash(first) == canonical.assertHash(second)
        and first.place[1][2].choose[1][1] == 'first', 'record spelling changed the canonical absolute pool')
      expect(canonical.assertHash(raw) == before, 'absolute choice normalization mutated the authored pool')
    end},
  })
end
return M
