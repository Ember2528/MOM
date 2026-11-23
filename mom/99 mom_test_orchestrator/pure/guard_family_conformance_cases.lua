package.preload['openmw.core'] = package.preload['openmw.core'] or function()
  return {}
end

local canonical = require('scripts.mom.contracts.canonical')
local guards_runtime = require('scripts.mom.runtime.guards')
local guard_plugin_api = require('scripts.mom.contracts.guard_plugin')
local guard_program = require('scripts.mom.compiler.guard_program')
local plain_data = require('scripts.mom.contracts.plain_data')

local M = {}

local test_support = require('pure.test_support')
local expect = test_support.expect

local MODULES = {
  quest_stage = require('scripts.mom.guards.quest_stage'),
  time = require('scripts.mom.guards.time'),
  weather = require('scripts.mom.guards.weather'),
  ['harness.toggle'] = require('scripts.mom.guards.harness.toggle'),
}

local ENV = {guardEvent = guard_plugin_api.guardEvent}

local function registry(module)
  return {byId = {[module.id] = {
    id = module.id,
    abiVersion = module.abiVersion,
    behaviorVersion = module.behaviorVersion,
    programVersion = module.programVersion,
    module = module,
  }}}
end

local function evaluate(module, program, capabilities)
  local ownerId = 'owner:' .. module.id
  local manifest = {
    ownerIds = {ownerId},
    ownersById = {
      [ownerId] = {
        id = ownerId,
        guard = {
          op = 'all',
          fragments = {{
            family = module.id,
            abiVersion = module.abiVersion,
            behaviorVersion = module.behaviorVersion,
            programVersion = module.programVersion,
            program = program,
          }},
        },
        actionIds = {},
        subscriptions = {},
      },
    },
    indexes = {ownersByEvent = {}},
  }
  local rt = assert(guards_runtime.new(manifest, registry(module)))
  rt.evaluateDue(1, capabilities)
  return {state = rt.truth(ownerId)}
end

local function moduleAndCompileContract()
  local specs = {
    quest_stage = {type = 'quest_stage', questId = 'A1_1_FindSpymaster', stage = {min = 50}},
    time = {type = 'time', hour = {eq = 12}},
    weather = {type = 'weather', region = 'Bitter Coast Region', scriptId = {eq = 1}},
    ['harness.toggle'] = {type = 'harness.toggle', key = 'door', expected = true},
  }
  for id, module in pairs(MODULES) do
    expect(module.id == id and module.abiVersion == 0
        and type(module.behaviorVersion) == 'number'
        and module.programVersion == 0
        and type(module.lowerTuple) == 'function'
        and type(module.compileProgram) == 'function'
        and type(module.evaluate) == 'function'
        and module.compile == nil,
      'guard module ABI is incomplete: ' .. id)
    local first = module.compileProgram(specs[id], ENV)
    local second = module.compileProgram(specs[id], ENV)
    expect(plain_data.validate(first, {path = id .. '.compiled'}) == true
        and canonical.assertHash(first) == canonical.assertHash(second)
        and type(first.program) == 'table'
        and type(first.subscriptions) == 'table' and #first.subscriptions == 1,
      'guard compile output is impure or nondeterministic: ' .. id)
    local compiled, subscriptions, errors = guard_program.compile({specs[id]}, id, registry(module))
    expect(compiled ~= nil and errors == nil and subscriptions[1] == first.subscriptions[1],
      'shared guard compiler rejected family: ' .. id)
  end
end

