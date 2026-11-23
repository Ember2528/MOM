package.preload['openmw.vfs'] = package.preload['openmw.vfs'] or function() return {} end
local support = require('pure.test_support')
local expect = support.expect
local compiler = require('scripts.mom.actions.place_ref.choice_compile')
local placementCompiler = require('scripts.mom.actions.place_ref.compile')
local category = require('scripts.mom.compat.vfr.category')
local spatial = require('scripts.mom.domain.variation.spatial')
local plain_data = require('scripts.mom.contracts.plain_data')
local canonical = require('scripts.mom.contracts.canonical')
local M = {}
local function input(raw)
  local parsed, err = category.parse(raw or {
    variants = {['f/source.nif'] = {meshes = {'f/first.nif', 'f/missing.nif', 'f/third.nif'}}},
    record_variants = {source_static = {records = {'target_static', 'missing', 'target_static'}}},
    weights = {default = {0, 1, 0, 0}},
  }, category.forName('plants'), 'fixture.yaml')
  expect(parsed, tostring(err))
  for _, rule in ipairs(parsed.rules) do
    rule.profile = assert(spatial.compile(rule.profile, {variantCount = #rule.targets}))
  end
  return {id = 'variation', verb = 'attach', payloadKind = 'choice', payload = {rules = parsed.rules},
    select = {cell = '*'}, options = {disableOriginal = true}}
end
local function context()
  local types = {source_static = 'Static', second_static = 'Static', source_container = 'Container',
    target_static = 'Static', target_container = 'Container', ignored = 'Static', source_light = 'Light'}
  return {recordCtx = {
    recordExists = function(id) return types[id] ~= nil, 'invalid_record_id' end,
    resolveLiveRefType = function(id) return types[id], types[id] == nil and 'invalid_record_id' or nil end,
    resolveMeshTypes = function(path)
      if path == 'meshes/f/source.nif' then
        return {Static = {'second_static', 'source_static', 'ignored'}, Container = {'source_container'}}
      end
      return nil, 'unknown_mesh_path'
    end,
  }, modelExists = function(path) return path ~= 'meshes/f/missing.nif', path end}
end
local function prepared(value)
  local queries = {recordIds = {}, meshPathTypes = {}}
  local result, errors = compiler.prepare(value or input(), queries, {})
  expect(result, table.concat(errors or {}, ' | '))
  return result, queries
end
local function prepareQueries()
  local value, queries = prepared()
  expect(queries.recordIds.source_static and queries.recordIds.target_static and queries.recordIds.missing
      and queries.meshPathTypes['meshes/f/source.nif'].Container
      and value.payload.rules[1].parsed.sourceKeyKind == 'record_id',
    'choice admission omitted source/target queries or selector facts')
  for _, malformed in ipairs({false, 1, 'bad', {payloadKind = 'choice'},
      {verb = 'attach', payloadKind = 'choice', payload = {rules = {}}}}) do
    local ok, result, errors = pcall(compiler.prepare, malformed, {}, {})
    expect(ok and result == nil and type(errors) == 'table', 'malformed family input escaped structured rejection')
  end
  for _, change in ipairs({
    function(v) v.select = false end,
    function(v) v.payload.rules[1].sourceTypes = {Ingredient = true} end,
    function(v) v.payload.rules[1].profile.default = {1} end,
    function(v) v.payload.rules[1].profile = {default = {0, 1, 0, 0}} end,
    function(v) v.payload.rules[1].targets[1].targetKind = 'unknown' end,
    function(v) v.payload.rules[1].extra = true end,
    function(v) v.options.disableOriginal = false end,
    function(v) v.options.extra = true end,
    function(v) v.payload.extra = true end,
  }) do
    local value = input()
    change(value)
    local ok, result, errors = pcall(compiler.prepare, value, {}, {})
    expect(ok and result == nil and type(errors) == 'table', 'invalid rule was admitted or threw')
  end
end
local function typedChoiceCompilation()
  local spec = input()
  spec.payload.rules[1].ignoreRecords.ignored = true
  spec.payload.rules[2].ignoreRecords.ignored = true
  local outputs, errors = compiler.compile(prepared(spec), context())
  expect(outputs, table.concat(errors or {}, ' | '))
  expect(#outputs == 2 and outputs[1].candidateTypes.Container and outputs[2].candidateTypes.Static,
    'choice source types did not split deterministically')
  local container, static = outputs[1].spec.program, outputs[2].spec.program
  expect(compiler.checkProgram(container) == true and compiler.checkProgram(static) == true,
    'compiler emitted an invalid or aliased native choice program')
  expect(#container.profiles == 1 and #static.profiles == 1
      and container.profiles[1] ~= static.profiles[1], 'identical spatial profiles were not pooled per program')
  expect(container.mode == 'relative' and container.disableOriginal and container.choiceGroup == 'appearance'
      and #container.objects == 1 and container.objects[1].sourceRecordId == 'source_container',
    'container source did not retain the normal placement envelope')
  expect(#static.objects == 2 and static.objects[1].sourceRecordId == 'second_static'
      and static.objects[2].sourceRecordId == 'source_static'
      and #static.objects[2].choices == 2 and static.objects[2].choices[1].sourceKind == 'record_id'
      and static.objects[2].choices[1].keepStops == true
      and static.objects[2].choices[2].sourceKind == 'model_path',
    'source expansion duplicated outputs, ignored IDs, or lost record-first keep semantics')
  local choices = static.objects[2].choices
  expect(choices[1].profile == nil and choices[2].profile == nil
      and choices[1].profileIndex == 1 and choices[2].profileIndex == 1
      and static.objects[1].choices[1].profileIndex == 1,
    'expanded or overlapping source choices duplicated their spatial profile')
  expect(#choices[1].targets == 3 and choices[1].targets[2].unavailable
      and choices[1].targets[3].targetType == 'Static'
      and #choices[2].targets == 3 and choices[2].targets[2].unavailable
      and choices[2].targets[3].targetValue == 'meshes/f/third.nif',
    'missing targets shifted spatial weighted indices')
  local claims = table.concat(outputs[1].claims.keys, ',')
  expect(claims == 'output.existence,ref.enabled,ref.inventory,ref.lock',
    'container choice did not own the full existing transfer claim set')
  expect(#outputs[2].resolvedSelection.exactIds == 2 and outputs[2].directTargets == nil,
    'choice did not produce exact-record discovery facts')
end
local function programAdmission()
  for _, change in ipairs({
    function(p) p.choiceGroup = 'unknown' end,
    function(p) p.objects[1].choices[1].targets[1].targetKind = 'unknown' end,
    function(p) p.profiles[1].default = {1} end,
    function(p) p.profiles = nil end,
    function(p) p.profiles = false end,
    function(p) p.profiles = {} end,
    function(p) p.profiles[2] = assert(plain_data.detach(p.profiles[1])) end,
    function(p) p.profiles[1].default = {1, 0} end,
    function(p) p.objects[1].choices[1].profileIndex = nil end,
    function(p) p.objects[1].choices[1].profileIndex = 0 end,
    function(p) p.objects[1].choices[1].profileIndex = 1.5 end,
    function(p) p.objects[1].choices[1].profileIndex = 2 end,
    function(p) p.objects[1].choices[1].profileIndex = '1' end,
    function(p) p.objects[1].choices[1].profile = assert(plain_data.detach(p.profiles[1])) end,
    function(p) p.objects[1].slot = 'wrong' end,
    function(p) p.objects[1].position.x = 1 end,
    function(p) p.objects[1].extra = true end,
  }) do
    local outputs = assert(compiler.compile(prepared(), context()))
    local program = outputs[2].spec.program
    change(program)
    local errors = {}
    compiler.validateProgram(program, errors, 'invalid', {appendError = function(out, _, message)
      out[#out + 1] = message
    end})
    expect(#errors > 0, 'malformed native choice program crossed validation')
  end
end
local function profilePoolIdentity()
  local spec = input()
  spec.payload.rules[1].profile.default = {1, 0, 0, 0}
  local function compile()
    return assert(compiler.compile(prepared(assert(plain_data.detach(spec))), context()))
  end
  local first, second = compile(), compile()
  local container, static = first[1].spec.program, first[2].spec.program
  expect(#container.profiles == 1 and #static.profiles == 2,
    'different profiles were combined or unused profiles leaked across typed programs')
  expect(static.objects[3].choices[1].profileIndex == 1
      and static.objects[3].choices[2].profileIndex == 2,
    'profile indices did not preserve source-rule encounter order')
  expect(canonical.encode(static) == canonical.encode(second[2].spec.program),
    'identical compilations produced different profile pools')
  spec.payload.rules[1].profile.default[1] = 99
  expect(static.profiles[1].default[1] == 1, 'pooled profile retained source input tables')
  local hash = canonical.hashValidated
  canonical.hashValidated = function() return 'forced-collision' end
  local ok, collided = pcall(compile)
  canonical.hashValidated = hash
  expect(ok and #collided[2].spec.program.profiles == 2,
    'different profiles collided in the canonical identity bucket')
end
local function orphanPoolAdmission()
  local outputs = assert(compiler.compile(prepared(), context()))
  local program = outputs[2].spec.program
  program.choiceGroup = nil
  for _, entry in ipairs(program.objects) do entry.choices = nil end
  local errors = {}
  local H = {
    appendError = function(out, _, message) out[#out + 1] = message end,
    rejectUnknownKeys = function(value, allowed, out)
      for key in pairs(value) do if not allowed[key] then out[#out + 1] = 'unexpected ' .. key end end
    end,
    requireNonEmptyArray = function(value, _, out)
      if type(value) ~= 'table' or #value == 0 then out[#out + 1] = 'expected array' end
    end,
  }
  placementCompiler.validateProgram(program, errors, 'orphan-pool', H)
  expect(table.concat(errors, ' | '):find('profiles require a choiceGroup', 1, true),
    'ordinary place_ref program admitted an orphaned spatial profile pool')
end
local function missingSources()
  local spec = input({variants = {['f/absent.nif'] = {meshes = {'f/first.nif'}}},
    weights = {default = {0, 1}}})
  local outputs, errors = compiler.compile(prepared(spec), context())
  expect(outputs and #outputs == 0 and errors == nil, 'missing source mutated or rejected unrelated compilation')
end
local function preparedChoiceOutputEnvelope()
  local spec = input({variants = {['f/source.nif'] = {meshes = {'f/first.nif'}}},
    weights = {default = {0, 1}}})
  local types, err = placementCompiler.outputTypeEnvelope(prepared(spec), context())
  expect(types and types.Static and types.Container, tostring(err))
  local recordSpec = input({record_variants = {source_static = {meshes = {'f/first.nif'}}},
    weights = {default = {0, 1}}})
  local narrowed, narrowedError = placementCompiler.outputTypeEnvelope(prepared(recordSpec), context())
  expect(narrowed and narrowed.Static and not narrowed.Container, tostring(narrowedError))
  local diagnostics = require('scripts.mom.diagnostics.compile_diagnostics')
  local function compileMixed(withEnvelope)
    local value = prepared()
    local ctx = context()
    local collector = diagnostics.new()
    ctx.diagnosticCollector = collector
    if withEnvelope then
      local mixed, mixedError = placementCompiler.outputTypeEnvelope(value, ctx)
      expect(mixed and mixed.Static and mixed.Container, tostring(mixedError))
    end
    local rows, errors = compiler.compile(value, ctx)
    expect(rows, table.concat(errors or {}, ' | '))
    return rows, diagnostics.forCompile(collector).summary.diagnostics
  end
  local ordinary, ordinaryDiagnostics = compileMixed(false)
  local nested, nestedDiagnostics = compileMixed(true)
  expect(canonical.encode(ordinary) == canonical.encode(nested)
      and ordinaryDiagnostics.total == 2 and nestedDiagnostics.total == 2
      and canonical.encode(ordinaryDiagnostics) == canonical.encode(nestedDiagnostics),
    'choice output envelope changed missing-target behavior or diagnostics')
  local uncertain = prepared(input({variants = {['f/absent.nif'] = {meshes = {'f/first.nif'}}},
    weights = {default = {0, 1}}}))
  local empty = placementCompiler.outputTypeEnvelope(uncertain, context())
  expect(type(empty) == 'table' and next(empty) == nil,
    'a choice with no resolvable sources did not prove an empty output envelope')
end
local function outputEnvelopeSkipsUnresolvedSources()
  local ctx = context()
  local spec = {
    id = 'mixed-parent', verb = 'attach', payloadKind = 'tuples', select = {cell = 'Balmora'},
    payload = {
      {sourceIndex = 1, values = {'missing_source', 'target_container'}},
      {sourceIndex = 2, values = {'f/absent.nif', 'f/first.nif'}},
      {sourceIndex = 3, values = {'source_static', 'f/first.nif'}},
    },
  }
  local preparedSpec, prepErrors = placementCompiler.prepareAction(
    spec, {recordIds = {}, meshPathTypes = {}}, ctx)
  expect(preparedSpec, table.concat(prepErrors or {}, ' | '))
  local rows, errors = placementCompiler.compileAction(preparedSpec, ctx)
  expect(rows and #rows == 1 and rows[1].candidateTypes.Static,
    'ordinary parent did not skip unavailable sources: ' .. table.concat(errors or {}, ' | '))
  local types, reason = placementCompiler.outputTypeEnvelope(preparedSpec, ctx)
  expect(types and types.Static and not types.Container,
    'parent envelope retained a skipped source or lost the valid source: ' .. tostring(reason))

  local choices = prepared(input({
    record_variants = {
      missing_source = {records = {'target_container'}},
      source_static = {meshes = {'f/first.nif'}},
    },
    weights = {default = {0, 1}},
  }))
  local choiceRows, choiceErrors = compiler.compile(choices, ctx)
  expect(choiceRows and #choiceRows == 1 and choiceRows[1].candidateTypes.Static,
    'ordinary choice did not skip its unavailable source: ' .. table.concat(choiceErrors or {}, ' | '))
  local choiceTypes, choiceReason = placementCompiler.outputTypeEnvelope(choices, ctx)
  expect(choiceTypes and choiceTypes.Static and not choiceTypes.Container,
    'choice envelope retained a skipped source: ' .. tostring(choiceReason))
end
local function outputEnvelopePreservesSelectorErrorReachability()
  local ctx = context()
  local function prepare(target)
    local value, errors = placementCompiler.prepareAction({
      id = 'selector-reachability', verb = 'attach', payloadKind = 'tuples',
      select = {cell = 'Balmora'}, payload = {
        {sourceIndex = 1, values = {'source_static, (bad)', target}},
        {sourceIndex = 2, values = {'source_static', 'f/first.nif'}},
      },
    }, {recordIds = {}, meshPathTypes = {}}, ctx)
    expect(value, table.concat(errors or {}, ' | '))
    return value
  end
  for _, missing in ipairs({'missing_target', 'f/missing.nif'}) do
    local value = prepare(missing)
    local rows, errors = placementCompiler.compileAction(value, ctx)
    expect(rows and #rows == 1, table.concat(errors or {}, ' | '))
    local types, reason = placementCompiler.outputTypeEnvelope(value, ctx)
    expect(types and types.Static, 'skipped replacement exposed a dead selector: ' .. tostring(reason))
  end
  local live = prepare('target_static')
  local rows, errors = placementCompiler.compileAction(live, ctx)
  expect(rows == nil and table.concat(errors or {}, ' | '):find('invalid keyed position suffix', 1, true),
    'normal parent accepted a malformed selector with an available target')
  local types, reason = placementCompiler.outputTypeEnvelope(live, ctx)
  expect(types == nil and tostring(reason):find('invalid keyed position suffix', 1, true),
    'parent envelope hid a malformed selector with an available target')
end
local function choiceOutputEnvelopeHonorsSourceEligibility()
  local function choice()
    return input({variants = {['f/source.nif'] = {meshes = {'f/first.nif'}}},
      weights = {default = {0, 1}}})
  end
  local function verify(value, ctx, expectedRows, expectedStatic, expectedContainer)
    local spec = prepared(value)
    local rows, errors = compiler.compile(spec, ctx)
    expect(rows and #rows == expectedRows, table.concat(errors or {}, ' | '))
    local types, reason = placementCompiler.outputTypeEnvelope(spec, ctx)
    expect(type(types) == 'table' and (types.Static == true) == expectedStatic
        and (types.Container == true) == expectedContainer,
      'choice output envelope differs from eligible source records: ' .. tostring(reason))
  end
  local excludeContainer = choice()
  excludeContainer.payload.rules[1].ignoreRecords.source_container = true
  verify(excludeContainer, context(), 1, true, false)

  local excludeAll = choice()
  for _, id in ipairs({'source_container', 'source_static', 'second_static', 'ignored'}) do
    excludeAll.payload.rules[1].ignoreRecords[id] = true
  end
  verify(excludeAll, context(), 0, false, false)

  local mismatchedContext = context()
  local resolve = mismatchedContext.recordCtx.resolveLiveRefType
  mismatchedContext.recordCtx.resolveLiveRefType = function(id)
    if id == 'source_container' then return nil, 'changed type' end
    return resolve(id)
  end
  verify(choice(), mismatchedContext, 1, true, false)

  local recordChoice = input({record_variants = {source_static = {meshes = {'f/first.nif'}}},
    weights = {default = {0, 1}}})
  recordChoice.payload.rules[1].ignoreRecords.source_static = true
  verify(recordChoice, context(), 0, false, false)
end
local function emptyParentOutputsPreserveChildValidation()
  local source_ir = require('scripts.mom.compiler.source_ir')
  local source_lowering = require('scripts.mom.compiler.source_lowering')
  local diagnostics = require('scripts.mom.diagnostics.compile_diagnostics')
  local catalog = {actions = {byId = {place_ref = {module = placementCompiler}}}}
  local function action(id, spec, child)
    return source_ir.sourceAction(spec, {family = 'place_ref', diagnosticId = id,
      children = child and {child} or {}})
  end
  local function lower(child, parentSpec)
    local parent = action('parent', parentSpec or {
      attach = {{'Balmora', 'missing_source', 'f/first.nif'}},
    }, child)
    local preparedActions, _, prepErrors = source_lowering.prepareActions({parent}, catalog)
    expect(preparedActions, table.concat(prepErrors or {}, ' | '))
    local ctx = context()
    local balmora = {key = 'balmora', id = 'Balmora', idLower = 'balmora',
      name = 'Balmora', nameLower = 'balmora', displayName = 'Balmora',
      displayNameLower = 'balmora', interiorKey = 'balmora', isExterior = false}
    ctx.cellIndex = {entries = {balmora}, byKey = {balmora = balmora},
      byId = {balmora = {balmora}}, byName = {balmora = {balmora}},
      byDisplayName = {balmora = {balmora}}, byExteriorWorldspace = {},
      byRegion = {}, byWorldspace = {}}
    local collector = diagnostics.new()
    ctx.diagnosticCollector = collector
    local result, errors = source_lowering.lowerActions(preparedActions, ctx, catalog)
    return result, errors, diagnostics.forCompile(collector).summary.diagnostics
  end
  local plain, plainErrors, plainDiagnostics = lower()
  expect(plain and #plain.actions == 0, table.concat(plainErrors or {}, ' | '))
  local grandchild = action('grandchild', {attach = {{'f/first.nif'}}})
  local child = action('child', {attach = {{'target_static'}}}, grandchild)
  local nested, nestedErrors, nestedDiagnostics = lower(child)
  expect(nested and #nested.actions == 0, table.concat(nestedErrors or {}, ' | '))
  expect(canonical.encode(plainDiagnostics) == canonical.encode(nestedDiagnostics),
    'known-empty descendants changed the skipped parent diagnostics')

  local tupleChild = action('tuple-child', {
    attach = {{'Balmora', 'f/generated.nif', 'target_static'}},
  }, action('tuple-grandchild', {attach = {{'f/first.nif'}}}))
  local tuple, tupleErrors, tupleDiagnostics = lower(tupleChild)
  expect(tuple and #tuple.actions == 0, table.concat(tupleErrors or {}, ' | '))
  expect(canonical.encode(plainDiagnostics) == canonical.encode(tupleDiagnostics),
    'known-empty mesh tuple descendants changed the skipped parent diagnostics')

  local missingTarget = action('bad-child', {attach = {{'missing_target'}}})
  local rejected, errors = lower(missingTarget)
  expect(rejected == nil and table.concat(errors or {}, ' | '):find('invalid record id', 1, true),
    'skipped parent hid an invalid child replacement target')
  local badGrandchild = action('bad-grandchild', {attach = {{'missing_target'}}})
  rejected, errors = lower(action('child', {attach = {{'target_static'}}}, badGrandchild))
  expect(rejected == nil and table.concat(errors or {}, ' | '):find('invalid record id', 1, true),
    'skipped parent hid an invalid grandchild replacement target')

  local emptyPlace, placeErrors = lower(
    action('child', {attach = {{'target_static'}}}),
    {place = {{'Balmora', 'missing_target', {0, 0, 0}, {yaw = 0}}}})
  expect(emptyPlace and #emptyPlace.actions == 0, table.concat(placeErrors or {}, ' | '))

  local recordChild = action('record-child', {
    attach = {{'Balmora', 'source_container', 'f/first.nif'}}, disableOriginal = true,
  }, action('grandchild', {attach = {{'target_static'}}}))
  local emptyRecord, recordErrors = lower(recordChild)
  expect(emptyRecord and #emptyRecord.actions == 0, table.concat(recordErrors or {}, ' | '))

  local placementChild = action('place-child', {
    place = {{'Balmora', 'source_light', {1, 2, 3}, {yaw = 0}}},
  }, action('grandchild', {attach = {{'target_static'}}}))
  local emptyPlacement, placementErrors = lower(placementChild)
  expect(emptyPlacement and #emptyPlacement.actions == 0, table.concat(placementErrors or {}, ' | '))

  local function keyedContainerChild()
    return action('container-child', {
      attach = {{'Balmora', 'source_container', 'target_container'}}, disableOriginal = true,
    }, action('grandchild', {attach = {{'target_static'}}}))
  end
  local staticParent = {place = {{'Balmora', 'source_static', {0, 0, 0}, {yaw = 0}}}}
  local unreachable, unreachableErrors = lower(keyedContainerChild(), staticParent)
  expect(unreachable and #unreachable.actions == 1
      and #unreachable.actions[1].children == 1
      and #unreachable.actions[1].children[1].children == 0,
    'unreachable keyed child polluted its descendants: ' .. table.concat(unreachableErrors or {}, ' | '))
  local mixedParent = {place = {
    {'Balmora', 'source_static', {0, 0, 0}, {yaw = 0}},
    {'Balmora', 'source_container', {1, 0, 0}, {yaw = 0}},
  }}
  local unsafe, unsafeErrors = lower(keyedContainerChild(), mixedParent)
  expect(unsafe == nil and table.concat(unsafeErrors or {}, ' | '):find('Container', 1, true),
    'reachable container branch was incorrectly omitted from the output envelope')

  local function lowerChoice(withChild)
    local choice = source_ir.sourceAction({select = {type = {'Static', 'Activator', 'Container'}},
      attach = {{'*', 'f/absent.nif', {choose = {{'f/first.nif', 1}}}}},
      disableOriginal = true}, {
      family = 'place_ref', diagnosticId = 'choice-parent',
      children = withChild and {action('child', {attach = {{'target_static'}}},
        action('grandchild', {attach = {{'f/first.nif'}}}))} or {},
    })
    local preparedActions, _, prepErrors = source_lowering.prepareActions({choice}, catalog)
    expect(preparedActions, table.concat(prepErrors or {}, ' | '))
    local ctx, collector = context(), diagnostics.new()
    ctx.diagnosticCollector = collector
    local result, errors = source_lowering.lowerActions(preparedActions, ctx, catalog)
    return result, errors, diagnostics.forCompile(collector).summary.diagnostics
  end
  local plainChoice, plainChoiceErrors, plainChoiceDiagnostics = lowerChoice(false)
  local nestedChoice, nestedChoiceErrors, nestedChoiceDiagnostics = lowerChoice(true)
  expect(plainChoice and #plainChoice.actions == 0, table.concat(plainChoiceErrors or {}, ' | '))
  expect(nestedChoice and #nestedChoice.actions == 0, table.concat(nestedChoiceErrors or {}, ' | '))
  expect(canonical.encode(plainChoiceDiagnostics) == canonical.encode(nestedChoiceDiagnostics),
    'known-empty choice descendants changed the skipped parent diagnostics')

  local unknownCatalog = {actions = {byId = {
    place_ref = {module = placementCompiler},
    unknown_parent = {module = {publicFields = {'modify'},
      prepareAction = function(value) return value end,
      compileAction = function() return {} end}},
  }}}
  local knownChild = action('record-child', {
    attach = {{'Balmora', 'source_static', 'f/first.nif'}},
  }, action('grandchild', {attach = {{'target_static'}}}))
  local unknownParent = source_ir.sourceAction({modify = {}}, {
    family = 'unknown_parent', diagnosticId = 'unknown-parent', children = {knownChild},
  })
  local unknownPrepared, _, unknownPrepErrors = source_lowering.prepareActions({unknownParent}, unknownCatalog)
  expect(unknownPrepared, table.concat(unknownPrepErrors or {}, ' | '))
  local unknownResult, unknownErrors = source_lowering.lowerActions(unknownPrepared, context(), unknownCatalog)
  expect(unknownResult and #unknownResult.actions == 0, table.concat(unknownErrors or {}, ' | '))
  local unknownContainerParent = source_ir.sourceAction({modify = {}}, {
    family = 'unknown_parent', diagnosticId = 'unknown-parent', children = {keyedContainerChild()},
  })
  local unknownContainerPrepared = assert(source_lowering.prepareActions({unknownContainerParent}, unknownCatalog))
  local unknownContainer, unknownContainerErrors = source_lowering.lowerActions(
    unknownContainerPrepared, context(), unknownCatalog)
  expect(unknownContainer == nil
      and table.concat(unknownContainerErrors or {}, ' | '):find('Container', 1, true),
    'unknown parent envelope incorrectly proved a keyed container branch unreachable')
end
function M.run()
  return support.runCases('choice place_ref compiler', {
    {'transfer capability is checked against resolved sources in shared lowering', function()
      local value = input()
      value.options.transferContents = false
      local outputs, errors = compiler.compile(prepared(value), context())
      expect(outputs == nil and table.concat(errors or {}, ' | '):find('preserving inventory', 1, true),
        'Container discard request escaped common capability validation')
      value = input()
      value.options.transferContents = false
      for _, rule in ipairs(value.payload.rules) do rule.sourceTypes = {Static = true} end
      outputs, errors = compiler.compile(prepared(value), context())
      expect(outputs and #outputs == 1 and outputs[1].candidateTypes.Static,
        'non-container replacement inherited an irrelevant transfer restriction')
    end},
    {'choice admission validates and collects queries', prepareQueries},
    {'typed choices preserve weighted slots and claims', typedChoiceCompilation},
    {'unavailable choice sources skip safely', missingSources},
    {'prepared choice output types follow actual sources', preparedChoiceOutputEnvelope},
    {'parent output types omit unresolved source siblings', outputEnvelopeSkipsUnresolvedSources},
    {'parent envelope preserves selector error reachability', outputEnvelopePreservesSelectorErrorReachability},
    {'choice output envelope honors ignored and changed sources', choiceOutputEnvelopeHonorsSourceEligibility},
    {'known-empty parent outputs preserve child validation', emptyParentOutputsPreserveChildValidation},
    {'compiled choice programs validate before publication', programAdmission},
    {'profile pools deduplicate by exact native identity', profilePoolIdentity},
    {'ordinary placement rejects orphaned profile pools', orphanPoolAdmission},
  })
end
return M
