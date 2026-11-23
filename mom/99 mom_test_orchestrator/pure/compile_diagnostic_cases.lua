local M = {}

local compile_diagnostics = require('scripts.mom.diagnostics.compile_diagnostics')
local plain_data = require('scripts.mom.contracts.plain_data')
local test_support = require('pure.test_support')
local expect = test_support.expect

local function same(actual, expected, message)
  expect(plain_data.equalValidated(actual, expected), message)
end

local function fields(value, names)
  local allowed = {}
  for name in names:gmatch('%S+') do
    allowed[name] = true
    expect(value[name] ~= nil, 'report omitted ' .. name)
  end
  for name in pairs(value) do
    expect(allowed[name], 'report exposed unexpected field ' .. tostring(name))
  end
end

local function record(index)
  return {
    category = 'import-warning', severity = 'warn', phase = 'import',
    sourcePath = 'fixture.yaml', code = 'Fixture-' .. index,
    message = 'warning ' .. index,
  }
end

local function status(value, limit)
  local report, truncated, errors = compile_diagnostics.forStatus(value, limit or 8)
  expect(report ~= nil and errors == nil, 'status projection failed')
  expect(plain_data.validate(report), 'status report is not detached plain data')
  return report, truncated
end

local function recordGrammarAndSamplingIsolation()
  local collector = compile_diagnostics.new()
  local input = record(1)
  input.category, input.severity, input.phase = 'Config-Invalid', 'ERROR', 'Load'
  input.code = 'Source-Identity-Invalid'
  input.family, input.actionId, input.path = 'fixture', 'action', 'variants.fixture'
  input.ignored = function() end
  local normalized = assert(collector:append(input))
  expect(normalized.code == 'source_identity_invalid', 'append changed code grammar')
  local expected = {
    category = 'config-invalid', severity = 'error', phase = 'load',
    sourcePath = 'fixture.yaml', family = 'fixture', actionId = 'action',
    path = 'variants.fixture', code = 'source_identity_invalid', message = 'warning 1',
  }
  same(normalized, expected, 'append changed diagnostic record fields')
  input.message, normalized.message = 'input changed', 'return changed'
  for _, invalid in ipairs({{}, {category = 'unknown'}, {message = ''}}) do
    local rejected, errors = collector:append(invalid)
    expect(rejected == nil and #errors > 0, 'invalid record was counted')
  end
  local first = compile_diagnostics.forCompile(collector)
  local diagnostic = first.summary.diagnostics
  same(diagnostic.samples[1], expected, 'sample aliases append input or return')
  expect(diagnostic.total == 1 and diagnostic.byCategory['config-invalid'] == 1
      and diagnostic.bySeverity.error == 1 and diagnostic.byPhase.load == 1,
    'normalization or validation changed exact counts')
  diagnostic.samples[1].message = 'report changed'
  diagnostic.byPhase.load = 100
  local second = compile_diagnostics.forCompile(collector)
  same(second.summary.diagnostics.samples[1], expected, 'report mutated collection')
  expect(second.summary.diagnostics.byPhase.load == 1, 'report mutated counts')
end

local function collectionAndCompileLimitsAreIndependent()
  for _, sampleLimit in ipairs({0, 2, 8, 12}) do
    local collector = compile_diagnostics.new({sampleLimit = sampleLimit})
    for i = 1, 10 do
      local value = record(i)
      if i % 2 == 0 then
        value.category, value.severity, value.phase = 'config-invalid', 'error', 'load'
      end
      assert(collector:append(value))
    end
    local report = compile_diagnostics.forCompile(collector)
    local diagnostic = report.summary.diagnostics
    expect(diagnostic.total == 10 and diagnostic.byCategory['config-invalid'] == 5
        and diagnostic.byCategory['import-warning'] == 5
        and diagnostic.bySeverity.error == 5 and diagnostic.bySeverity.warn == 5
        and diagnostic.byPhase.load == 5 and diagnostic.byPhase.import == 5,
      'collection limit changed exact totals')
    expect(#diagnostic.samples == math.min(sampleLimit, 8)
        and diagnostic.samplesTruncated == true,
      'compiler limit replaced collection policy or lost prior truncation')
    for i, sample in ipairs(diagnostic.samples) do
      expect(sample.code == 'fixture_' .. i, 'diagnostic sample order changed')
    end
    assert(collector:append(record(11)))
    expect(diagnostic.total == 10
        and compile_diagnostics.forCompile(collector).summary.diagnostics.total == 11,
      'snapshot consumed the collector or retained its mutable state')
  end
end

local function optionalMetadataAndTextBounds()
  local collector = compile_diagnostics.new()
  local longText = string.rep('x', 4096)
  local value = record(1)
  local metadata = setmetatable({}, {__tostring = function() return longText end})
  value.sourcePath, value.family, value.actionId = metadata, false, 42
  value.path, value.message = function() end, longText
  assert(collector:append(value))
  local compiled = compile_diagnostics.forCompile(collector)
  local sample = compiled.summary.diagnostics.samples[1]
  expect(sample.sourcePath == longText:sub(1, 2048) .. '...'
      and sample.message == sample.sourcePath
      and sample.family == 'false' and sample.actionId == '42'
      and sample.path == tostring(value.path),
    'report tightened optional metadata validation or changed text encoding')
  local projected, truncated = status(compiled)
  expect(truncated == false
      and projected.summary.diagnostics.samplesTruncated == false,
    'text elision changed the meaning of count-truncation flags')
end

local function compilationFacts()
  local manifest = {
    contentHash = 'fixture-manifest', actionIds = {}, actionsById = {},
    ownerIds = {'owner-a', 'owner-b'}, indexes = {previsitCells = {a = true, b = true}},
  }
  for i = 1, 10 do
    local id = 'action-' .. i
    manifest.actionIds[i] = id
    manifest.actionsById[id] = {
      family = string.format('family_%02d', i),
      lifecycle = i <= 4 and 'static' or 'state',
      scope = i <= 3 and 'cell' or 'ref',
      program = {runtimeOnly = function() end},
    }
  end
  local states = {}
  for i = 1, 10 do
    local failed = i % 2 == 0
    states[i] = {
      attempt = {
        path = 'fallback-' .. i, sourcePath = 'source-' .. i, kind = 'native',
        adapterId = 'native', status = 'resolved', actionCount = 99,
        error = {kind = 'old_error', message = 'old message'},
      },
      disposition = failed and 'failed' or 'accepted', actionCount = i,
      failure = failed and {code = 'source_failed', message = string.rep('m', 4096)} or nil,
      prepared = {runtimeOnly = function() end},
    }
  end
  return {manifest = manifest, sourceStates = states,
    compileContext = {cellIndexesBuilt = 2, modelPathCacheHits = 3}}
end

local function compilationSummaryBorrowsFacts()
  local collector = compile_diagnostics.new()
  local facts = compilationFacts()
  local compiled = compile_diagnostics.forCompile(collector, facts)
  expect(plain_data.validate(compiled), 'compiler report retained executable input')
  local summary = compiled.summary
  fields(summary, 'total byFamily byLifecycle byClassification byScope static state '
    .. 'diagnostics sources compileContext manifest')
  expect(summary.total == 10 and summary.byFamily.family_10 == 1
      and summary.manifest.contentHash == 'fixture-manifest'
      and summary.manifest.actions == 10 and summary.manifest.owners == 2,
    'compiler lost complete manifest counts')
  same(summary.byLifecycle, {static = 4, state = 6}, 'lifecycle counts changed')
  same(summary.byClassification, {static = 4, state = 6}, 'classification changed')
  same(summary.byScope, {cell = 3, ref = 7}, 'scope counts changed')
  same(summary.static, {actions = 4, previsitCells = 2}, 'static facts changed')
  same(summary.state, {actions = 6, owners = 2}, 'state facts changed')
  expect(summary.sources.count == 10 and summary.sources.failed == 5
      and #summary.sources.rows == 8 and summary.sources.rowsTruncated,
    'source summary used bounded rows to calculate totals')
  for i, row in ipairs(summary.sources.rows) do
    fields(row, 'path kind adapterId status resolvedActions errorKind errorMessage')
    expect(row.path == 'source-' .. i and row.resolvedActions == i,
      'source row precedence or source order changed')
  end
  expect(summary.sources.rows[2].status == 'failed'
      and summary.sources.rows[2].errorKind == 'source_failed'
      and #summary.sources.rows[2].errorMessage == 2051,
    'source disposition or failure message bounds changed')
  facts.manifest.contentHash = 'changed'
  facts.sourceStates[1].attempt.sourcePath = 'changed'
  facts.compileContext.cellIndexesBuilt = 99
  expect(summary.manifest.contentHash == 'fixture-manifest'
      and summary.sources.rows[1].path == 'source-1'
      and summary.compileContext.cellIndexesBuilt == 2,
    'compiler report shares source facts')
  local watched = setmetatable({facts, facts.manifest, facts.sourceStates,
    facts.compileContext}, {__mode = 'v'})
  facts = nil
  collectgarbage('collect')
  collectgarbage('collect')
  expect(next(watched) == nil, 'report or collector retained the compilation facts')
end

local function earlyRejectionUsesSourceAttempts()
  local attempts, states = {}, {}
  for i = 1, 10 do
    attempts[i] = {
      path = 'source-' .. i, status = 'failed', actions = {1, 2},
      error = {kind = 'load_failed', message = 'unavailable'},
    }
  end
  local collector = compile_diagnostics.new()
  local report = compile_diagnostics.forCompile(collector, {
    sourceAttempts = attempts, sourceStates = states,
  })
  local summary = report.summary
  expect(summary.manifest == nil and summary.total == 0
      and summary.sources.count == 10 and summary.sources.failed == 0
      and #summary.sources.rows == 8 and summary.sources.rowsTruncated,
    'early rejection changed source availability or invented compiled failures')
  expect(summary.sources.rows[1].path == 'source-1'
      and summary.sources.rows[1].resolvedActions == 2
      and summary.sources.rows[1].status == 'failed'
      and summary.sources.rows[1].errorKind == 'load_failed',
    'early rejection lost attempt fallbacks')
  expect(next(states) == nil and #attempts[1].actions == 2,
    'reporting mutated borrowed compiler source inputs')
  local empty = compile_diagnostics.forCompile(collector)
  expect(empty.summary.sources.count == 0 and #empty.summary.sources.rows == 0,
    'empty rejection invented sources')
  for _, invalid in ipairs({'not-an-array', true, 42}) do
    local rejected = compile_diagnostics.forCompile(collector, {
      sourceAttempts = invalid, sourceStates = {},
    })
    expect(rejected.summary.sources.count == 0
        and #rejected.summary.sources.rows == 0,
      'malformed source input prevented an early rejection report')
  end
end

local function statusSelectsMapsAndAllowedFields()
  local values, samples, rows = {}, {}, {}
  for i = 10, 1, -1 do
    values[string.format('key_%02d', i)] = i
    samples[i], rows[i] = {code = 'sample-' .. i}, {path = 'source-' .. i}
  end
  local input = {summary = {
    total = 55, byFamily = values, byLifecycle = values, byScope = values,
    byClassification = {static = 20, state = 35},
    static = {actions = 20}, state = {actions = 35}, manifest = {actions = 55},
    compileContext = {compilerOnly = function() end}, ignored = function() end,
    diagnostics = {total = 55, byCategory = values, bySeverity = values,
      byPhase = values, samples = samples, ignored = true},
    sources = {count = 10, failed = 3, rows = rows, ignored = true},
  }}
  local report, truncated = status(input)
  local summary = report.summary
  fields(summary, 'total byFamily byLifecycle byClassification byScope static state '
    .. 'diagnostics sources manifest diagnosticsTruncated')
  fields(summary.diagnostics, 'total byCategory bySeverity byPhase samples samplesTruncated')
  fields(summary.sources, 'count failed rows rowsTruncated')
  for _, map in ipairs({summary.byFamily, summary.byLifecycle, summary.byScope,
      summary.diagnostics.byCategory, summary.diagnostics.bySeverity,
      summary.diagnostics.byPhase}) do
    local expected = {}
    for i = 1, 8 do expected[string.format('key_%02d', i)] = i end
    same(map, expected, 'status map selection depends on iteration order')
  end
  expect(truncated and summary.total == 55 and summary.diagnostics.total == 55
      and summary.sources.count == 10 and summary.sources.failed == 3
      and #summary.diagnostics.samples == 8 and #summary.sources.rows == 8,
    'status limits changed totals or ignored cardinality')
  for i = 1, 8 do
    expect(summary.diagnostics.samples[i].code == 'sample-' .. i
        and summary.sources.rows[i].path == 'source-' .. i,
      'status projection changed sample or source order')
  end
  local before = assert(plain_data.detach(report))
  values.key_01 = 100
  rows[1].path = 'changed'
  samples[1].code = 'changed'
  input.summary.byClassification.static = 100
  same(report, before, 'status view aliases input data')
  report.summary.byFamily.key_01 = 200
  expect(report.summary.byLifecycle.key_01 == 1, 'status count maps share storage')
  local zero = status(input, 0)
  expect(next(zero.summary.byFamily) == nil and #zero.summary.sources.rows == 0,
    'zero status limit retained samples')
end

local function truncationSurvivesRepeatedProjection()
  local inputs = {
    {summary = {diagnostics = {total = 20, samples = {{code = 'one'}},
      samplesTruncated = true}}},
    {summary = {sources = {count = 20, rows = {{path = 'one'}}, rowsTruncated = true}}},
    {summary = {diagnosticsTruncated = true}},
    {summary = {byFamily = {a = 1, b = 1}}},
  }
  for _, input in ipairs(inputs) do
    local report, truncated = status(input, 1)
    expect(truncated and report.summary.diagnosticsTruncated,
      'status omitted an existing truncation reason')
    for _ = 1, 3 do
      local repeated, againTruncated = status(report, 8)
      same(repeated, report, 'reprojection lost fields or truncation evidence')
      expect(againTruncated, 'reprojection erased aggregate truncation')
      report = repeated
    end
  end
end

local function invalidPlainDataUsesTheReportErrorContract()
  local missing, truncated, errors = compile_diagnostics.forStatus(nil, 8)
  expect(missing == nil and truncated == false and errors == nil,
    'missing diagnostic report became an error')
  local cyclic = {}
  cyclic.self = cyclic
  for _, invalid in ipairs({{callback = function() end}, cyclic,
      setmetatable({}, {})}) do
    local value, _, projectionErrors = compile_diagnostics.forStatus({
      summary = {diagnostics = {samples = {invalid}}},
    }, 8)
    expect(value == nil and type(projectionErrors) == 'table' and #projectionErrors > 0,
      'invalid status data escaped the structured error result')
  end
  local ok, compileError = pcall(compile_diagnostics.forCompile,
    compile_diagnostics.new(), {compileContext = cyclic})
  expect(not ok and tostring(compileError):find('compile diagnostics are invalid:', 1, true),
    'invalid compiler facts stopped being a compiler programming error')
end

function M.run()
  return test_support.runCases('pure compile diagnostics', {
    {'record grammar and isolated sampling', recordGrammarAndSamplingIsolation},
    {'independent collection and compile limits', collectionAndCompileLimitsAreIndependent},
    {'optional metadata and bounded text', optionalMetadataAndTextBounds},
    {'detached compilation facts', compilationSummaryBorrowsFacts},
    {'early rejection source attempts', earlyRejectionUsesSourceAttempts},
    {'bounded detached status fields', statusSelectsMapsAndAllowedFields},
    {'repeated projection truncation', truncationSurvivesRepeatedProjection},
    {'invalid plain data error contract', invalidPlainDataUsesTheReportErrorContract},
  })
end

return M
