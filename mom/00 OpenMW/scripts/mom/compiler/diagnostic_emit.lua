local M = {}

local log = require('scripts.mom.diagnostics.log')

function M.sourceBasename(sourcePath)
  if type(sourcePath) ~= 'string' or sourcePath == '' then return nil end
  return sourcePath:match('([^/\\]+)$') or sourcePath
end

function M.sourceLogPrefix(sourcePath)
  local basename = M.sourceBasename(sourcePath)
  if not basename then return '' end
  return '[' .. tostring(basename) .. '] '
end

function M.append(collector, record)
  if type(collector) ~= 'table' or type(collector.append) ~= 'function' then
    return nil
  end
  local ok, errors = collector:append(record)
  if not ok and log.isEnabled and log.isEnabled('debug') then
    log.debug('diagnostics', 'Dropped diagnostic record: %s', table.concat(errors or {}, ' | '))
  end
  return ok, errors
end

local function appendCompileRecord(category, collector, opts)
  opts = opts or {}
  return M.append(collector, {
    category = category,
    severity = opts.severity or 'error',
    phase = opts.phase or 'compile',
    sourcePath = opts.sourcePath,
    family = opts.family,
    actionId = opts.actionId,
    path = opts.path,
    code = opts.code or category:gsub('-', '_'),
    message = tostring(opts.message or category),
  })
end

function M.appendSelectorUnresolved(collector, opts)
  opts = opts or {}
  opts.severity = opts.severity or 'warn'
  opts.code = opts.code or 'selector_unresolved'
  opts.message = opts.message or 'selector did not resolve; action skipped'
  return appendCompileRecord('selector-unresolved', collector, opts)
end

function M.reportSelectorUnresolved(collector, opts)
  opts = opts or {}
  local appended, appendErrors = M.appendSelectorUnresolved(collector, opts)
  local logMessage = opts.logMessage
  if type(logMessage) == 'string' and logMessage ~= '' then
    log.warn(
      opts.logTag or 'compile',
      '%s%s',
      M.sourceLogPrefix(opts.sourcePath),
      logMessage
    )
  end
  return appended, appendErrors
end

return M
