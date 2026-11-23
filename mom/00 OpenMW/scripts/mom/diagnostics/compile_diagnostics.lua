-- Compile diagnostic collection and its detached compiler/status views.
-- Producers append records; consumers never inspect collector storage.
local M = {}

local plain_data = require('scripts.mom.contracts.plain_data')
local taxonomy = require('scripts.mom.diagnostics.taxonomy')
local copyMap = require('scripts.mom.common.tables').copyObject

local bounds = require('scripts.mom.diagnostics.bounds')
local DEFAULT_SAMPLE_LIMIT = bounds.SAMPLE_LIMIT
local COMPILE_LIMIT = bounds.SAMPLE_LIMIT

local function countKey(values, key)
  values[key] = (values[key] or 0) + 1
end

local boundedText = bounds.text

local Collector = {}
Collector.__index = Collector

function Collector:append(record)
  local ok, errors = taxonomy.validate(record)
  if not ok then return nil, errors end
  local normalized = {
    category = taxonomy.normalizeCategory(record.category),
    severity = taxonomy.normalizeSeverity(record.severity),
    phase = taxonomy.normalizePhase(record.phase),
    sourcePath = record.sourcePath,
    family = record.family,
    actionId = record.actionId,
    path = record.path,
    code = taxonomy.normalizeCode(record.code),
    message = record.message,
  }
  self.total = self.total + 1
  countKey(self.byCategory, normalized.category)
  countKey(self.bySeverity, normalized.severity)
  countKey(self.byPhase, normalized.phase)
  if #self.samples < self.sampleLimit then
    self.samples[#self.samples + 1] = copyMap(normalized)
  end
  return normalized, nil
end

function M.new(opts)
  opts = opts or {}
  return setmetatable({
    total = 0,
    byCategory = {},
    bySeverity = {},
    byPhase = {},
    samples = {},
    sampleLimit = tonumber(opts.sampleLimit) or DEFAULT_SAMPLE_LIMIT,
  }, Collector)
end

local function diagnosticSummary(collector)
  local samples = {}
  for i = 1, math.min(#collector.samples, COMPILE_LIMIT) do
    local sample = {}
    -- append owns the record fields. Optional metadata is intentionally
    -- stringified here, after the collector has applied its sampling policy.
    for field, value in pairs(collector.samples[i]) do
      sample[field] = boundedText(value)
    end
    samples[i] = sample
  end
  return {
    total = collector.total,
    byCategory = copyMap(collector.byCategory),
    bySeverity = copyMap(collector.bySeverity),
    byPhase = copyMap(collector.byPhase),
    samples = samples,
    samplesTruncated = collector.total > #samples,
  }
end

local function sourceSummary(attempts, states)
  -- Input validation can reject before source attempts have an array shape.
  attempts = type(attempts) == 'table' and attempts or {}
  states = states or {}
  local useAttempts = #states == 0
  local count = useAttempts and #attempts or #states
  local rows, failedCount = {}, 0
  for i = 1, #states do
    if states[i].failure ~= nil then failedCount = failedCount + 1 end
  end
  for i = 1, math.min(count, COMPILE_LIMIT) do
    local state = useAttempts and {} or states[i]
    local attempt = (useAttempts and attempts[i] or state.attempt) or {}
    local failed = state.failure or attempt.error or {}
    rows[i] = {
      path = attempt.sourcePath and boundedText(attempt.sourcePath)
        or attempt.path and boundedText(attempt.path) or nil,
      kind = attempt.kind and boundedText(attempt.kind) or nil,
      adapterId = attempt.adapterId and boundedText(attempt.adapterId) or nil,
      status = state.disposition or attempt.status,
      resolvedActions = state.actionCount
        or (type(attempt.actionCount) == 'number' and attempt.actionCount)
        or (type(attempt.actions) == 'table' and #attempt.actions)
        or 0,
      errorKind = failed.code and boundedText(failed.code)
        or failed.kind and boundedText(failed.kind) or nil,
      errorMessage = failed.message and boundedText(failed.message) or nil,
    }
  end
  return {
    count = count,
    rows = rows,
    rowsTruncated = count > COMPILE_LIMIT,
    failed = failedCount,
  }
end

-- Borrows compilation facts synchronously. No input is consumed or
-- retained; the collector can produce another report after further appends.
-- Invalid compiler facts raise an error at this internal boundary.
function M.forCompile(collector, facts)
  facts = facts or {}
  local manifest = facts.manifest
  local byFamily, byLifecycle, byScope = {}, {}, {}
  local actionIds = manifest and manifest.actionIds or {}
  local ownerIds = manifest and manifest.ownerIds or {}
  for i = 1, #actionIds do
    local action = manifest.actionsById[actionIds[i]]
    countKey(byFamily, action.family)
    countKey(byLifecycle, action.lifecycle)
    countKey(byScope, action.scope)
  end
  local previsitCells = 0
  for _ in pairs(manifest and manifest.indexes.previsitCells or {}) do
    previsitCells = previsitCells + 1
  end
  local summary = {
    total = #actionIds,
    byFamily = byFamily,
    byLifecycle = byLifecycle,
    byClassification = {
      static = byLifecycle.static or 0,
      state = byLifecycle.state or 0,
    },
    byScope = byScope,
    static = {
      actions = byLifecycle.static or 0,
      previsitCells = previsitCells,
    },
    state = {
      actions = byLifecycle.state or 0,
      owners = #ownerIds,
    },
    diagnostics = diagnosticSummary(collector),
    sources = sourceSummary(facts.sourceAttempts, facts.sourceStates),
    compileContext = facts.compileContext or {},
  }
  if manifest ~= nil then
    summary.manifest = {
      contentHash = manifest.contentHash,
      actions = #actionIds,
      owners = #ownerIds,
    }
  end
  local detached, errors = plain_data.detach({summary = summary}, {
    path = 'compileDiagnostics',
  })
  if detached == nil then
    error('compile diagnostics are invalid: '
      .. table.concat(errors or {}, ' | '), 0)
  end
  return detached
end

local function boundedArray(values, limit)
  local out = {}
  for i = 1, math.min(#(values or {}), limit) do out[i] = values[i] end
  return out, #(values or {}) > limit
end

local function boundedMap(values, limit)
  local keys, count = {}, 0
  for key in pairs(values or {}) do
    count = count + 1
    if #keys < limit then
      keys[#keys + 1] = key
      table.sort(keys)
    elseif #keys > 0 and key < keys[#keys] then
      keys[#keys] = key
      table.sort(keys)
    end
  end
  local out = {}
  for i = 1, #keys do out[keys[i]] = values[keys[i]] end
  return out, count > limit
end

-- Status takes a non-negative integer map/array limit and omits compiler metrics.
-- Returns view, truncated, errors. Missing diagnostics are not an error;
-- invalid plain data returns errors for the caller's status/error policy.
function M.forStatus(diagnostics, limit)
  if type(diagnostics) ~= 'table' then return nil, false, nil end
  local summary = type(diagnostics.summary) == 'table' and diagnostics.summary or {}
  local diagnostic = type(summary.diagnostics) == 'table' and summary.diagnostics or {}
  local sources = type(summary.sources) == 'table' and summary.sources or {}
  local byFamily, familyTruncated = boundedMap(summary.byFamily, limit)
  local byLifecycle, lifecycleTruncated = boundedMap(summary.byLifecycle, limit)
  local byScope, scopeTruncated = boundedMap(summary.byScope, limit)
  local byCategory, categoryTruncated = boundedMap(diagnostic.byCategory, limit)
  local bySeverity, severityTruncated = boundedMap(diagnostic.bySeverity, limit)
  local byPhase, phaseTruncated = boundedMap(diagnostic.byPhase, limit)
  local samples, samplesTruncated = boundedArray(diagnostic.samples, limit)
  local sourceRows, sourcesTruncated = boundedArray(sources.rows, limit)
  samplesTruncated = samplesTruncated or diagnostic.samplesTruncated == true
  sourcesTruncated = sourcesTruncated or sources.rowsTruncated == true
  local truncated = familyTruncated or lifecycleTruncated or scopeTruncated
    or categoryTruncated or severityTruncated or phaseTruncated
    or samplesTruncated or sourcesTruncated
    or summary.diagnosticsTruncated == true
  local detached, errors = plain_data.detach({
    summary = {
      total = summary.total,
      byFamily = byFamily,
      byLifecycle = byLifecycle,
      byClassification = summary.byClassification,
      byScope = byScope,
      static = summary.static,
      state = summary.state,
      manifest = summary.manifest,
      diagnostics = {
        total = diagnostic.total,
        byCategory = byCategory,
        bySeverity = bySeverity,
        byPhase = byPhase,
        samples = samples,
        samplesTruncated = samplesTruncated,
      },
      sources = {
        count = sources.count,
        failed = sources.failed,
        rows = sourceRows,
        rowsTruncated = sourcesTruncated,
      },
      diagnosticsTruncated = truncated,
    },
  }, {path = 'compileDiagnostics'})
  return detached, truncated, errors
end

return M
