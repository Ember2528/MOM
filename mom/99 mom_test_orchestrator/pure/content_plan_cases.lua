local M = {}
local planner = require('scripts.mom.compiler.content.planner')
local executor = require('scripts.mom.compiler.content.executor')
local schema = require('scripts.mom.compiler.content.schema')
local contract = require('scripts.mom.contracts.content_plan')
local plain_data = require('scripts.mom.contracts.plain_data')
local canonical = require('scripts.mom.contracts.canonical')
local test_support = require('pure.test_support')
local expect = test_support.expect
local function copy(value) return assert(plain_data.detach(value)) end

-- Mutable wrappers intentionally resolve by ID after every assignment, just
-- like OpenMW MutableRecord. Copy assignment snapshots hidden/raw fields too.
local function store(initial, options)
  options = options or {}
  local data, writes, events = copy(initial), 0, {}
  local wrapperTags = setmetatable({}, {__mode = 'k'})
  local function wrapper(id)
    if not data[id] then return nil end
    local value = setmetatable({}, {__index = function(_, key) return data[id] and data[id][key] end})
    wrapperTags[value] = id
    return value
  end
  local records = setmetatable({}, {
    __index = function(_, key) return wrapper(key) end,
    __newindex = function(_, key, value)
      writes = writes + 1
      events[#events + 1] = {id = key, delete = value == nil}
      local isTemp = key:match('^mom__content_') ~= nil
      if options.fail and options.fail(key, value, writes, isTemp) then error('synthetic record write failure') end
      if value == nil then data[key] = nil; return end
      local raw
      if wrapperTags[value] then raw = copy(assert(data[wrapperTags[value]]))
      else
        raw = value.template and copy(assert(data[wrapperTags[value.template]])) or {}
        for field, item in pairs(value) do if field ~= 'template' then raw[field] = copy(item) end end
      end
      raw.id = key
      data[key] = raw
      if options.after then options.after(key, data[key], data) end
    end,
  })
  return records, data, function() return writes, events end
end
local function fixture(options)
  local statics, staticData, staticWrites = store({a = {id = 'a', model = 'meshes/a.nif', hidden = 817},
    b = {id = 'b', model = 'meshes/b.nif', hidden = 919}}, options)
  local books, bookData = store({book = {id = 'book', name = 'Old', text = 'Original', weight = 1,
    model = 'meshes/book.nif', hidden = 234}})
  local lists, listData = store({animals = {id = 'animals', creatures = {{id = 'rat', level = 1},
    {id = 'rat', level = 1}, {id = 'scrib', level = 2}}, chanceNone = 0.29,
    calculateFromAllLevels = false, rawChance = 177, hiddenFlags = 8192},
    nested = {id = 'nested', creatures = {{id = 'rat', level = 1}}, chanceNone = 0.1}}, options and options.list)
  return {content = {statics = {records = statics}, books = {records = books},
    levelledCreatures = {records = lists}}, staticData = staticData, bookData = bookData,
    listData = listData, staticWrites = staticWrites}
end
local function record(id, model, priority)
  return {kind = 'record', source = 'test:' .. id, priority = priority,
    payload = {type = 'Static', id = id, patch = {model = model}}}
end
local function list(operations, patch, id)
  return {kind = 'leveled', source = 'test:list', payload = {type = 'CreatureLevelledList',
    id = id or 'animals', operations = operations, patch = patch}}
end
local function compile(nodes, f)
  local plan, errors = planner.compile(nodes, {content = f.content})
  expect(plan ~= nil, errors and table.concat(errors, '\n'))
  expect(contract.validate(plan), 'planner emitted invalid plain-data plan')
  return plan
end
local function purePlanAndFullCopy()
  local f = fixture()
  local original = canonical.assertHash(f.staticData)
  local plan = compile({record('a', 'new.nif')}, f)
  expect(f.staticWrites() == 0 and original == canonical.assertHash(f.staticData), 'planning changed engine content')
  expect(plan.writes[1].patch.model == 'meshes/new.nif' and plan.metrics.changedCount == 1)
  local result = executor.execute(plan, {content = f.content})
  expect(result.status == 'committed' and result.changedCount == 1)
  expect(f.staticData.a.model == 'meshes/new.nif' and f.staticData.a.hidden == 817)
  for id in pairs(f.staticData) do expect(not id:match('^mom__content_'), 'temporary record leaked') end
end
local function capabilityAndFieldErrors()
  local f = fixture()
  local plan, errors = planner.compile({{kind = 'record', source = 'creature',
    payload = {type = 'Creature', id = 'rat', patch = {model = 'x.nif'}}}}, {content = f.content})
  expect(plan == nil and errors[1]:find('unsupported type', 1, true))
  plan, errors = planner.compile({{kind = 'leveled', source = 'items',
    payload = {type = 'ItemLevelledList', id = 'items', operations = {}}}}, {content = f.content})
  expect(plan == nil and errors[1]:find('levelledItems.records is unavailable', 1, true))
  plan = planner.compile({{kind = 'record', payload = {type = 'Static', id = 'a', patch = {weight = 2}}}}, {content = f.content})
  expect(plan == nil and f.staticWrites() == 0)
end
local function createAndDependencies()
  local f = fixture()
  local plan = compile({{kind = 'record', source = 'new book', payload = {type = 'Book', id = 'new_book',
    template = 'book', create = true, patch = {name = 'New', text = 'New text'}}}}, f)
  expect(executor.execute(plan, {content = f.content}).status == 'committed')
  expect(f.bookData.new_book.text == 'New text' and f.bookData.new_book.hidden == 234 and f.bookData.book.text == 'Original')
  local rejected = planner.compile({{kind = 'record', payload = {type = 'Static', id = 'new_a', template = 'a',
    create = true, patch = {model = 'one.nif'}}}, {kind = 'record', payload = {type = 'Static', id = 'new_b',
    template = 'new_a', create = true, patch = {model = 'two.nif'}}}}, {content = f.content})
  expect(rejected == nil, 'same-plan template chain was accepted')
end
local function listWeightAndFlags()
  local f = fixture()
  local plan = compile({list({{op = 'append', entries = {{id = 'rat', level = 1}}},
    {op = 'add_if_absent', entries = {{id = 'rat', level = 1}, {id = 'rat', level = 3}}}})}, f)
  expect(plan.metrics.unverifiedMembers == 2 or plan.metrics.unverifiedMembers == 3)
  expect(executor.execute(plan, {content = f.content}).status == 'committed')
  local data = f.listData.animals
  expect(#data.creatures == 5 and data.creatures[1].id == 'rat' and data.creatures[4].id == 'rat')
  expect(data.rawChance == 177 and data.hiddenFlags == 8192 and data.chanceNone == 0.29,
    'entry edits changed raw flags/chance')
  local nextPlan = compile({list({{op = 'replace', match = {id = 'rat', level = 1},
    entries = {{id = 'scrib', level = 4}}}, {op = 'remove', match = {id = 'rat'}}})}, f)
  expect(executor.execute(nextPlan, {content = f.content}).status == 'committed')
  expect(#f.listData.animals.creatures == 2 and f.listData.animals.creatures[1].level == 4
    and f.listData.animals.creatures[2].level == 2)
end
local function priorityAndNoop()
  local f = fixture()
  local plan = compile({record('a', 'same.nif', 1), record('a', 'last.nif', 2)}, f)
  expect(plan.writes[1].patch.model == 'meshes/last.nif')
  local bad = planner.compile({record('a', 'one.nif'), record('a', 'two.nif')}, {content = f.content})
  expect(bad == nil, 'equal-priority field conflict was accepted')
  local noop = compile({record('a', 'a.nif')}, f)
  expect(executor.execute(noop, {content = f.content}).status == 'noop' and f.staticWrites() == 0)
end
local function newCycleRejected()
  local f = fixture()
  local bad, errors = planner.compile({list({{op = 'append', entries = {{id = 'nested', level = 1}}}}),
    list({{op = 'append', entries = {{id = 'animals', level = 1}}}}, nil, 'nested')}, {content = f.content})
  expect(bad == nil and table.concat(errors, ' '):find('cyclic list reference', 1, true))
end
local function failureRestoresDetachedOriginal()
  local failed = false
  local f = fixture({fail = function(id, value, _, temporary)
    if id == 'b' and value ~= nil and not temporary and not failed then failed = true; return true end
  end})
  local plan = compile({record('a', 'changed_a.nif'), record('b', 'changed_b.nif')}, f)
  local result = executor.execute(plan, {content = f.content})
  expect(result.status == 'restored_failure' and result.attemptedWrites == 2,
    'failed commit was not restored: ' .. result.status)
  expect(f.staticData.a.model == 'meshes/a.nif' and f.staticData.a.hidden == 817,
    'original mutable handle aliased the replacement during rollback')
  expect(f.staticData.b.model == 'meshes/b.nif')
  for id in pairs(f.staticData) do expect(not id:match('^mom__content_'), 'rollback leaked temporary record') end
end
local function stagingAndCleanupFailure()
  local f = fixture({fail = function(id) return id:match('_stage$') ~= nil end})
  local plan = compile({record('a', 'changed.nif')}, f)
  local result = executor.execute(plan, {content = f.content})
  expect(result.status == 'rejected' and f.staticData.a.model == 'meshes/a.nif')
  local f2 = fixture({fail = function(id, value) return id:match('_backup$') ~= nil and value == nil end})
  local plan2 = compile({record('a', 'changed.nif')}, f2)
  local result2 = executor.execute(plan2, {content = f2.content})
  expect(result2.status == 'partial' and #result2.cleanupErrors > 0 and f2.staticData.a.model == 'meshes/changed.nif')
end
local function staleBaselineAndTamper()
  local f = fixture()
  local plan = compile({record('a', 'changed.nif')}, f)
  f.staticData.a.model = 'meshes/external.nif'
  local result = executor.execute(plan, {content = f.content})
  expect(result.status == 'rejected' and f.staticWrites() == 0)
  local f2 = fixture()
  local plan2 = compile({record('a', 'changed.nif')}, f2)
  plan2.writes[1].patch.model = 'meshes/forged.nif'
  expect(executor.execute(plan2, {content = f2.content}).status == 'rejected' and f2.staticWrites() == 0)
end

local function stableIdentityAndAuthoredOrder()
  local f = fixture()
  local first = record('a', 'changed.nif')
  local moved = record('a', 'changed.nif')
  moved.source = 'a/different/config.yaml'
  local a, b = compile({first}, f), compile({moved}, f)
  expect(a.contentHash == b.contentHash and a.integrityHash ~= b.integrityHash,
    'source provenance changed semantic content identity')
  local firstList = list({{op = 'set', entries = {{id = 'rat', level = 10}}}})
  firstList.source = 'same.yaml#actions[2]'
  local secondList = list({{op = 'append', entries = {{id = 'scrib', level = 11}}}})
  secondList.source = 'same.yaml#actions[10]'
  local ordered = compile({firstList, secondList}, f)
  local entries = ordered.writes[1].patch.creatures
  expect(#entries == 2 and entries[1].id == 'rat' and entries[2].id == 'scrib',
    'diagnostic source spelling reordered authored list operations')
end
local function malformedPlansAndInput()
  local f = fixture()
  local plan = compile({record('a', 'changed.nif')}, f)
  plan.writes = {named = plan.writes[1]}
  expect(executor.execute(plan, {content = f.content}).status == 'rejected' and f.staticWrites() == 0)
  local invalid = planner.compile({list({{op = 'append', entries = {{id = 'rat', level = 65536}}}})}, {content = f.content})
  expect(invalid == nil)
  local modelFailure, errors = planner.compile({record('a', 'missing.nif')}, {
    content = f.content, modelExists = function() return false, nil, 'missing test model' end})
  expect(modelFailure == nil and table.concat(errors, ' '):find('missing test model', 1, true))
  expect(f.staticWrites() == 0)
end
local function createdRecordRollback()
  local failed = false
  local f = fixture({fail = function(id, value, _, temporary)
    if id == 'b' and value ~= nil and not temporary and not failed then failed = true; return true end
  end})
  local plan = compile({{kind = 'record', source = 'created first', payload = {type = 'Static',
    id = 'a_created', template = 'a', create = true, patch = {}}}, record('b', 'changed.nif')}, f)
  expect(executor.execute(plan, {content = f.content}).status == 'restored_failure')
  expect(f.staticData.a_created == nil and f.staticData.b.model == 'meshes/b.nif',
    'failed transaction retained newly created public record')
end
local function numericStorageSemantics()
  local lights, lightData = store({lamp = {id = 'lamp', color = 16777215, radius = 2000000}})
  local books, bookData = store({book = {id = 'book', value = 2000000, enchantCapacity = 1.2}}, {
    after = function(id, row)
      if id:match('_stage$') then
        local stored = math.floor(schema.float32(row.enchantCapacity) * 10 + 0.5)
        row.enchantCapacity = schema.float32(schema.float32(stored) * schema.float32(0.1))
      end
    end,
  })
  local content = {lights = {records = lights}, books = {records = books}}
  local plan, errors = planner.compile({
    {kind = 'record', payload = {type = 'Light', id = 'lamp', patch = {color = 16777214, radius = 2000001}}},
    {kind = 'record', payload = {type = 'Book', id = 'book', patch = {value = 2000001, enchantCapacity = 1.25}}},
  }, {content = content})
  expect(plan, errors and table.concat(errors, ' | '))
  expect(plan.metrics.changedCount == 2 and plan.writes[1].patch.enchantCapacity == 1.3,
    'integer changes or capacity normalization were lost')
  expect(executor.execute(plan, {content = content}).status == 'committed')
  expect(lightData.lamp.color == 16777214 and lightData.lamp.radius == 2000001
    and bookData.book.value == 2000001 and schema.equal('enchantCapacity', bookData.book.enchantCapacity, 1.3),
    'native numeric storage semantics were not applied')
  expect(not schema.equal('color', 16777215, 16777214)
    and not schema.equal('duration', 2000000, 2000001)
    and not schema.equal('maxCondition', 2000000, 2000001), 'integer comparison used float tolerance')
  expect(schema.equal('weight', 0.1, 0.100000001), 'float round-trip tolerance disappeared')
  expect(not schema.unchanged('enchantCapacity', 1000000, 1000000.1), 'representable capacity edit was lost')
  expect(not schema.unchanged('weight', 1000000, 1000000.0625)
    and not schema.unchanged('quality', 1, 1.0000001192092896), 'representable float32 edit was lost')
  expect(schema.value('capacity', 0.35, 'capacity') == 0.4, 'capacity half-step normalization changed')
  expect(schema.value('capacity', 214748352, 'capacity') == 214748352)
  local invalid = planner.compile({{kind = 'record', payload = {type = 'Book', id = 'book',
    patch = {enchantCapacity = 214748364.7}}}}, {content = content})
  expect(invalid == nil, 'capacity outside safe native storage range was accepted')
end
local function probabilityStorageSemantics()
  local records, data = store({list = {id = 'list', creatures = {{id = 'rat', level = 1}}, chanceNone = 0.5}}, {
    after = function(id, row)
      if id:match('_stage$') then row.chanceNone = math.floor(row.chanceNone * 100) / 100 end
    end,
  })
  local content = {levelledCreatures = {records = records}}
  for _, case in ipairs({{0, 0}, {0.29, 0.29}, {0.57, 0.57}, {0.58, 0.58},
      {0.335, 0.33}, {0.999, 0.99}, {1, 1}}) do
    local plan, errors = planner.compile({{kind = 'leveled', payload = {type = 'CreatureLevelledList',
      id = 'list', patch = {chanceNone = case[1]}}}}, {content = content})
    expect(plan, errors and table.concat(errors, ' | '))
    expect(plan.writes[1].patch.chanceNone == case[2], 'probability did not normalize to decimal hundredths')
    local result = executor.execute(plan, {content = content})
    expect(result.status == 'committed', 'probability draft did not round-trip: ' .. table.concat(result.errors, ' | '))
    expect(data.list.chanceNone == case[2], 'probability was truncated into an adjacent stored percent')
  end
end

local CASES = {
  {'pure planning and full-copy preservation', purePlanAndFullCopy},
  {'capabilities and typed fields', capabilityAndFieldErrors},
  {'named creation and dependency rejection', createAndDependencies},
  {'list weighting order and raw field preservation', listWeightAndFlags},
  {'field priority conflicts and noops', priorityAndNoop},
  {'new list cycles rejected', newCycleRejected},
  {'commit restores detached originals', failureRestoresDetachedOriginal},
  {'staging rejection and cleanup failure', stagingAndCleanupFailure},
  {'stale baselines and tampered plans', staleBaselineAndTamper},
  {'stable identity and authored list order', stableIdentityAndAuthoredOrder},
  {'malformed plans and missing models', malformedPlansAndInput},
  {'created record rollback', createdRecordRollback},
  {'integer precision and book capacity storage', numericStorageSemantics},
  {'probability storage conversion', probabilityStorageSemantics},
}
function M.run() return test_support.runCases('pure content plan', CASES) end
return M
