local M = {}
local support = require('pure.test_support')
local expect = support.expect
local backend = require('scripts.mom.compiler.content.compile')
local schema = require('scripts.mom.compiler.content.schema')
local vfr = require('scripts.mom.compat.vfr.leveled_creatures')

local function fixture()
  return {statics = {records = {a = {id = 'a', model = 'meshes/a.nif'},
    b = {id = 'b', model = 'meshes/b.nif'}}},
    activators = {records = {a = {id = 'a', model = 'meshes/a.nif'}}},
    levelledCreatures = {records = {animals = {id = 'animals', creatures = {{id = 'rat', level = 1}}}}}}
end
local function aggregate(actions)
  return {sourceAttempts = {{status = 'resolved', path = 'scripts/mom/config/mixed.yaml', actions = actions}}}
end
local function model(source, target, types)
  return {family = 'place_ref', diagnosticId = 'typed model', children = {}, spec = {
    disableOriginal = true, select = {type = types or 'Static'}, attach = {{'*', source, target}}}}
end
local function accepted(actions, content, options)
  options = options or {}; options.content = content
  local plan, errors = backend.compile(aggregate(actions), options)
  expect(plan ~= nil, errors and table.concat(errors, ' | '))
  return plan
end
function M.run()
  return support.runCases('LOAD content backend', {
    {'selected definitions are planned without mutation', function()
      local content = fixture()
      local plan = accepted({{family = 'record_content', spec = {record = {type = 'Static', id = 'a',
        patch = {model = 'new.nif'}}}}, {family = 'leveled_content', spec = {leveled = {
        type = 'CreatureLevelledList', id = 'animals', operations = {{op = 'append',
          entries = {{id = 'scrib', level = 2}}}}}}}}, content)
      expect(#plan.writes == 2 and content.statics.records.a.model == 'meshes/a.nif'
        and #content.levelledCreatures.records.animals.creatures == 1, 'backend wrote engine content')
    end},
    {'uniform exact records resolve only their declared types', function()
      local content = fixture()
      local plan = accepted({model('a', 'other.nif')}, content)
      expect(#plan.writes == 1 and plan.writes[1].type == 'Static'
        and plan.writes[1].id == 'a' and plan.writes[1].patch.model == 'meshes/other.nif', 'typed source widened')
      expect(plan.metrics.recordQueries == 1 and next(plan.metrics.recordCatalogScans) == nil, 'exact ID built mesh index')
    end},
    {'uniform mesh resolution uses one pre-edit catalog', function()
      local content = fixture()
      local plan = accepted({model('meshes/a.nif', 'meshes/b.nif'), model('meshes/b.nif', 'meshes/c.nif')}, content)
      expect(#plan.writes == 2 and plan.writes[1].id == 'a' and plan.writes[1].patch.model == 'meshes/b.nif'
        and plan.writes[2].id == 'b' and plan.writes[2].patch.model == 'meshes/c.nif'
        and plan.metrics.recordCatalogScans.Static == 1 and plan.metrics.recordQueries == 2,
        'model rewrite cascaded through mutated content or rescanned its catalog')
      expect(content.statics.records.a.model == 'meshes/a.nif', 'model compilation mutated baseline')
    end},
    {'record exclusions are resolved in LOAD and may exclude every match', function()
      local content = fixture()
      content.statics.records.b.model = 'meshes/a.nif'
      local action = model('meshes/a.nif', 'other.nif')
      action.spec.filters = {{'exclude', 'B'}}
      action.spec.chance, action.spec.previsit = 1, false
      local plan = accepted({action}, content)
      expect(#plan.writes == 1 and plan.writes[1].id == 'a', 'record exclusion widened or became runtime work')
      action.spec.filters = {{'exclude', 'a'}, {'exclude', 'b'}}
      plan = accepted({action}, content)
      expect(#plan.writes == 0 and plan.metrics.recordCatalogScans.Static == 1,
        'fully excluded definition was rejected or created writes')
      expect(content.statics.records.a.model == 'meshes/a.nif', 'exclusion mutated input content')
      action.spec.filters = {{'exclude', false}}
      local rejected, errors = backend.compile(aggregate({action}), {content = content})
      expect(rejected == nil and errors[1]:find('exclude ids must be strings', 1, true),
        'selected backend did not validate exclusion arguments')
    end},
    {'missing and ambiguous matches fail in the selected backend', function()
      local content = fixture()
      local bad, errors = backend.compile(aggregate({model('missing', 'x.nif')}), {content = content})
      expect(bad == nil and errors[1]:find('matches no LOAD records', 1, true), 'missing record fell through')
      bad, errors = backend.compile(aggregate({model('a', 'x.nif', {'Static', 'Activator'})}), {content = content})
      expect(bad == nil and errors[1]:find('ambiguous', 1, true), 'ambiguous ID chose a type')
      content.statics = nil
      bad, errors = backend.compile(aggregate({model('a', 'x.nif')}), {content = content})
      expect(bad == nil and errors[1]:find('statics.records is unavailable', 1, true), 'capability error changed owner')
    end},
    {'resolved overlaps and model conflicts are LOAD errors', function()
      local content = fixture()
      local action = model('a', 'b.nif')
      action.spec.attach[2] = {'*', 'meshes/a.nif', 'b.nif'}
      local bad, errors = backend.compile(aggregate({action}), {content = content})
      expect(bad == nil and errors[1]:find('overlap', 1, true), 'overlapping rows were accepted')
      bad, errors = backend.compile(aggregate({model('a', 'b.nif'), model('meshes/a.nif', 'c.nif')}), {content = content})
      expect(bad == nil and errors[1]:find('conflicting equal-priority', 1, true), 'resolved model conflicts were silently ordered')
    end},
    {'asset and type validation never supplies a runtime fallback', function()
      local content = fixture()
      local selected = aggregate({model({recordId = 'a', type = 'Static'}, 'missing.nif')})
      local bad, errors = backend.compile(selected, {content = content, modelExists = function() return false, nil, 'absent mesh' end})
      expect(bad == nil and errors[1]:find('absent mesh', 1, true)
        and #selected.sourceAttempts[1].actions == 1, 'asset failure mutated source or supplied fallback')
      expect(not schema.array({[1] = true, [3] = true}), 'sparse backend arrays were admitted')
    end},
    {'tuple exclusions and record queries narrow definition writes', function()
      local content = fixture()
      content.statics.records.b.model = 'meshes/a.nif'
      local action = model('a.nif', 'other.nif')
      action.spec.attach[1][4] = {'exclude', 'b'}
      local plan = accepted({action}, content)
      expect(#plan.writes == 1 and plan.writes[1].id == 'a', 'row exclusion was widened')
      action.spec.attach[1][4] = nil
      action.spec.select.recordId = {match = 'b*'}
      plan = accepted({action}, content)
      expect(#plan.writes == 1 and plan.writes[1].id == 'b', 'base-record query was not applied')
      action.spec.select.recordId = 'unmatched'
      expect(#accepted({action}, content).writes == 0, 'empty record restriction became a missing-source error')
      local scripted = model('a', 'other.nif', 'Activator')
      scripted.spec.select.mwscript = 'target_script'
      content.activators.records.a.mwscript = 'TARGET_SCRIPT'
      expect(#accepted({scripted}, content).writes == 1, 'MWScript restriction ignored its record field')
      scripted.spec.select.mwscript = 'other_script'
      expect(#accepted({scripted}, content).writes == 0, 'MWScript query widened to unrelated scripts')
    end},
    {'constant choice can edit a supported item definition', function()
      local content = fixture()
      content.ingredients = {records = {herb = {id = 'herb', model = 'meshes/a.nif'}}}
      local action = model('herb', 'other.nif', 'Ingredient')
      action.spec.attach[1][3] = {choose = {{'unused.nif', 0}, {'other.nif', 2}}}
      local plan = accepted({action}, content)
      expect(#plan.writes == 1 and plan.writes[1].type == 'Ingredient'
        and plan.writes[1].patch.model == 'meshes/other.nif', 'constant choice was rejected by runtime transfer policy')
      expect(content.ingredients.records.herb.model == 'meshes/a.nif', 'choice planning mutated content')
    end},
    {'optional targets use an explicit common policy', function()
      local content = fixture()
      local action = {family = 'leveled_content', spec = {onMissingTarget = 'skip', leveled = {
        type = 'CreatureLevelledList', id = 'absent', operations = {{op = 'merge_by_id',
          entries = {{id = 'rat', level = 3}}}}}}}
      local plan = accepted({action}, content)
      expect(#plan.writes == 0 and plan.metrics.skippedCount == 1
        and plan.diagnostics[1].code == 'optional_target_unavailable', 'missing optional list was not diagnosed')
      content.levelledCreatures = nil
      expect(accepted({action}, content).metrics.skippedCount == 1, 'missing optional binding became fatal')
      action.spec.leveled.type = 'Creature'
      local unsupported, unsupportedErrors = backend.compile(aggregate({action}), {content = content})
      expect(unsupported == nil and unsupportedErrors[1]:find('unsupported type', 1, true),
        'optional target policy hid an unsupported definition operation')
      action.spec.leveled.type, action.spec.onMissingTarget = 'CreatureLevelledList', nil
      local bad, errors = backend.compile(aggregate({action}), {content = content})
      expect(bad == nil and errors[1]:find('is unavailable', 1, true), 'native missing-target default was relaxed')
    end},
    {'composition ordering scopes batch priorities without changing native list state', function()
      local content = fixture()
      content.levelledCreatures.records.animals.creatures = {{id = 'rat', level = 1},
        {id = 'rat', level = 2}, {id = 'base', level = 3}}
      local function edit(level, priority, compositionOrder)
        return {family = 'leveled_content', priority = priority, compositionOrder = compositionOrder,
          spec = {leveled = {type = 'CreatureLevelledList', id = 'animals', operations = {
            {op = 'merge_by_id', entries = {{id = 'rat', level = level}}}}}}}
      end
      local native = edit(4, 99)
      local early = edit(9, 0, {1, -10, 'b.yaml', 1})
      local late = edit(11, 0, {1, 10, 'a.yaml', 1})
      -- Discovery order is deliberately unrelated to the declared composition.
      local plan = accepted({late, native, early}, content)
      local entries = plan.writes[1].patch.creatures
      expect(#entries == 3 and entries[1].level == 11 and entries[2].level == 11
        and entries[3].id == 'base' and entries[3].level == 3,
        'foreign batch priority escaped its scope or coalesced existing duplicates')
      expect(plan.writes[1].patch.chanceNone == nil and plan.writes[1].patch.calculateFromAllLevels == nil,
        'entry-only composition overwrote untouched flags')
      local earlierName = edit(13, 0, {1, 10, '0.yaml', 1})
      entries = accepted({earlierName, late}, content).writes[1].patch.creatures
      expect(entries[1].level == 11, 'equal-priority modules lost canonical path order')
    end},
    {'VFR list declarations use the common source and content stages', function()
      local raw = {priority = 2, injections = {{list = 'animals', add = {{id = 'rat', level = 9},
        {id = 'scrib', level = 2}}}}}
      local actions = assert(vfr.translate(raw, 'scripts/variationframework/leveled_creatures/data/test.yaml'))
      expect(#actions == 1 and actions[1].spec.leveled ~= nil and actions[1].familyInput == nil,
        'list adapter bypassed ordinary actions')
      local normalized = assert(require('scripts.mom.compiler.action_frontend').normalize(aggregate(actions).sourceAttempts,
        {activeContent = {}}))
      local content = fixture()
      local plan, errors = backend.compile({sourceAttempts = normalized}, {content = content})
      expect(plan ~= nil, errors and table.concat(errors, ' | '))
      expect(#plan.writes == 1 and plan.writes[1].patch.creatures[1].id == 'rat'
        and plan.writes[1].patch.creatures[1].level == 9 and plan.writes[1].patch.creatures[2].id == 'scrib',
        'common list planner changed VFR merge-by-ID meaning')
      expect(content.levelledCreatures.records.animals.creatures[1].level == 1,
        'translation or common planning changed installed content')
    end},
  })
end
return M
