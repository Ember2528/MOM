local canonical = require('scripts.mom.contracts.canonical')
local claim_contract = require('scripts.mom.contracts.claim_contract')
local compile_result = require('scripts.mom.contracts.compiler_result')
local extension_registry = require('scripts.mom.compiler.extension_registry')
local manifest_assembler = require('scripts.mom_test_orchestrator.manifest_fixture')
local manifest_contract = require('scripts.mom.contracts.manifest_contract')
local plain_data = require('scripts.mom.contracts.plain_data')
local plan_identity = require('scripts.mom.contracts.plan_identity')
local scalar_match = require('scripts.mom.contracts.scalar_match')
local source_ir = require('scripts.mom.compiler.source_ir')
local source_lowering = require('scripts.mom.compiler.source_lowering')
local compile_manifest = require('scripts.mom.compiler.compile_manifest')
local source_manifest_fixture = require('scripts.mom_test_orchestrator.source_manifest_fixture')
local source_variant_actions =
  require('scripts.mom.compiler.source_variant_actions')
local strings = require('scripts.mom.common.strings')
local numbers = require('scripts.mom.common.numbers')
local tables = require('scripts.mom.common.tables')
local spec_key = require('scripts.mom.compiler.spec_key')

local M = {}

local test_support = require('pure.test_support')
local expect = test_support.expect

