-- Compiler orchestration uses tiny authored sources. No installed-source or
-- engine-world traversal is needed to prove atomic publication and boundaries.
local support = require('pure.test_support')
local expect = support.expect
local compiler = require('scripts.mom.compiler.compile_sources')
local source_ir = require('scripts.mom.compiler.source_ir')
local source_lowering = require('scripts.mom.compiler.source_lowering')
local bootstrap = require('scripts.mom.compiler.bootstrap_config')
local compile_context = require('scripts.mom.compiler.compile_context')
local cell_index = require('scripts.mom.compiler.cell_index')
local record_index = require('scripts.mom.compiler.record_index')
local vfs = require('openmw.vfs')
local world = require('openmw.world')
local M = {}

local function catalog()
  local family = {
    id = 'fixture', abiVersion = 0, behaviorVersion = 0, programVersion = 0,
    publicFields = {'modify'}, behavior = {scope = 'ref'},
    prepareAction = function(spec) return spec end,
    compileAction = function(spec, context)
      local probe = spec.payload
      if probe.lowerFailure then return nil, {'fixture lowering failed'} end
      if probe.cell then context.requireCellIndex() end
      if probe.record then context.requireRecordContext() end
      if probe.model then context.modelExists('meshes/fixture.nif') end
      return {source_ir.familyProgram({
        id = spec.id, program = {value = probe.value},
      }, {claims = {keys = {'ref.enabled'}}, reversible = true,
        candidateTypes = {Miscellaneous = true}})}
    end,
    validateProgram = function() end,
    validateStoredState = function() return true end,
  }
  return {
    kind = 'mom-extension-catalog',
    actions = {kind = 'action', ids = {'fixture'}, byId = {fixture = {
      id = 'fixture', abiVersion = 0, behaviorVersion = 0, programVersion = 0,
      module = family,
    }}},
    guards = {kind = 'guard', ids = {}, byId = {}},
    compat = {kind = 'compat', ids = {}, byId = {}},
  }
end

local function source(id, payload)
  local path = 'fixture/' .. id .. '.yaml'
  return {
    kind = 'native', native = true, adapterId = 'native',
    path = path, sourcePath = path, status = 'resolved',
    actions = {source_ir.sourceAction({modify = payload or {value = id}}, {
      family = 'fixture', diagnosticId = id,
      source = {adapterId = 'native', file = path, path = {'actions', 1}},
    })},
  }
end

local function rejected(result, code, failed)
  expect(result.status == 'rejected' and result.manifest == nil
      and result.fatal.code == code and result.diagnostics.summary.manifest == nil
      and result.diagnostics.summary.sources.failed == failed,
    'compiler published partial authority or misclassified rejection: '
      .. tostring(result.fatal and result.fatal.message))
end

local function atomicSourceSet()
  local accepted = compiler.compile({sourceAttempts = {source('a'), source('b')}}, catalog())
  expect(accepted.status == 'accepted' and #accepted.manifest.actionIds == 2,
    'injected family did not produce both manifest programs')
  for _, mode in ipairs({'load', 'prepare', 'lower', 'aggregate', 'duplicate'}) do
    local first, second = source('a'), source('b')
    if mode == 'load' then
      second.status, second.actions = 'failed', nil
      second.error = {status = 'load_error', kind = 'fixture', message = 'missing'}
    elseif mode == 'prepare' then
      second.actions[1].kind = 'invalid'
    elseif mode == 'lower' then
      second = source('b', {lowerFailure = true})
    elseif mode == 'aggregate' then
      second = source('b', {value = 'a'})
    elseif mode == 'duplicate' then
      second.path = first.path:gsub('/', '\\'):upper()
      second.sourcePath = second.path
    end
    local result = compiler.compile({sourceAttempts = {first, second}}, catalog())
    rejected(result, mode == 'aggregate' and 'manifest_rejected' or 'source_set_rejected',
      mode == 'aggregate' and 0 or 1)
  end
end