local function builtInTruthContract()
  local time = MODULES.time
  local timeProgram = {type = 'time', hour = {eq = 12}}
  expect(evaluate(time, timeProgram, {readTime = function() return {hour = 12} end}).state == 'active',
    'time guard did not evaluate active')
  expect(evaluate(time, timeProgram, {readTime = function() return {hour = 13} end}).state == 'inactive',
    'time guard did not evaluate inactive')
  expect(evaluate(time, timeProgram, {readTime = function() return {} end}).state == 'unknown',
    'malformed time snapshot became known false')

  local weather = MODULES.weather
  local weatherProgram = {type = 'weather', region = 'Bitter Coast Region', scriptId = {eq = 1}}
  expect(evaluate(weather, weatherProgram, {
    readWeather = function() return {scriptId = 1} end,
  }).state == 'active', 'weather guard did not evaluate active')
  expect(evaluate(weather, weatherProgram, {
    readWeather = function() return {scriptId = 2} end,
  }).state == 'inactive', 'weather guard did not evaluate inactive')
  expect(evaluate(weather, weatherProgram, {
    readWeather = function() return {} end,
  }).state == 'unknown', 'malformed weather snapshot became known false')

  local quest = MODULES.quest_stage
  local questProgram = {type = 'quest_stage', questId = 'A1_1_FindSpymaster', stage = {min = 50}}
  expect(evaluate(quest, questProgram, {
    readQuestStage = function() return 60 end,
  }).state == 'active', 'quest guard did not evaluate active')
  expect(evaluate(quest, questProgram, {
    readQuestStage = function() return 10 end,
  }).state == 'inactive', 'quest guard did not evaluate inactive')
  expect(evaluate(quest, questProgram, {
    readQuestStage = function() return nil, 'snapshot-pending' end,
  }).state == 'unknown', 'unavailable quest state became inactive')
  expect(evaluate(quest, questProgram, {
    readQuestStage = function() return nil, 'quest-not-active' end,
  }).state == 'inactive', 'known absent quest did not evaluate inactive')
end

local function unavailableAndProviderFailureContract()
  local programs = {
    quest_stage = {type = 'quest_stage', questId = 'quest', stage = {eq = 1}},
    time = {type = 'time', hour = {eq = 1}},
    weather = {type = 'weather', region = 'region', scriptId = {eq = 1}},
  }
  for id, program in pairs(programs) do
    expect(evaluate(MODULES[id], program, {}).state == 'unknown',
      'missing provider did not produce unknown: ' .. id)
  end
  expect(evaluate(MODULES.time, programs.time, {
    readTime = function() error('synthetic provider failure') end,
  }).state == 'unknown', 'provider exception escaped tri-state guard boundary')
end

local function recurringDateRangeYearCaps()
  local time = MODULES.time
  local function check(from, to, mode, year, month, day, expected)
    local program, err = time.lowerTuple(
      {'time', 'date', 'range', from, to, mode}, 'guard'
    )
    assert(program, err)
    local result = evaluate(time, program, {
      readTime = function() return {year = year, month = month, day = day} end,
    })
    expect(result.state == expected,
      string.format('date range returned %s for %d-%02d-%02d; expected %s',
        result.state, year, month, day, expected))
  end
  check({year = 427, month = 4, day = 1}, {month = 4, day = 30}, 'inclusive', 426, 4, 15, 'inactive')
  check({year = 427, month = 4, day = 1}, {month = 4, day = 30}, 'inclusive', 427, 3, 31, 'inactive')
  check({year = 427, month = 4, day = 1}, {month = 4, day = 30}, 'inclusive', 427, 4, 1, 'active')
  check({year = 427, month = 4, day = 1}, {month = 4, day = 30}, 'inclusive', 427, 4, 30, 'active')
  check({year = 427, month = 4, day = 1}, {month = 4, day = 30}, 'exclusive', 427, 4, 30, 'inactive')
  check({year = 427, month = 4, day = 1}, {month = 4, day = 30}, 'inclusive', 428, 4, 15, 'active')
  check({year = 427, month = 4, day = 1}, {month = 4, day = 30}, 'inclusive', 428, 7, 1, 'inactive')
  check({month = 4, day = 1}, {year = 427, month = 4, day = 30}, 'inclusive', 426, 4, 15, 'active')
  check({month = 4, day = 1}, {year = 427, month = 4, day = 30}, 'exclusive', 427, 4, 30, 'inactive')
  check({month = 4, day = 1}, {year = 427, month = 4, day = 30}, 'inclusive', 428, 4, 15, 'inactive')
  check({year = 427, month = 12, day = 1}, {month = 2, day = 28}, 'inclusive', 427, 1, 15, 'inactive')
  check({year = 427, month = 12, day = 1}, {month = 2, day = 28}, 'inclusive', 427, 12, 1, 'active')
  check({year = 427, month = 12, day = 1}, {month = 2, day = 28}, 'inclusive', 428, 1, 15, 'active')
  check({month = 12, day = 1}, {year = 427, month = 2, day = 28}, 'inclusive', 426, 12, 15, 'active')
  check({month = 12, day = 1}, {year = 427, month = 2, day = 28}, 'inclusive', 427, 12, 15, 'inactive')
