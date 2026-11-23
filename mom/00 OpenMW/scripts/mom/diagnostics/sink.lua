local M = {}

local taxonomy = require('scripts.mom.diagnostics.taxonomy')
local log = require('scripts.mom.diagnostics.log')

local function normalizeCategory(category)
  return taxonomy.normalizeCategory(category) or 'support-warning'
end

local function prefix(category, code, fmt)
  return '[' .. normalizeCategory(category) .. ':' .. taxonomy.normalizeCode(code) .. '] ' .. tostring(fmt)
end

function M.error(category, code, tag, fmt, ...)
  log.error(tag, prefix(category, code, fmt), ...)
end

function M.warn(category, code, tag, fmt, ...)
  log.warn(tag, prefix(category, code, fmt), ...)
end

function M.info(category, code, tag, fmt, ...)
  log.info(tag, prefix(category, code, fmt), ...)
end

function M.debug(category, code, tag, fmt, ...)
  log.debug(tag, prefix(category, code, fmt), ...)
end

function M.throttled(lvl, key, category, code, tag, fmt, ...)
  log.throttled(lvl, key, tag, prefix(category, code, fmt), ...)
end

return M
