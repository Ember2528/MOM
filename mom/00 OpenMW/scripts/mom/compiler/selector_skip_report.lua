-- Aggregates selector-unresolved diagnostics for one action-family compile.
-- Emits compact warnings with bounded samples.
local M = {}

local diagnostic_emit = require('scripts.mom.compiler.diagnostic_emit')
local log = require('scripts.mom.diagnostics.log')

local DEFAULT_SAMPLE_LIMIT = 3

local function diagnosticsCollector(report)
  return report and report.diagnosticCollector or nil
end

local function sourcePath(report)
  return report and report.sourcePath or nil
end

local function sourcePrefix(report)
  return report and report.sourcePrefix or ''
end

function M.new(opts)
  opts = opts or {}
  local diagnostics = opts.diagnostics or {}
  local reportSourcePath = opts.sourcePath or diagnostics.sourcePath
  return {
    family = opts.family,
    actionId = tostring(opts.actionId or 'action'),
    verb = tostring(opts.verb or 'action'),
    diagnosticCollector = opts.diagnosticCollector or diagnostics.diagnosticCollector,
    sourcePath = reportSourcePath,
    sourcePrefix = diagnostic_emit.sourceLogPrefix(reportSourcePath),
    warnTag = opts.warnTag or 'compile',
    code = opts.code or 'selector_unresolved',
    sampleLimit = tonumber(opts.sampleLimit) or DEFAULT_SAMPLE_LIMIT,
    total = 0,
    order = {},
    byReason = {},
  }
end

function M.record(report, path, target, label, reason)
  if not report then return false end
  label = tostring(label or 'target')
  reason = tostring(reason or 'unknown')
  diagnostic_emit.appendSelectorUnresolved(diagnosticsCollector(report), {
    sourcePath = sourcePath(report),
    family = report.family,
    actionId = report.actionId,
    path = path,
    code = report.code,
    message = label .. ' ' .. tostring(target)
      .. ' is unavailable (' .. reason .. ')',
  })
  local key = label .. '\n' .. reason
  local bucket = report.byReason[key]
  if not bucket then
    bucket = {
      label = label,
      reason = reason,
      count = 0,
      samples = {},
    }
    report.byReason[key] = bucket
    report.order[#report.order + 1] = key
  end
  bucket.count = bucket.count + 1
  report.total = report.total + 1
  if #bucket.samples < report.sampleLimit then
    bucket.samples[#bucket.samples + 1] = string.format('%s -> %s', tostring(path), tostring(target))
  end
  return true
end

function M.flush(report)
  if not report or report.total == 0 then return end
  for i = 1, #report.order do
    local bucket = report.byReason[report.order[i]]
    local hiddenCount = bucket.count - #bucket.samples
    local hidden = hiddenCount > 0 and ('; +' .. tostring(hiddenCount) .. ' more') or ''
    log.warn(report.warnTag or 'compile', '%sAction %s.%s skipped %d %s tuple(s) (%s); examples: %s%s',
      sourcePrefix(report),
      report.actionId,
      report.verb,
      bucket.count,
      bucket.label,
      bucket.reason,
      table.concat(bucket.samples, '; '),
      hidden)
  end
end

function M.emitNoTargets(report, opts)
  opts = opts or {}
  diagnostic_emit.appendSelectorUnresolved(diagnosticsCollector(report), {
    sourcePath = sourcePath(report),
    family = report and report.family or opts.family,
    actionId = report and report.actionId or opts.actionId,
    path = opts.path,
    code = opts.code or 'selector_no_targets_resolved',
    message = opts.message or 'action was skipped because no target selector resolved',
  })
  log.warn(report and report.warnTag or 'compile', '%sAction %s.%s was skipped because %s',
    sourcePrefix(report),
    tostring(report and report.actionId or opts.actionId),
    tostring(report and report.verb or opts.verb or 'action'),
    tostring(opts.reason or 'no target selector resolved'))
end

return M