end

local function timeGuardArrayValidation()
  local time = MODULES.time
  local badDates = {[1] = {month = 4, day = 1}, extra = {month = 4, day = 2}}
  local badSeasons = {[1] = 'spring', [3] = 'summer'}
  local dates, dateError = time.lowerTuple({'time', 'date', 'any', badDates}, 'guard')
  local seasons, seasonError = time.lowerTuple({'time', 'season', 'any', badSeasons}, 'guard')
  expect(dates == nil and dateError:find('array', 1, true)
      and seasons == nil and seasonError:find('array', 1, true),
    'time guard accepted a mixed or sparse any list')
end

local function externalGuardReadsAuthorityNotPayload()
  local module = MODULES['harness.toggle']
  local program = {type = 'harness.toggle', key = 'door', expected = true}
  local current = true
  local capabilities = {
    eventPayload = {key = 'door', value = false},
    providers = {
      ['harness.toggle'] = {
        read = function() return current end,
      },
    },
  }
  expect(evaluate(module, program, capabilities).state == 'active',
    'external guard used stale event payload instead of provider truth')
  current = false
  expect(evaluate(module, program, capabilities).state == 'inactive',
    'external guard did not reread authoritative provider state')
  capabilities.providers = nil
  expect(evaluate(module, program, capabilities).state == 'unknown',
    'missing external provider did not hold unknown')
end

local function keyedEventDispatchWakesOnlySubscribedOwners()
  local manifest = {
    ownerIds = {'a', 'b', 'c'},
    ownersById = {
      a = {
        id = 'a',
        guard = {op = 'all', fragments = {{family = 'quest_stage', program = {questId = 'Quest A', stage = {min = 10}}}}},
        actionIds = {},
        subscriptions = {'questStageChanged'},
      },
      b = {
        id = 'b',
        guard = {op = 'all', fragments = {{family = 'quest_stage', program = {questId = 'Quest B', stage = {min = 10}}}}},
        actionIds = {},
        subscriptions = {'questStageChanged'},
      },
      c = {
        id = 'c',
        guard = {op = 'all', fragments = {{family = 'weather', program = {region = 'Bitter Coast', scriptId = {eq = 1}}}}},
        actionIds = {},
        subscriptions = {'weatherChanged'},
      },
    },
    indexes = {
      ownersByEvent = {
        questStageChanged = {'a', 'b'},
        weatherChanged = {'c'},
      },
    },
  }
  local rt = assert(guards_runtime.new(manifest, {
    byId = {
      quest_stage = {module = MODULES.quest_stage},
      weather = {module = MODULES.weather},
    },
  }))
  expect(rt.watchWeather == true and rt.watchTime == false,
    'guard runtime did not derive watch flags from subscriptions')
  local reads = {}
  local caps = {
    readQuestStage = function(q) reads[q] = (reads[q] or 0) + 1; return 10 end,
    readWeather = function(r) reads[r] = (reads[r] or 0) + 1; return {scriptId = 1} end,
  }
  rt.evaluateDue(1, caps)
  reads = {}
  rt.dispatchEvent('questStageChanged:quest a')
  local res = rt.evaluateDue(2, caps)
  expect(res.evaluated >= 1 and reads['Quest A'] == 1 and reads['Bitter Coast'] == nil,
    'quest event unexpectedly woke unrelated weather owner')
end

local CASES = {
  {'module and compile contract', moduleAndCompileContract},
  {'built-in truth contract', builtInTruthContract},
  {'provider failure contract', unavailableAndProviderFailureContract},
  {'recurring date range year caps', recurringDateRangeYearCaps},
  {'time guard array validation', timeGuardArrayValidation},
  {'external authoritative reads', externalGuardReadsAuthorityNotPayload},
  {'keyed event dispatch wakes subscribed owners', keyedEventDispatchWakesOnlySubscribedOwners},
}

function M.run()
  return test_support.runCases('pure guard conformance', CASES)
end

return M