local function expectInvalid(value, expected)
  local ok, errors = plain_data.validate(value)
  expect(ok == nil, 'expected plain-data validation failure')
  expect(type(errors) == 'table' and #errors > 0, 'expected validation diagnostics')
  if expected then
    local found = false
    for i = 1, #errors do
      if tostring(errors[i]):find(expected, 1, true) then
        found = true
        break
      end
    end
    expect(found, 'expected error containing ' .. tostring(expected) .. ': ' .. table.concat(errors, ' | '))
  end
end

local function plainDataContract()
  local valid = {
    schemaVersion = 0,
    actions = {
      {id = 'a', enabled = true, value = 1.5},
    },
  }
  expect(plain_data.validate(valid) == true, 'valid plain data was rejected')

  expectInvalid({callback = function() end}, 'function values are not allowed')

  local cyclic = {}
  cyclic.self = cyclic
  expectInvalid(cyclic, 'already referenced')

  local shared = {value = 1}
  expectInvalid({left = shared, right = shared}, 'already referenced')
  local detached = assert(plain_data.detach({left = shared, right = shared}))
  expect(detached.left ~= detached.right, 'detach did not split shared compiler tables')
  expect(plain_data.validate(detached) == true, 'detached compiler data is not a tree')
  local cloned = plain_data.cloneValidated(valid)
  cloned.actions[1].id = 'changed'
  expect(cloned ~= valid and cloned.actions ~= valid.actions
      and valid.actions[1].id == 'a',
    'validated plain-data clone did not isolate its source tree')
  expect(plain_data.equalValidated(valid, plain_data.cloneValidated(valid))
      and not plain_data.equalValidated(valid, cloned)
      and plain_data.equalValidated(0, -0.0)
      and not plain_data.equalValidated({a = 1}, {a = 1, b = 2})
      and not plain_data.equalValidated({1, 2}, {1, 3}),
    'validated plain-data structural equality is inconsistent')

  expectInvalid(setmetatable({value = 1}, {}), 'metatables are not allowed')
  expectInvalid({[2] = 'sparse'}, 'dense arrays or string-keyed objects')
  expectInvalid({value = 0 / 0}, 'numbers must be finite')
end

local function manifestAction(seed)
  local lifecycle = seed.lifecycle or 'static'
  return {
    id = seed.id,
    family = seed.family or 'modify_ref',
    familyAbiVersion = 0,
    behaviorVersion = 0,
    programVersion = 0,
    lifecycle = lifecycle,
    scope = seed.scope or 'ref',
    ownerId = seed.ownerId,
    program = seed.program or {enabled = false},
    selection = seed.selection or {},
    claims = seed.claims or {keys = {'ref.enabled'}},
    priority = seed.priority or 0,
    specificity = seed.specificity or 0,
    order = seed.order or 0,
    chance = seed.chance or 1,
    reversible = seed.reversible ~= false,
    parentId = seed.parentId,
    childIds = seed.childIds or {},
    sourceRef = seed.sourceRef or ('source:' .. seed.id),
    previsit = seed.previsit == true,
  }
end

local function manifestContract()
  local parent = manifestAction({
    id = 'parent',
    scope = 'cell',
    order = 1,
  })
  parent.id = plan_identity.actionId(parent)
  local child = manifestAction({
    id = 'child',
    order = 2,
    parentId = parent.id,
  })
  child.id = plan_identity.actionId(child)
  parent.childIds = {child.id}
  local guard = {
    op = 'all',
    fragments = {
      {
        family = 'time',
        abiVersion = 0,
        behaviorVersion = 0,
        programVersion = 0,
        program = {hour = {min = 8}},
      },
    },
  }
  local stateAction = manifestAction({
    id = 'state',
    lifecycle = 'state',
    order = 3,
  })
  stateAction.guardKey = plan_identity.guardKey(guard, {'timeHourChanged'})
  stateAction.id = plan_identity.actionId(stateAction)
  local owner = {
    guard = guard,
    actionIds = {stateAction.id},
    subscriptions = {'timeHourChanged'},
  }
  owner.id = plan_identity.ownerId(owner)
  stateAction.ownerId = owner.id
  local extensions = {
    actions = {
      modify_ref = {abiVersion = 0, behaviorVersion = 0, programVersion = 0},
    },
    guards = {
      time = {abiVersion = 0, behaviorVersion = 0, programVersion = 0},
    },
    compat = {},
  }
  local first, firstErrors = manifest_assembler.assemble({
    actions = {stateAction, child, parent},
    owners = {owner},
    extensions = extensions,
  })
  expect(first ~= nil, 'manifest assembly failed: ' .. table.concat(firstErrors or {}, ' | '))
  expect(manifest_contract.validate(first) == true, 'assembled manifest is invalid')
  expect(first.schemaVersion == nil and first.compilerVersion == nil
      and first.claimSchemaVersion == nil,
    'process-local manifest retained compatibility version fields')
  expect(plain_data.validate(first) == true, 'manifest is not plain data')
  expect(first.actionsById[parent.id] ~= nil,
    'manifest action IDs are not canonical')
  expect(first.indexes.ownersByEvent.timeHourChanged[1] == owner.id,
    'owner event index was not derived')
  expect(first.actionsById[parent.id].fingerprint == nil
      and first.actionsById[child.id].fingerprint == nil
      and first.actionsById[stateAction.id].fingerprint == nil
      and first.ownersById[owner.id].fingerprint == nil,
    'manifest retained duplicate semantic fingerprint fields')

  local tamperedAction = assert(plain_data.detach(first))
  tamperedAction.actionsById[parent.id].program.enabled = true
  tamperedAction.contentHash = manifest_contract.contentHash(tamperedAction)
  local valid, validationErrors = manifest_contract.validate(tamperedAction)
  expect(valid == nil and table.concat(validationErrors or {}, ' | '):find(
    'does not match semantic action content', 1, true),
    'manifest accepted modified action content under its prior semantic ID')

  local tamperedOwner = assert(plain_data.detach(first))
  tamperedOwner.ownersById[owner.id].guard.fragments[1].program.hour.min = 9
  tamperedOwner.contentHash = manifest_contract.contentHash(tamperedOwner)
  valid, validationErrors = manifest_contract.validate(tamperedOwner)
  expect(valid == nil and table.concat(validationErrors or {}, ' | '):find(
    'does not match semantic owner content', 1, true),
    'manifest accepted modified owner content under its prior semantic ID')

  local mismatchedState = assert(plain_data.detach(stateAction))
  mismatchedState.guardKey = plan_identity.guardKey({op = 'always'}, {})
  mismatchedState.id = plan_identity.actionId(mismatchedState)
  local mismatchedOwner = {
    guard = assert(plain_data.detach(guard)),
    actionIds = {mismatchedState.id},
    subscriptions = {'timeHourChanged'},
  }
  mismatchedOwner.id = plan_identity.ownerId(mismatchedOwner)
  mismatchedState.ownerId = mismatchedOwner.id
  local mismatchedManifest, mismatchedErrors = manifest_assembler.assemble({
    actions = {mismatchedState},
    owners = {mismatchedOwner},
    extensions = extensions,
  })
  expect(mismatchedManifest == nil
      and table.concat(mismatchedErrors or {}, ' | '):find(
        'does not match its owner guard definition', 1, true),
    'manifest accepted a supplied guard key unrelated to its owner')

  local malformedState = assert(plain_data.detach(stateAction))
  local malformedOwner = {
    guard = 'invalid',
    actionIds = {malformedState.id},
    subscriptions = {'timeHourChanged'},
  }
  malformedOwner.id = plan_identity.ownerId(malformedOwner)
  malformedState.ownerId = malformedOwner.id
  malformedState.guardKey = plan_identity.guardKey(
    malformedOwner.guard,
    malformedOwner.subscriptions
  )
  local returned, malformedManifest, malformedErrors = pcall(
    manifest_assembler.assemble,
    {
      actions = {malformedState},
      owners = {malformedOwner},
      extensions = extensions,
    }
  )
  expect(returned and malformedManifest == nil
      and table.concat(malformedErrors or {}, ' | '):find(
        'expected table', 1, true),
    'malformed owner guard escaped manifest diagnostics')

  local second = assert(manifest_assembler.assemble({
    actions = {parent, child, stateAction},
    owners = {owner},
    extensions = extensions,
  }))
  expect(first.contentHash == second.contentHash,
    'input ordering changed schema-0 content hash')

  local movedParent = manifestAction({
    id = 'moved-parent',
    scope = 'cell',
    order = 20,
    sourceRef = 'source:moved-parent',
  })
  movedParent.id = plan_identity.actionId(movedParent)
  local movedChild = manifestAction({
    id = 'moved-child',
    order = 21,
    parentId = movedParent.id,
    sourceRef = 'source:moved-child',
  })
  movedChild.id = plan_identity.actionId(movedChild)
  movedParent.childIds = {movedChild.id}
  local moved = assert(manifest_assembler.assemble({
    actions = {movedParent, movedChild, stateAction},
    owners = {owner},
    extensions = extensions,
  }))
  expect(movedParent.id == parent.id and movedChild.id == child.id,
    'source movement changed semantic action IDs')
  local editedParent = manifestAction({
    id = 'edited-parent',
    scope = 'cell',
    order = 20,
  })
  editedParent.program.patch = {enabled = false}
  editedParent.id = plan_identity.actionId(editedParent)
  local editedChild = manifestAction({
    id = 'edited-child',
    order = 21,
    parentId = editedParent.id,
  })
  editedChild.id = plan_identity.actionId(editedChild)
  editedParent.childIds = {editedChild.id}
  local edited = assert(manifest_assembler.assemble({
    actions = {editedParent, editedChild, stateAction},
    owners = {owner},
    extensions = extensions,
  }))
  expect(editedParent.id ~= parent.id and editedChild.id ~= child.id,
    'semantic action edit retained its semantic ID')
  local otherSourceAction = manifestAction({
    id = 'other-source',
    scope = 'cell',
    order = 20,
    sourceRef = 'source:other-file',
  })
  otherSourceAction.id = plan_identity.actionId(otherSourceAction)
  local otherSource = assert(manifest_assembler.assemble({
    actions = {otherSourceAction, stateAction},
    owners = {owner},
    extensions = extensions,
  }))
  expect(otherSourceAction.id == parent.id,
    'source lineage changed semantic action identity')

  local invalid, invalidErrors = manifest_assembler.assemble({
    actions = {
      manifestAction({
        id = 'bad-parent',
        childIds = {'missing-child'},
      }),
    },
    extensions = extensions,
  })
  expect(invalid == nil, 'missing child action was accepted')
  expect(type(invalidErrors) == 'table' and #invalidErrors > 0,
    'missing child action diagnostic was not returned')

  local impure = manifestAction({id = 'impure'})
  impure.program.callback = function() end
  expect(manifest_assembler.assemble({
    actions = {impure},
    extensions = extensions,
  }) == nil, 'impure action program was accepted')

  local unknown, unknownErrors = manifest_assembler.assemble({
    actions = {manifestAction({id = 'unknown-claim', claims = {keys = {'ref.value'}}})},
    extensions = extensions,
  })
  expect(unknown == nil and table.concat(unknownErrors or {}, ' | '):find(
    'unknown claim domain ref.value', 1, true), 'unknown shared claim was accepted')

  local wrongPrivate, privateErrors = manifest_assembler.assemble({
    actions = {manifestAction({
      id = 'wrong-private-claim',
      claims = {keys = {'family:other:value'}},
    })},
    extensions = extensions,
  })
  expect(wrongPrivate == nil and table.concat(privateErrors or {}, ' | '):find(
    'does not match action family modify_ref', 1, true),
    'foreign family-private claim was accepted')

  local privateAction = manifestAction({
    id = 'private-claim',
    claims = {keys = {'family:modify_ref:value'}},
  })
  privateAction.id = plan_identity.actionId(privateAction)
  local privateManifest, privateManifestErrors = manifest_assembler.assemble({
    actions = {privateAction},
    extensions = extensions,
  })
  expect(privateManifest ~= nil, 'matching family-private claim was rejected: '
    .. table.concat(privateManifestErrors or {}, ' | '))
end

local function claimSchemaContract()
  expect(claim_contract.validateDomain('ref.enabled', 'modify_ref') == true,
    'shared claim was rejected')
  expect(claim_contract.validateDomain('family:modify_ref:variant', 'modify_ref') == true,
    'matching private claim was rejected')

  local valid, reason = claim_contract.validateDomain('family:place_ref:variant', 'modify_ref')
  expect(valid == nil and reason:find('does not match action family', 1, true),
    'foreign private claim family was accepted')
  valid, reason = claim_contract.validateDomain('family:modify-ref:variant', 'modify_ref')
  expect(valid == nil and reason:find('canonical extension ID', 1, true),
    'malformed private claim family was accepted')

  local normalized = assert(claim_contract.normalize(
    {'ref.scale', 'ref.enabled'},
    'modify_ref',
    'claims',
    {nonEmpty = true}
  ))
  expect(normalized[1] == 'ref.enabled' and normalized[2] == 'ref.scale',
    'claim array was not canonicalized')

  local many = {}
  for i = 1, 64 do
    many[i] = string.format('family:modify_ref:claim_%03d', i)
  end
  local normalizedMany, manyErrors = claim_contract.normalize(
    many,
    'modify_ref',
    'claims',
    {nonEmpty = true}
  )
  expect(normalizedMany ~= nil and #normalizedMany == #many,
    'valid claim cardinality was rejected: ' .. table.concat(manyErrors or {}, ' | '))
end

local function canonicalContract()
  local left = {
    beta = {2, 3},
    alpha = 1,
  }
  local right = {
    alpha = 1,
    beta = {2, 3},
  }
  local leftEncoded = assert(canonical.encode(left))
  local rightEncoded = assert(canonical.encode(right))
  expect(leftEncoded == rightEncoded, 'map insertion order changed canonical encoding')
  local leftHash = assert(canonical.hash(left))
  expect(leftHash == assert(canonical.hash(right)),
    'map insertion order changed canonical hash')
  expect(assert(canonical.hash({value = 1})) ~= assert(canonical.hash({value = 2})),
    'semantic edit did not change canonical hash')
  expect(strings.hashString('') == '00001505811c9dc5'
      and strings.hashString('MOM') == '0b8804eeb5e18386'
      and strings.sampleStringRaw('MOM') == 193463534,
    'portable dual-lane string hash vectors drifted')
  expect(strings.sampleStringRaw('bA') == strings.sampleStringRaw('ab')
      and strings.hashString('bA') == '00597728640223a4'
      and strings.hashString('ab') == '0059772864012386',
    'secondary lane did not separate a known primary-lane collision')
  expect(leftEncoded == 'o2{s5:alphad1;s4:betaa2[d2;d3;]}'
      and leftHash == 'mom64:1e347c0168c08955'
      and canonical.assertHashBody(leftHash) == '1e347c0168c08955',
    'canonical encoding or mom64 known vector drifted')
  expect(canonical.hashBody('djb2:1e347c01') == nil,
    'canonical hash body accepted the removed fingerprint format')
  expect(spec_key.fromSpec({value = '\0\r\t'}) == 'o1{s5:values3:\0\r\t}'
      and spec_key.fromSpec(1 + 2 ^ -52) == 'd1.0000000000000002;'
      and spec_key.fromSpec(0) == spec_key.fromSpec(-0.0),
    'source keys depend on runtime number precision or quoted-string spelling')
end

local function semanticIdentityContract()
  local seed = {
    family = 'modify_ref',
    familyAbiVersion = 0,
    behaviorVersion = 0,
    programVersion = 0,
    lifecycle = 'static',
    scope = 'ref',
    program = {enabled = false},
    selection = {exactIds = {'object-a'}},
    claims = {keys = {'ref.enabled'}},
    priority = 0,
    specificity = 1,
    chance = 1,
    reversible = true,
    childIds = {},
    previsit = false,
  }
  local firstId = plan_identity.actionId(seed)
  local ownerId = plan_identity.ownerId({
    guard = {op = 'always'},
    actionIds = {},
    subscriptions = {},
  })
  local ownerFamilyAction = assert(plain_data.detach(seed))
  ownerFamilyAction.family = 'owner'
  local ownerFamilyActionId = plan_identity.actionId(ownerFamilyAction)
  expect(firstId:sub(1, #'action:modify_ref:') == 'action:modify_ref:'
      and ownerFamilyActionId:sub(1, #'action:owner:') == 'action:owner:'
      and ownerId:sub(1, #'owner:') == 'owner:'
      and ownerFamilyActionId ~= ownerId,
    'semantic action and owner identity domains are not separated')
  seed.sourceRef = 'source:first'
  seed.order = 99
  expect(firstId == plan_identity.actionId(seed),
    'source provenance or traversal order changed semantic action identity')
  seed.program = {enabled = true}
  expect(firstId ~= plan_identity.actionId(seed),
    'outcome-relevant program edit retained semantic action identity')
end

local function normalizedSourceIrContract()
  local child = source_ir.sourceAction({
    modify = {scale = {to = 1}},
  }, {
    family = 'modify_ref',
    diagnosticId = 'fixture.actions[1].actions[1]',
    source = {
      adapterId = 'native',
      file = 'fixture.yaml',
      variant = 'default',
      path = {'actions', 1, 'actions', 1},
    },
  })
  local action = source_ir.sourceAction({
    chance = 0.5,
    fixtureOption = 42,
    modify = {
      {'Balmora', 'fixture-a', {enabled = false}, {'upright', 25}},
      {'Ald-ruhn', 'fixture-b', {enabled = true}, {'upright', 25}},
    },
  }, {
    family = 'modify_ref',
    diagnosticId = 'fixture.actions[1]',
    source = {
      adapterId = 'native',
      file = 'fixture.yaml',
      variant = 'default',
      path = {'actions', 1},
    },
    children = {child},
  })
  local authoredPaths = {}
  local prepareCount, compileCount = 0, 0
  local familyCompiler = {
    publicFields = {'modify', 'fixtureOption'},
    prepareAction = function(input)
      prepareCount = prepareCount + 1
      if input.options then expect(input.options.fixtureOption == 42,
        'dynamic family preparation lost its own sibling options') end
      return input
    end,
    validateProgram = function() end,
    compileAction = function(spec, ctx)
      compileCount = compileCount + 1
      authoredPaths[ctx.actionId] = ctx.authoredPath
      return {source_ir.familyProgram({
        id = spec.id,
        select = spec.select,
        program = {
          payload = spec.payload,
        },
      }, {
        claims = {keys = {'ref.enabled'}},
        reversible = true,
      })}, nil
    end,
  }
  local catalog = {
    actions = {byId = {modify_ref = {module = familyCompiler}}},
  }

  local prepared, _, prepareErrors = source_lowering.prepareActions({action}, catalog)
  expect(prepared ~= nil, 'source preparation failed: ' .. table.concat(prepareErrors or {}, ' | '))
  expect(#prepared == 2 and prepared[1].kind == 'mom-prepared-action'
      and prepared[2].kind == 'mom-prepared-action',
    'multi-cell action did not produce explicit prepared records')
  expect(type(prepared[1].input.payload[1].predicates) == 'table'
      and #prepared[1].input.payload[1].predicates == 1
      and type(prepared[2].input.payload[1].predicates) == 'table'
      and #prepared[2].input.payload[1].predicates == 1,
    'tuple predicates were not retained as explicit prepared-record fields')
  expect(prepared[1].source == prepared[2].source
      and prepared[1].children == prepared[2].children,
    'transient split preparation redundantly copied compiler-owned metadata')

  local boundedPrepared = assert(plain_data.detach(prepared))
  local normalized, lowerErrors = source_lowering.lowerActions(prepared, {
    recordCtx = {},
    cellIndex = {},
  }, catalog)
  expect(prepareCount == 3 and compileCount == 4,
    'cell splits repeated child preparation or lost per-parent lowering')
  expect(normalized ~= nil, 'normalized source lowering failed: '
    .. table.concat(lowerErrors or {}, ' | '))
  expect(authoredPaths['fixture.actions[1]'] == 'variants.default.actions[1]'
      and authoredPaths['fixture.actions[1].actions[1]']
        == 'variants.default.actions[1].actions[1]',
    'source lowering exposed semantic ids instead of authored diagnostic paths')
  expect(#normalized.actions == 2
      and #normalized.actions[1].children == 1
      and #normalized.actions[2].children == 1
      and normalized.actions[1].chance == 0.5
      and normalized.actions[2].chance == 0.5,
    'normalized IR lost split children or inherited chance')
  expect(normalized.actions[1].sourceRef == 'fixture.yaml#variants.default.actions[1]'
      and normalized.actions[1].children[1].sourceRef
        == 'fixture.yaml#variants.default.actions[1].actions[1]',
    'source provenance did not retain a readable filename and authored path')
  boundedPrepared[1].source.file = string.rep('f', 600) .. '\nfile.yaml'
  boundedPrepared[1].source.variant = string.rep('v', 600)
  local boundedSource = assert(source_lowering.lowerActions(boundedPrepared, {
    recordCtx = {}, cellIndex = {},
  }, catalog)).actions[1].sourceRef
  expect(#boundedSource == 512 and boundedSource:find('#variants.', 1, true)
      and not boundedSource:find('%c'),
    'source provenance was unbounded or lost its authored location')
  expect(normalized.actions[1].source ~= normalized.actions[2].source
      and normalized.actions[1].children ~= normalized.actions[2].children
      and plain_data.validate(normalized) == true,
    'normalized source IR did not detach the transient prepared graph')
end

local function sourceIrChildOwnershipContract()
  local leafSpec = {modify = {scale = {to = 1}}}
  local leaf = source_ir.sourceAction(leafSpec, {
    family = 'modify_ref',
    diagnosticId = 'ownership.leaf',
    source = {adapterId = 'native', file = 'ownership.yaml', path = {'leaf'}},
  })
  leafSpec.modify.scale.to = 9
  local suppliedChildren = {leaf}
  local parent = source_ir.sourceAction({
    place = {{'Balmora', 'misc_de_pot_green_01', {0, 0, 0}, {}}},
  }, {
    family = 'place_ref',
    diagnosticId = 'ownership.parent',
    source = {adapterId = 'native', file = 'ownership.yaml', path = {'parent'}},
    children = suppliedChildren,
  })
  suppliedChildren[1] = nil
  expect(parent.children ~= suppliedChildren
      and parent.children[1] == leaf
      and leaf.spec.modify.scale.to == 1,
    'source IR did not isolate local fields while transferring owned children')

  local chain = leaf
  for depth = 1, 32 do
    chain = source_ir.sourceAction({modify = {scale = {to = depth}}}, {
      family = 'modify_ref',
      diagnosticId = 'ownership.chain.' .. tostring(depth),
      source = {
        adapterId = 'native',
        file = 'ownership.yaml',
        path = {'chain', depth},
      },
      children = {chain},
    })
  end
  local count, cursor = 0, chain
  while cursor do
    count = count + 1
    cursor = cursor.children[1]
  end
  expect(count == 33 and plain_data.validate(chain) == true,
    'deep source IR ownership transfer changed or corrupted the child tree')

  local wide = {}
  for i = 1, 256 do
    wide[i] = source_ir.sourceAction({modify = {enabled = true}}, {
      family = 'modify_ref',
      diagnosticId = 'ownership.wide.' .. tostring(i),
      source = {
        adapterId = 'native',
        file = 'ownership.yaml',
        path = {'wide', i},
      },
    })
  end
  local wideParent = source_ir.sourceAction({
    place = {{'Balmora', 'misc_de_pot_green_01', {0, 0, 0}, {}}},
  }, {
    family = 'place_ref',
    diagnosticId = 'ownership.wide-parent',
    source = {adapterId = 'native', file = 'ownership.yaml', path = {'wide'}},
    children = wide,
  })
  expect(#wideParent.children == 256
      and wideParent.children[1] == wide[1]
      and wideParent.children[256] == wide[256]
      and plain_data.validate(wideParent) == true,
    'wide source IR ownership transfer copied or truncated child records')
end

local function selectorExclusionOwnershipContract()
  local selection_plan = require('scripts.mom.compiler.selection_plan')
  local function compileWithPredicates(predicates)
    return selection_plan.compile({
      id = 'selector-exclusions',
      predicates = predicates,
    }, nil, {}, {})
  end

  local first, second = {a = true, ignored = false}, {a = false, b = true}
  local predicates = {
    {kind = 'orientation'},
    {kind = 'record_id_exclude', excludedIds = first},
    {kind = 'record_id_exclude'},
    {kind = 'record_id_exclude', excludedIds = second},
    {kind = 'record_id_exclude', excludedIds = {}},
  }
  local status, selection = compileWithPredicates(predicates)
  expect(status == 'ok' and #selection.excludedIds == 3
      and selection.excludedIds[1] == 'a' and selection.excludedIds[2] == 'b'
      and selection.excludedIds[3] == 'ignored',
    'selector exclusions lost keys or ordering')
  selection.excludedIds[1] = nil
  first.later = true
  expect(first.a == true and second.a == false and selection.excludedIds[2] == 'b'
      and selection.excludedIds[3] == 'ignored',
    'selector exclusion accumulation changed input ownership')
  for _, values in ipairs({{value = nil}, {value = false}}) do
    local emptyStatus, empty = compileWithPredicates(values.value)
    expect(emptyStatus == 'ok' and #empty.excludedIds == 0,
      'absent selector exclusions must remain empty')
  end
  for _, values in ipairs({{}, {{kind = 'orientation'}},
      {{kind = 'record_id_exclude'}},
      {{kind = 'record_id_exclude', excludedIds = {}}}}) do
    local emptyStatus, empty = compileWithPredicates(values)
    expect(emptyStatus == 'ok' and #empty.excludedIds == 0,
      'empty selector exclusion unions must remain empty')
  end
  expect(not pcall(compileWithPredicates,
      {{kind = 'record_id_exclude', excludedIds = false}}),
    'malformed false exclusion sets must retain their rejection')
end

local function compilerResultContract()
  local result = compile_result.rejected({
    diagnostics = {summary = {
      total = 0,
      diagnostics = {
        total = 1,
        bySeverity = {error = 1},
        samples = {{code = 'fixture-invalid'}},
      },
      sources = {
        count = 1,
        failed = 1,
        rows = {{path = 'fixture.yaml', status = 'resolve_error'}},
      },
    }},
    fatal = {
      code = 'candidate_source_set_incomplete',
      message = 'candidate source set is incomplete',
      errors = {'fixture source was rejected'},
    },
  })
  expect(compile_result.isRejected(result)
      and not compile_result.isAccepted(result)
      and result.manifest == nil
      and result.fatal.code == 'candidate_source_set_incomplete'
      and result.fatal.errors[1] == 'fixture source was rejected',
    'expected compiler rejection was not returned as a structured result')
  expect(result.diagnostics.summary.total == 0
      and result.diagnostics.summary.manifest == nil
      and result.diagnostics.summary.diagnostics.total == 1
      and result.diagnostics.summary.diagnostics.bySeverity.error == 1
      and result.diagnostics.summary.sources.failed == 1
      and result.diagnostics.summary.sources.rows[1].path == 'fixture.yaml',
    'rejected compiler result lost structured source diagnostics')
  expect(plain_data.validate(result, {path = 'compilerResult'}) == true,
    'rejected compiler result is not plain data')

  local manifest = {contentHash = 'sha256:fixture'}
  local accepted = compile_result.accepted({
    manifest = manifest,
    diagnostics = {summary = {total = 0}},
  })
  expect(compile_result.isAccepted(accepted)
      and not compile_result.isRejected(accepted)
      and accepted.manifest == manifest
      and accepted.fatal == nil,
    'accepted compiler result changed or cloned its manifest payload')
end

local function compilerDiagnosticsUseAuthoredPaths()
  local actions, pathError = source_variant_actions.collect('fixture', {
    actions = {
      {modify = 'not-a-payload'},
    },
  })
  expect(actions == nil
      and tostring(pathError):find(
        'variants.fixture.actions[1].modify',
        1,
        true
      ) == 1,
    'author-facing diagnostics did not use the authored variants path')
end

local function registryModule(id, matchesPath, storageVersion)
  return {
    id = id,
    abiVersion = 0,
    behaviorVersion = 0,
    storageVersion = storageVersion,
    matchesPath = matchesPath,
    compile = function() end,
  }
end

local function registryContract()
  local registry, errors = extension_registry.build('guard', {
    {
      path = 'scripts/mom/guards/zeta.lua',
      module = registryModule('zeta', function(path) return path == 'z' end, 2),
    },
    {
      path = 'scripts/mom/guards/alpha.lua',
      module = registryModule('alpha', function(path) return path == 'a' end),
    },
  }, {
    requiredMethods = {'compile'},
  })
  expect(registry ~= nil, 'valid registry failed: ' .. tostring(errors and errors[1] and errors[1].message))
  expect(registry.ids[1] == 'alpha' and registry.ids[2] == 'zeta',
    'registry IDs are not deterministic')
  expect(extension_registry.describe(registry).alpha.abiVersion == 0,
    'registry description omitted ABI')
  expect(extension_registry.describe(registry).zeta.storageVersion == 2,
    'registry description omitted family storage version')
  local selectedDescription = extension_registry.describe(registry, {alpha = true})
  expect(selectedDescription.alpha.abiVersion == 0
      and selectedDescription.zeta == nil,
    'registry description did not limit projection to selected extension IDs')

  local missingProgram, missingProgramErrors = extension_registry.build('guard', {
    {
      path = 'scripts/mom/guards/no_program.lua',
      module = registryModule('no_program', function() return false end),
    },
  }, {
    requiredMethods = {'compile'},
    requireProgramVersion = true,
  })
  expect(missingProgram == nil and missingProgramErrors[1].code == 'extension_program_version_invalid',
    'required program version was accepted')

  local invalidStorageModule = registryModule('invalid_storage', function() return false end)
  invalidStorageModule.storageVersion = -1
  local invalidStorage, invalidStorageErrors = extension_registry.build('action', {
    {path = 'scripts/mom/actions/invalid_storage.lua', module = invalidStorageModule},
  }, {
    requiredMethods = {'compile'},
  })
  expect(invalidStorage == nil
      and invalidStorageErrors[1].code == 'extension_storage_version_invalid',
    'invalid family storage version was accepted')

  local invalidRevertModule = registryModule('invalid_revert', function() return false end)
  invalidRevertModule.revertTokenVersion = -1
  local invalidRevert, invalidRevertErrors = extension_registry.build('action', {
    {path = 'scripts/mom/actions/invalid_revert.lua', module = invalidRevertModule},
  }, {
    requiredMethods = {'compile'},
  })
  expect(invalidRevert == nil
      and invalidRevertErrors[1].code == 'extension_revert_token_version_invalid',
    'invalid family revert-token version was accepted')

  local claim = assert(extension_registry.claim(registry, 'a'))
  expect(claim.id == 'alpha', 'wrong extension claimed source')

  local duplicate, duplicateErrors = extension_registry.build('guard', {
    {path = 'one.lua', module = registryModule('duplicate', function() return false end)},
    {path = 'two.lua', module = registryModule('duplicate', function() return false end)},
  }, {
    requiredMethods = {'compile'},
  })
  expect(duplicate == nil, 'duplicate extension ID was accepted')
  expect(duplicateErrors[1].code == 'extension_id_duplicate'
      or duplicateErrors[#duplicateErrors].code == 'extension_id_duplicate',
    'duplicate extension diagnostic missing')

  local unsupported = extension_registry.build('guard', {
    {
      path = 'future.lua',
      module = {
        id = 'future',
        abiVersion = 2,
        compile = function() end,
      },
    },
  }, {
    requiredMethods = {'compile'},
  })
  expect(unsupported == nil, 'unsupported ABI was accepted')

  local mismatched, mismatchErrors = extension_registry.build('guard', {
    {
      path = 'scripts/mom/guards/actual.lua',
      expectedId = 'actual',
      module = registryModule('different', function() return false end),
    },
  }, {
    requiredMethods = {'compile'},
  })
  expect(mismatched == nil, 'path/ID mismatch was accepted')
  expect(mismatchErrors[1].code == 'extension_id_path_mismatch',
    'path/ID mismatch diagnostic missing')

  local ambiguousRegistry = assert(extension_registry.build('compat', {
    {path = 'one.lua', module = registryModule('one', function() return true end)},
    {path = 'two.lua', module = registryModule('two', function() return true end)},
  }, {
    requiredMethods = {'compile'},
  }))
  local ambiguous, ambiguousErrors = extension_registry.claim(ambiguousRegistry, 'source.yaml')
  expect(ambiguous == nil, 'ambiguous source claim was accepted')
  expect(ambiguousErrors[1].code == 'extension_source_ambiguous',
    'ambiguous source diagnostic missing')

  local isolated = assert(extension_registry.buildQuarantined('guard', {
    {
      path = 'scripts/mom/guards/good.lua',
      expectedId = 'good',
      module = registryModule('good', function() return false end),
    },
    {
      path = 'scripts/mom/guards/broken.lua',
      expectedId = 'broken',
      module = {id = 'broken', abiVersion = 99},
    },
  }, {
    requiredMethods = {'compile'},
  }))
  expect(#isolated.ids == 1 and isolated.ids[1] == 'good'
      and isolated.byId.broken == nil
      and isolated.quarantinedById.broken ~= nil,
    'unused invalid extension rejected or contaminated the valid registry')

  local duplicateIsolated = assert(extension_registry.buildQuarantined('guard', {
    {
      path = 'scripts/mom/guards/duplicate_one.lua',
      module = registryModule('duplicate', function() return false end),
    },
    {
      path = 'scripts/mom/guards/duplicate_two.lua',
      module = registryModule('duplicate', function() return false end),
    },
  }, {
    requiredMethods = {'compile'},
  }))
  expect(#duplicateIsolated.ids == 0
      and duplicateIsolated.byId.duplicate == nil
      and duplicateIsolated.quarantinedById.duplicate ~= nil,
    'tolerant registry selected a duplicate extension by load order')

  local requireFailure = assert(extension_registry.buildQuarantined('action', {}, {
    loadErrors = {
      {
        code = 'extension_require_failed',
        path = 'scripts/mom/actions/unloadable.lua',
        expectedId = 'unloadable',
        message = 'synthetic require failure',
      },
    },
  }))
  expect(#requireFailure.ids == 0
      and requireFailure.quarantinedIds[1] == 'unloadable'
      and requireFailure.quarantinedById.unloadable.diagnostics[1].code
        == 'extension_require_failed',
    'require failure was not retained as deterministic ID quarantine evidence')
end

local function registryFor(kind, path, mod, opts)
  return assert(extension_registry.build(kind, {{path = path, module = mod}}, opts or {}))
end

local function sourceManifestCompilerContract()
  local validationCalls = 0
  local actionModule = {
    id = 'fixture_action',
    abiVersion = 0,
    behaviorVersion = 0,
    programVersion = 0,
    storageVersion = 0,
    programByReference = true,
    behavior = {
      scope = 'ref',
      canBeChildAction = true,
      acceptedParentTargetKinds = {'ref'},
    },
    prepareAction = function() error('source manifest must not invoke prepareAction') end,
    compileAction = function()
      error('source manifest must not invoke compileAction')
    end,
    validateProgram = function()
      validationCalls = validationCalls + 1
    end,
  }
  local compatModule = {
    id = 'fixture_compat',
    abiVersion = 0,
    behaviorVersion = 0,
    translate = function(_, config) return config, true end,
  }
  local actionRegistry = registryFor(
    'action',
    'fixture/action.lua',
    actionModule,
    {
      requiredMethods = {'compileAction', 'validateProgram'},
      requireProgramVersion = true,
    }
  )
  local guardRegistry = assert(extension_registry.build('guard', {}, {}))
  local compatRegistry = registryFor(
    'compat',
    'fixture/compat.lua',
    compatModule,
    {requiredMethods = {'translate'}}
  )
  local function catalog(compat)
    return {
      kind = 'mom-extension-catalog',
      actions = actionRegistry,
      guards = guardRegistry,
      compat = compat or assert(extension_registry.build('compat', {}, {})),
    }
  end
  local function ast(adapterId, sourceFile, sourcePath, structuralId, order)
    return {
      actions = {
        {
          kind = 'action',
          id = structuralId or 'fixture',
          family = 'fixture_action',
          order = order or 1,
          source = {
            adapterId = adapterId,
            file = sourceFile or 'fixture.yaml',
            path = sourcePath or {1},
          },
          sourceRef = 'fixture-source',
          program = {},
          claims = {keys = {'ref.enabled'}},
          reversible = true,
          candidateTypes = {Miscellaneous = true},
          children = {},
        },
      },
    }
  end
  local compileCtx = {cellIndex = {}, recordCtx = {}}

  local missing, missingErrors = source_manifest_fixture.compile(ast('native'), compileCtx)
  expect(missing == nil and tostring(missingErrors[1]):find('extension catalog', 1, true),
    'source compiler discovered extension registries from host state')

  local native, nativeErrors = source_manifest_fixture.compile(ast('native'), compileCtx, {
    catalog = catalog(),
  })
  expect(native ~= nil, 'native source compile failed without unused compat registry: '
    .. table.concat(nativeErrors or {}, ' | '))
  expect(next(native.extensions.compat) == nil, 'native manifest recorded an unused compat extension')
  expect(validationCalls == 1,
    'direct source compiler repeated validation for an unchanged family program')
  validationCalls = 0
  local ownedInput = ast('native')
  local ownedProgram = ownedInput.actions[1].program
  local ownedClaims = ownedInput.actions[1].claims
  local compiled = assert(compile_manifest.compileOwned(
    ownedInput,
    compileCtx,
    catalog()
  ))
  expect(compiled.contentHash == native.contentHash and validationCalls == 0,
    'owned source compiler revalidated a final family program')
  local compiledAction = compiled.actionsById[compiled.actionIds[1]]
  expect(compiledAction.program == ownedProgram
      and compiledAction.claims == ownedClaims,
    'owned source compiler copied already-proved family data')
  local selectiveCatalog = catalog()
  selectiveCatalog.actions = {
    kind = 'action',
    ids = {'fixture_action', 'unused_action'},
    byId = {
      fixture_action = actionRegistry.byId.fixture_action,
      unused_action = setmetatable({}, {
        __index = function(_, field)
          error('unused extension description projected field ' .. tostring(field))
        end,
      }),
    },
  }
  local selective = assert(compile_manifest.compileOwned(
    ast('native'),
    compileCtx,
    selectiveCatalog
  ))
  expect(selective.contentHash == native.contentHash
      and selective.extensions.actions.unused_action == nil,
    'source compiler projected an unused installed extension description')
  local nativeActionId = native.actionIds[1]
  local nativeAction = native.actionsById[nativeActionId]
  expect(nativeAction.sourceLineage == nil
      and type(nativeAction.sourceRef) == 'string',
    'direct compiler retained duplicate source lineage or omitted sourceRef')
  local ownedAst = ast('native')
  ownedAst.actions[1].source.capsuleKey = 'source-capsule:fixture'
  local owned = assert(source_manifest_fixture.compile(
    ownedAst,
    compileCtx,
    {catalog = catalog()}
  ))
  expect(owned.actionsById[nativeActionId].sourceLineage == nil
      and owned.contentHash == native.contentHash,
    'capsule ownership leaked into the runtime manifest or semantic identity')
  local movedSource = assert(source_manifest_fixture.compile(
    ast('native', 'elsewhere.yaml', {'actions', 9}, 'different-label', 500),
    compileCtx,
    {catalog = catalog()}
  ))
  expect(movedSource.actionIds[1] == nativeActionId
      and movedSource.contentHash == native.contentHash,
    'source movement changed semantic action or plan identity')

  local noCompat, noCompatErrors = source_manifest_fixture.compile(ast('fixture_compat'), compileCtx, {
    catalog = catalog(),
  })
  expect(noCompat == nil and tostring(noCompatErrors[1]):find('not registered', 1, true),
    'compat source compiled without its explicit registry')

  local manifest, errors = source_manifest_fixture.compile(ast('fixture_compat'), compileCtx, {
    catalog = catalog(compatRegistry),
  })
  expect(manifest ~= nil, 'source manifest compile failed: ' .. table.concat(errors or {}, ' | '))
  expect(manifest.extensions.actions.fixture_action.abiVersion == 0,
    'injected action registry was not recorded')
  expect(manifest.extensions.actions.fixture_action.storageVersion == 0,
    'action family storage version was not recorded')
  expect(manifest.extensions.compat.fixture_compat.abiVersion == 0,
    'injected compat registry was not recorded')
  expect(manifest.actionIds[1] == nativeActionId
      and manifest.actionsById[nativeActionId] ~= nil,
    'compat/native provenance changed semantic action identity')
  expect(manifest.contentHash == native.contentHash,
    'compat provenance changed canonical runtime plan hash')
  expect(plain_data.validate(manifest) == true, 'direct compiler emitted impure manifest data')
end

local function finalizedOwnerIdentityContract()
  local catalog = {
    kind = 'mom-extension-catalog',
    actions = registryFor('action', 'fixture/action.lua', {
      id = 'fixture_action', abiVersion = 0, behaviorVersion = 0, programVersion = 0,
      behavior = {
        scope = 'ref', canHaveChildActions = true, canBeChildAction = true,
        childTargetKind = 'ref', acceptedParentTargetKinds = {'ref'},
      },
    }),
    guards = registryFor('guard', 'fixture/guard.lua', {
      id = 'fixture_guard', abiVersion = 0, behaviorVersion = 0, programVersion = 0,
      compileProgram = function(spec)
        return {program = {value = spec.value}, subscriptions = {'MOM:fixture'}}
      end,
    }),
    compat = assert(extension_registry.build('compat', {})),
  }
  local function node(label, value, guardValue, children)
    return {
      kind = 'action', id = label, family = 'fixture_action', sourceRef = 'fixture:' .. label,
      program = {value = value}, claims = {keys = {'ref.enabled'}}, reversible = true,
      candidateTypes = {Miscellaneous = true}, children = children or {},
      guardOwner = guardValue and {
        id = label, when = {{type = 'fixture_guard', value = guardValue}},
      } or nil,
    }
  end
  local function compile(reverse, removeSibling)
    local actions = {
      node('parent', 2, 'a', {node('child', 1)}),
      node('sibling', 3, 'a'), node('other', 4, 'b'), node('static', 5),
    }
    if removeSibling then table.remove(actions, 2) end
    if reverse then
      for i = 1, math.floor(#actions / 2) do
        actions[i], actions[#actions - i + 1] = actions[#actions - i + 1], actions[i]
      end
    end
    local input = {actions = actions}
    expect(plain_data.validate(input), 'identity fixture must own a plain-data tree')
    return assert(compile_manifest.compileOwned(
      input, {cellIndex = {}, recordCtx = {}}, catalog))
  end
  local first, reordered, removed = compile(), compile(true), compile(false, true)
  local adjacentValue = 1 + 2 ^ -52
  local precise = assert(compile_manifest.compileOwned({actions = {
    node('numeric-a', 6, 1), node('numeric-b', 7, adjacentValue),
  }}, {cellIndex = {}, recordCtx = {}}, catalog))
  expect(#precise.ownerIds == 2,
    'source guard memoization merged distinct adjacent numeric values')
  local numericGuardValues = {}
  for _, ownerId in ipairs(precise.ownerIds) do
    local value = precise.ownersById[ownerId].guard.fragments[1].program.value
    numericGuardValues[value] = true
  end
  expect(numericGuardValues[1] and numericGuardValues[adjacentValue],
    'source guard memoization changed an adjacent numeric guard value')
  -- Includes shared guard ownership, a child, two owners sharing a route,
  -- and an unrelated static action under stable guard/subscription identity.
  expect(first.contentHash == 'mom64:080cb7ce2641ba32',
    'compiler changed established parent/action/owner/manifest identity')
  expect(first.contentHash == reordered.contentHash,
    'source order changed final owner identity or routes')
  expect(#first.ownerIds == 2 and #first.indexes.ownersByCell.shared == 2,
    'guard grouping or shared owner routes lost a finalized owner')
  for _, ownerId in ipairs(first.indexes.ownersByCell.shared) do
    expect(first.ownersById[ownerId] ~= nil and ownerId:sub(1, 6) == 'owner:',
      'owner route retained a draft guard-definition key')
  end
  local firstParent, remainingParent
  for _, actionId in ipairs(first.actionIds) do
    local action = first.actionsById[actionId]
    expect(plan_identity.actionId(action) == actionId,
      'assigning a final owner changed action identity')
    if action.lifecycle == 'state' then
      local owner = first.ownersById[action.ownerId]
      expect(owner ~= nil and plan_identity.ownerId(owner) == action.ownerId,
        'action points to a provisional owner identity')
    else
      expect(action.ownerId == nil, 'static action acquired an owner')
    end
    if action.program.value == 2 then firstParent = action end
  end
  for _, actionId in ipairs(removed.actionIds) do
    local action = removed.actionsById[actionId]
    if action.program.value == 2 then remainingParent = action end
  end
  expect(firstParent.id == remainingParent.id
      and firstParent.ownerId == remainingParent.ownerId
      and first.contentHash ~= removed.contentHash,
    'membership changes must preserve surviving action/owner identity and change manifest content')

  -- Exercise ordering through real guard/source compilation, not a fixture
  -- assembler that could repair the result and conceal a production regression.
  catalog.guards.byId.fixture_guard.module.compileProgram = function(spec)
    return {
      program = {value = spec.value},
      subscriptions = {'MOM:z', 'MOM:shared', 'MOM:a', 'MOM:shared'},
    }
  end
  local function orderedManifest(reverse)
    local actions = {
      node('wide', 20, 'c', {node('child-z', 30), node('child-a', 10), node('child-m', 25)}),
      node('owner-a', 40, 'a'), node('owner-b', 50, 'b'),
      node('static-z', 60), node('static-a', 70), node('static-m', 80),
    }
    if reverse then
      actions[1].children[1], actions[1].children[3] =
        actions[1].children[3], actions[1].children[1]
      for i = 1, #actions / 2 do
        actions[i], actions[#actions - i + 1] = actions[#actions - i + 1], actions[i]
      end
    end
    return assert(compile_manifest.compileOwned(
      {actions = actions}, {cellIndex = {}, recordCtx = {}}, catalog))
  end
  local ordered, reversed = orderedManifest(), orderedManifest(true)
  expect(canonical.encode(ordered) == canonical.encode(reversed),
    'source/child permutation changed complete canonical manifest bytes')
  local function expectSorted(ids)
    for i = 2, #ids do expect(ids[i - 1] < ids[i], 'IDs are not strictly ordered') end
  end
  expectSorted(ordered.actionIds)
  expectSorted(ordered.ownerIds)
  expect(#ordered.ownerIds == 3, 'multi-event fixture lost an owner')
  for _, ownerId in ipairs(ordered.ownerIds) do
    local owner = ordered.ownersById[ownerId]
    expectSorted(owner.actionIds)
    expect(table.concat(owner.subscriptions, ',') == 'MOM:a,MOM:shared,MOM:z',
      'guard subscriptions were not canonicalized before owner identity')
  end
  for _, event in ipairs({'MOM:a', 'MOM:shared', 'MOM:z'}) do
    expect(canonical.encode(ordered.indexes.ownersByEvent[event])
        == canonical.encode(ordered.ownerIds),
      'shared event bucket lost, duplicated or reordered owners')
  end
  for _, actionId in ipairs(ordered.actionIds) do
    expectSorted(ordered.actionsById[actionId].childIds)
  end
  for _, route in ipairs({'staticByCell', 'ownersByCell'}) do
    for _, ids in pairs(ordered.indexes[route]) do expectSorted(ids) end
  end

  local skipped = node('skipped', 90, 'unused')
  skipped.select = {cell = '*'}
  skipped.resolvedSelection = {exactIds = {}, exactIdQueries = {}, candidateTypes = {}}
  local empty = assert(compile_manifest.compileOwned(
    {actions = {skipped}}, {cellIndex = {}, recordCtx = {}}, catalog))
  expect(#empty.actionIds == 0 and #empty.ownerIds == 0
      and next(empty.indexes.ownersByEvent) == nil
      and empty.extensions.guards.fixture_guard ~= nil
      and empty.extensions.actions.fixture_action ~= nil,
    'skipping every guarded action retained an empty owner or lost used extensions')

  -- Node errors must still win over duplicates; duplicate errors must still
  -- win over extension-description errors. Neither check belongs in packing.
  local function duplicateInput(extra)
    local actions = {node('duplicate-a', 100), node('duplicate-b', 100)}
    actions[1].source = {adapterId = 'unregistered_compat'}
    if extra then actions[#actions + 1] = extra end
    return {actions = actions}
  end
  catalog.compat = nil
  local malformed = node('malformed', 101)
  malformed.family = 'missing_family'
  local rejected, errors = compile_manifest.compileOwned(
    duplicateInput(malformed), {cellIndex = {}, recordCtx = {}}, catalog)
  expect(rejected == nil and errors[1]
      == 'sourceManifest: action:malformed: unknown action family missing_family',
    'duplicate detection moved ahead of later node diagnostics')
  rejected, errors = compile_manifest.compileOwned(
    duplicateInput(), {cellIndex = {}, recordCtx = {}}, catalog)
  expect(rejected == nil and errors[1]:find(
      'sourceManifest: duplicate semantic action id ', 1, true) == 1,
    'extension description moved ahead of semantic duplicate diagnostics')
end

local function keyedTupleIdentityAndSavedWork()
  local target_match_plan = require('scripts.mom.contracts.target_match_plan')
  local family = require('scripts.mom.actions.modify_ref')
  local catalog = {
    kind = 'mom-extension-catalog',
    actions = registryFor('action', 'fixture/modify_ref.lua', family),
    guards = assert(extension_registry.build('guard', {})),
    compat = assert(extension_registry.build('compat', {})),
  }
  local context = {
    recordCtx = {resolveLiveRefType = function() return 'Static' end},
    cellIndex = {entries = {}}, workspace = {},
  }
  local function compile(tuples)
    local source = source_ir.sourceAction({modify = plain_data.cloneValidated(tuples)}, {
      family = 'modify_ref', diagnosticId = 'independent-tuples',
      source = {adapterId = 'native', file = 'tuple-identity.yaml', path = {'actions', 1}},
    })
    local prepared, _, prepareErrors = source_lowering.prepareActions({source}, catalog)
    expect(prepared ~= nil, table.concat(prepareErrors or {}, ' | '))
    local lowered, lowerErrors = source_lowering.lowerActions(prepared, context, catalog)
    expect(lowered ~= nil, table.concat(lowerErrors or {}, ' | '))
    local manifest, errors = compile_manifest.compileOwned(lowered, context, catalog)
    expect(manifest ~= nil, table.concat(errors or {}, ' | '))
    return manifest
  end
  local a = {'*', 'a, (1, 2, 3)', {enabled = false}}
  local b = {'*', 'b, (1, 2, 3)', {enabled = true}}
  local c = {'*', 'a, (4, 5, 6)', {enabled = true}}
  local first, reordered = compile({a, b, c}), compile({c, b, a})
  expect(first.contentHash == reordered.contentHash
      and canonical.encode(first) == canonical.encode(reordered),
    'independent record/position tuple reorder changed the complete manifest')
  local function payloads(plan, recordId, position)
    local facts = {typeName = 'Static', recordId = recordId, origin = {position = position}}
    local out, cursor = {}, nil
    while true do
      local entry, nextCursor, complete = target_match_plan.next(plan, facts, cursor)
      if complete then break end
      out[#out + 1] = entry.payload.patch.enabled
      cursor = nextCursor
    end
    return out
  end
  local function entry(recordId, position, enabled)
    return {sourceRecordId = recordId, inferredType = 'Static',
      sourceKeyKind = 'record_id', sourcePosition = position, enabled = enabled}
  end
  local function plan(entries)
    return assert(target_match_plan.build(entries, function(value)
      return {patch = {enabled = value.enabled}}
    end))
  end
  local exactA = entry('a', {x = 1, y = 2, z = 3}, false)
  local exactB = entry('b', {x = 1, y = 2, z = 3}, true)
  local exactC = entry('a', {x = 4, y = 5, z = 6}, true)
  local any = entry('a', nil, true)
  local overlap = plan({exactA, any, exactC, exactB})
  local independent = plan({exactB, exactA, any, exactC})
  local changedPrecedence = plan({any, exactA, exactC, exactB})
  expect(canonical.encode(overlap) == canonical.encode(independent)
      and canonical.encode(overlap) ~= canonical.encode(changedPrecedence),
    'overlap normalization lost authored precedence or retained disjoint source order')
  expect(plain_data.equalValidated(payloads(overlap, 'a', {x = 1, y = 2, z = 3}), {false, true})
      and plain_data.equalValidated(payloads(changedPrecedence, 'a', {x = 1, y = 2, z = 3}), {true, false})
      and plain_data.equalValidated(payloads(overlap, 'a', {x = 4, y = 5, z = 6}), {true, true}),
    'canonical target lookup changed overlapping patch order')
  local conflicting = {'*', 'a, (1, 2, 3)', {enabled = true}}
  expect(compile({a, conflicting}).actionIds[1] ~= compile({conflicting, a}).actionIds[1],
    'overlapping authored tuples lost semantic precedence')

  -- Real compiler output must reuse durable static work after harmless edits.
  local ledger_api = require('scripts.mom.ledger.ledger')
  local identity = require('scripts.mom.ledger.identity')
  local coordinator_api = require('scripts.mom.runtime.coordinator')
  local targetId = 'content:000001:morrowind.esm'
  local target = {
    id = '0x1',
    recordId = 'a',
    enabled = true,
    isValid = function() return true end,
  }
  local cellFacts = {
    id = 'Test Cell', idLower = 'test cell', key = 'test cell', interiorKey = 'test cell',
    name = 'Test Cell', nameLower = 'test cell', displayNameLower = 'test cell',
    isExterior = false, worldspaceKey = 'sys::default',
  }
  local captures, applies = 0, 0
  local driver = {
    id = 'modify_ref', abiVersion = 0, behaviorVersion = 0, programVersion = 0,
    revertTokenVersion = 0,
    matchesTarget = function() return true end,
    capture = function(_, live)
      captures = captures + 1
      return {enabled = live.enabled}
    end,
    apply = function(_, live)
      applies = applies + 1
      live.enabled = false
      return {status = 'applied', changedClaims = {'ref.enabled'}, outputs = {}}
    end,
    revert = function(token, live)
      live.enabled = token.enabled
      return {status = 'applied', changedClaims = {'ref.enabled'}, outputs = {}}
    end,
  }
  local function mockSession()
    local observed = {
      ['test cell'] = {handle = cellFacts, facts = cellFacts, routes = {'shared', 'interior:test cell'}},
    }
    local worldAdapter = {
      beginFrame = function() end,
      isValid = function(r) return r == target end,
      observedCells = function() return observed end,
      getObservedCell = function(k) return observed[k] end,
      isCellFenced = function() return false end,
      cellRefs = function() return {target}, nil end,
      describeRef = function()
        return {
          id = targetId, objectId = targetId, recordId = 'a', typeName = 'Static',
          position = {x = 1, y = 2, z = 3}, currentCell = cellFacts, cell = cellFacts,
          origin = {cellId = 'test cell', cell = cellFacts, position = {x = 1, y = 2, z = 3}},
        }, nil
      end,
      resolveTarget = function(id) return id == targetId and target or nil end,
      resolveCell = function() return cellFacts end,
    }
    return {
      world = worldAdapter,
      guardCapabilities = {},
      beginFrame = function() end,
      syncObservedCells = function() return {}, {} end,
      pollGuardEvents = function() return {} end,
      clear = function() end,
    }
  end
  local function openRuntime(manifest, savedLedger)
    local catalog = {
      actions = {byId = {modify_ref = {module = driver}}},
      guards = {byId = {}},
    }
    local bundle = assert(coordinator_api.prepareActivation({
      manifest = manifest, extensionCatalog = catalog,
    }))
    local ledger = savedLedger and assert(ledger_api.decode(savedLedger)) or ledger_api.new()
    local rt = assert(coordinator_api.new({
      activationBundle = bundle, ledger = ledger, session = mockSession(),
    }))
    rt.reconciler.enqueueCell('test cell')
    return rt
  end
  local original = openRuntime(first, nil)
  for frame = 1, 4 do assert(coordinator_api.tick(original, {frame = frame})) end
  local saved = assert(coordinator_api.saveSnapshot(original))
  expect(captures == 1 and applies == 1 and target.enabled == false,
    'tuple save fixture did not establish completed static work')
  expect(identity.semanticId(first.actionIds[1], targetId, nil)
      == identity.semanticId(reordered.actionIds[1], targetId, nil),
    'independent tuple reorder changed semantic operation id')
  local reopened = openRuntime(reordered, saved)
  for frame = 5, 8 do assert(coordinator_api.tick(reopened, {frame = frame})) end
  local savedAfter = assert(coordinator_api.saveSnapshot(reopened))
  expect(captures == 1 and applies == 1 and target.enabled == false
      and plain_data.equalValidated(saved.ops, savedAfter.ops),
    'independent tuple reorder repeated or rewrote saved static work')
end

local function sharedScalarNormalizationContract()
  expect(strings.isNonEmpty(' ') and not strings.isNonEmpty('')
      and not strings.isNonEmpty(false) and not strings.isNonEmpty(1),
    'string admission must stay strict and preserve whitespace')
  expect(strings.lowerString(false) == 'false'
      and strings.lowerString(12) == '12'
      and strings.lowerString(' A ') == ' a '
      and strings.lowerString('') == nil,
    'string normalization changed coercion, whitespace, or empty handling')
  local stringReads = 0
  local value = setmetatable({}, {__tostring = function()
    stringReads = stringReads + 1
    return 'MixedCase'
  end})
  expect(strings.lowerString(value) == 'mixedcase' and stringReads == 1,
    'string normalization must convert an object exactly once')

  expect(numbers.positiveInteger('4', 3) == 4
      and numbers.positiveInteger(nil, 3) == 3
      and numbers.positiveInteger(false, 3) == 3
      and numbers.positiveInteger('invalid', 3) == 3,
    'positive integer normalization changed conversion or fallback')
  expect(numbers.positiveInteger(0, 3) == nil
      and numbers.positiveInteger(-1, 3) == nil
      and numbers.positiveInteger(1.5, 3) == nil
      and numbers.positiveInteger(math.huge, 3) == nil
      and numbers.positiveInteger(0 / 0, 3) == nil
      and numbers.positiveInteger(nil, '3') == nil,
    'positive integer normalization accepted an invalid number or coerced its fallback')
  expect(numbers.isFinite(0) and numbers.isFinite(-1.5)
      and not numbers.isFinite('1') and not numbers.isFinite(math.huge)
      and not numbers.isFinite(-math.huge) and not numbers.isFinite(0 / 0),
    'finite number admission must reject coercion, infinities, and NaN')
end

local function sharedArrayComparisonContract()
  expect(tables.sameArray(nil, false) and tables.sameArray(false, {})
      and tables.sameArray({}, nil),
    'optional array comparison changed nil or false handling')
  expect(tables.sameArray({'a', false, 'b'}, {'a', false, 'b'})
      and not tables.sameArray({'a', 'b'}, {'b', 'a'})
      and not tables.sameArray({'a'}, {'a', 'b'}),
    'array comparison changed order, length, or false-element handling')
  local entry = {id = 'same'}
  expect(tables.sameArray({entry}, {entry})
      and not tables.sameArray({entry}, {{id = 'same'}}),
    'array comparison must preserve shallow element identity')
end

local function denseArrayValidationContract()
  expect(tables.isArray({}) and tables.isArray({false, 2, 3})
      and not tables.isArray({[2] = 2, [5] = 5})
      and not tables.isArray({[1] = 1, [3] = 3})
      and not tables.isArray({[1] = 1, extra = 2}),
    'array validation must reject sparse or mixed keys')
  local actions, actionError = source_variant_actions.collect('fixture', {
    actions = {[2] = {}, [5] = {}},
  }, {})
  expect(actions == nil and actionError == 'variants.fixture.actions: expected array',
    'sparse action lists must be rejected instead of silently dropping actions')
  local guards, guardError = source_variant_actions.collect('fixture', {
    guards = {{when = {{[1] = 'time', [3] = 'eq', [4] = 1}}, actions = {}}},
  }, {})
  expect(guards == nil and guardError:find('expected compact guard tuple', 1, true),
    'sparse guard tuples must be rejected before family lowering')

  for _, op in ipairs({'any', 'not'}) do
    local valid, validError = scalar_match.lowerScalarTuple(
      {'time', 'hour', op, {6, 18}}, 'guard', 3)
    expect(valid ~= nil and validError == nil and #valid[op] == 2,
      'dense guard values must remain accepted')
    for _, values in ipairs({{[1] = 6, extra = 18}, {[1] = 6, [3] = 18}, {[2] = 6, [5] = 18}}) do
      local result, err = scalar_match.lowerScalarTuple(
        {'time', 'hour', op, values}, 'guard', 3)
      expect(result == nil and err == 'guard[4]: expected numeric array',
        'guard values must reject sparse or mixed keys')
    end
  end
end

local CASES = {
  {'shared scalar normalization', sharedScalarNormalizationContract},
  {'shared array comparison', sharedArrayComparisonContract},
  {'dense array validation', denseArrayValidationContract},
  {'plain data', plainDataContract},
  {'canonical encoding', canonicalContract},
  {'semantic identity', semanticIdentityContract},
  {'final owner identity boundary', finalizedOwnerIdentityContract},
  {'keyed tuple identity and saved work', keyedTupleIdentityAndSavedWork},
  {'normalized source IR', normalizedSourceIrContract},
  {'source IR child ownership', sourceIrChildOwnershipContract},
  {'selector exclusion union ownership', selectorExclusionOwnershipContract},
  {'compiler accepted/rejected result', compilerResultContract},
  {'compiler diagnostic authored paths', compilerDiagnosticsUseAuthoredPaths},
  {'extension registry', registryContract},
  {'claim contract', claimSchemaContract},
  {'source manifest compiler', sourceManifestCompilerContract},
  {'manifest contract', manifestContract},
}

function M.run()
  return test_support.runCases('pure compiler', CASES)
end

return M