local function malformedInputs()
  for _, value in ipairs({1, {sourceAttempts = 1}, {version = 2, actions = {}}}) do
    local ok, result = pcall(compiler.compile, value)
    expect(ok and result.status == 'rejected'
        and result.fatal.code == 'source_attempts_required',
      'malformed compiler input escaped structured rejection')
  end
end

local function missingSourceHasOneDiagnostic()
  local previous, oldOpen = vfs.fileExists, vfs.open
  vfs.fileExists = function() return false end
  vfs.open = function() return nil, "fixture source missing" end
  local ok, err = pcall(function()
    local extensions = catalog()
    local input = bootstrap.loadAggregated({
      configSources = {{path = 'missing-fixture.yaml', native = true}},
      usingExplicitList = true,
    }, {catalog = extensions})
    local result = compiler.compile(input, extensions)
    rejected(result, 'source_set_rejected', 1)
    local diagnostics = result.diagnostics.summary.diagnostics
    expect(diagnostics.total == 1 and diagnostics.byPhase.load == 1
        and diagnostics.byCategory['source-load-failed'] == 1,
      'bootstrap and compiler duplicated one missing-source diagnostic')
  end)
  vfs.fileExists, vfs.open = previous, oldOpen
  if not ok then error(err, 0) end
end

local function fatalDiagnosticsAreBounded()
  local sources = {}
  for i = 1, 9 do
    sources[i] = source(tostring(i))
    sources[i].status, sources[i].actions = 'failed', nil
    sources[i].error = {status = 'load_error', kind = 'fixture',
      message = i == 1 and string.rep('x', 2100) or 'missing'}
  end
  local result = compiler.compile({sourceAttempts = sources}, catalog())
  rejected(result, 'source_set_rejected', 9)
  expect(result.fatal.errorCount == 9 and #result.fatal.errors == 8
      and result.fatal.errorsTruncated == true,
    'compiler fatal errors lost their bounded sample or full count')
  for _, message in ipairs(result.fatal.errors) do
    expect(#message <= 2051, 'compiler retained an unbounded fatal message')
  end
end

local function contextUsesOnlyDemandedHostFacts()
  local oldCell, oldRecord, oldExists = cell_index.build, record_index.build, vfs.fileExists
  local calls, generation = {cell = 0, record = 0, model = 0}, 1
  cell_index.build = function()
    calls.cell = calls.cell + 1
    return {generation = generation}
  end
  record_index.build = function()
    calls.record = calls.record + 1
    return {generation = generation}
  end
  vfs.fileExists = function()
    calls.model = calls.model + 1
    return generation == 1
  end
  local ok, err = pcall(function()
    for _, attempts in ipairs({{}, {source('independent')}}) do
      expect(compiler.compile({sourceAttempts = attempts}, catalog()).status == 'accepted',
        'selection-independent compile failed')
    end
    expect(calls.cell + calls.record + calls.model == 0, 'compiler eagerly requested host facts')
    for _, field in ipairs({'cell', 'record', 'model'}) do
      local before = {cell = calls.cell, record = calls.record, model = calls.model}
      local result = compiler.compile({sourceAttempts = {source(field, {[field] = true})}}, catalog())
      expect(result.status == 'accepted', 'dependent fixture failed compilation')
      for key, count in pairs(calls) do
        expect(count - before[key] == (field == key and 1 or 0),
          'compiler requested unrelated host facts')
      end
    end
    local first = assert(compile_context.build())
    local cells, records = first.requireCellIndex(), first.requireRecordContext()
    expect(first.modelExists('meshes/fixture.nif') == true, 'first model fact missing')
    generation = 2
    expect(first.requireCellIndex() == cells and cells.generation == 1
        and first.requireRecordContext() == records and records.generation == 1
        and first.modelExists('meshes/fixture.nif') == true,
      'one attempt did not preserve stable host facts')
    local second = assert(compile_context.build())
    expect(second.requireCellIndex().generation == 2
        and second.requireRecordContext().generation == 2
        and second.modelExists('meshes/fixture.nif') == false,
      'a later attempt reused stale host facts')
  end)
  cell_index.build, record_index.build, vfs.fileExists = oldCell, oldRecord, oldExists
  if not ok then error(err, 0) end
end

local function familyProgram(fields)
  fields = fields or {}
  local program = {
    kind = 'mom-family-program',
    spec = {
      id = 'malformed-family-result',
      program = {},
    },
    claims = {keys = {'fixture.claim'}},
    reversible = true,
  }
  for key, value in pairs(fields) do program[key] = value end
  return program
end

local function malformedFamilyResultsAreRejected()
  local actionModule = {
    publicFields = {'fixture'},
    prepareAction = function(input) return input end,
    validateProgram = function() end,
  }
  local catalog = {
    actions = {
      byId = {
        fixture = {module = actionModule},
      },
    },
  }
  local prepared = {{
    kind = 'mom-prepared-action',
    family = 'fixture',
    diagnosticId = 'malformed-family-result',
    input = {
      id = 'malformed-family-result',
      verb = 'fixture', payloadKind = 'direct', payload = {},
    },
    source = {},
    children = {},
  }}
  local cases = {
    {label = 'malformed resolved selection', rows = function() return {familyProgram({resolvedSelection = {}})} end, expected = 'resolvedSelection.'},
    {
      label = 'metatable result array',
      rows = function() return setmetatable({}, {}) end,
      expected = 'metatables are not allowed',
    },
    {
      label = 'sparse result array',
      rows = function() return {[2] = familyProgram()} end,
      expected = 'expected a dense array',
    },
    {
      label = 'map result container',
      rows = function() return {row = familyProgram()} end,
      expected = 'expected a dense array index',
    },
    {
      label = 'unknown family-program field',
      rows = function()
        return {familyProgram({unexpected = true})}
      end,
      expected = 'unexpected: field is not allowed',
    },
    {
      label = 'invalid selection-fact type',
      rows = function()
        return {familyProgram({candidateTypes = 'NPC'})}
      end,
      expected = 'candidateTypes: expected object',
    },
  }
  for i = 1, #cases do
    local case = cases[i]
    actionModule.compileAction = function() return case.rows(), nil end
    local normalized, errors = source_lowering.lowerActions(
      assert(require('scripts.mom.contracts.plain_data').detach(prepared)),
      {recordCtx = {}, cellIndex = {}},
      catalog
    )
    expect(normalized == nil
        and type(errors) == 'table'
        and tostring(errors[1]):find(case.expected, 1, true),
      case.label .. ' crossed the source-lowering family boundary')
  end
end

local function cellIndexUsesFixedCollectionBounds()
  local rows = {
    {id = 'Cell A', name = 'Cell A', isExterior = false},
    {id = 'Cell B', name = 'Cell B', isExterior = false},
  }
  local lengths = 0
  local cells = setmetatable({rows[1], rows[2]}, {
    __len = function()
      lengths = lengths + 1
      return #rows
    end,
    __index = function()
      error('cell index probed outside the collection bounds', 0)
    end,
    __ipairs = function()
      error('cell index delegated its fixed bounds to an engine iterator', 0)
    end,
  })
  local previous = world.cells
  world.cells = cells
  local ok, index = pcall(cell_index.build)
  world.cells = previous
  expect(ok, 'fixed cell collection traversal failed: ' .. tostring(index))
  -- LuaJIT uses the table's raw array size; Luau honors __len on tables.
  expect(lengths <= 1 and index.totalCount == 2
      and index.byKey['cell a'] ~= nil and index.byKey['cell b'] ~= nil,
    'cell index did not traverse every entry within one size snapshot')
end

function M.run()
  return support.runCases('compiler pipeline', {
    {'current sources publish atomically', atomicSourceSet},
    {'malformed compiler inputs reject', malformedInputs},
    {'family results validate at lowering boundary', malformedFamilyResultsAreRejected},
    {'missing source has one diagnostic', missingSourceHasOneDiagnostic},
    {'fatal errors retain bounded samples', fatalDiagnosticsAreBounded},
    {'context demands and attempt lifetime', contextUsesOnlyDemandedHostFacts},
    {'cell index uses fixed collection bounds', cellIndexUsesFixedCollectionBounds},
  })
end
return M
