local M = {}

local function set(values)
  local out = {}
  for i = 1, #values do
    out[values[i]] = true
  end
  return out
end

M.categories = set({
  'source-load-failed',
  'config-invalid',
  'import-warning',
  'selector-unresolved',
  'compiler-contract',
  'program-invalid',
  'runtime-ref-missing',
  'engine-api-failed',
  'saved-state-invalid',
  'persistence-failed',
  'runtime-failed',
  'public-api-invalid',
  'support-warning',
})

M.severities = set({
  'debug',
  'info',
  'warn',
  'error',
})

M.phases = set({
  'load',
  'import',
  'compile',
  'runtime',
  'support',
})

local function normalizeSetValue(values, value)
  if type(value) ~= 'string' or value == '' then return nil end
  local normalized = value:lower()
  if values[normalized] then return normalized end
  return nil
end

function M.normalizeCategory(value)
  return normalizeSetValue(M.categories, value)
end

function M.normalizeSeverity(value)
  return normalizeSetValue(M.severities, value)
end

function M.normalizePhase(value)
  return normalizeSetValue(M.phases, value)
end

function M.normalizeCode(value)
  if type(value) ~= 'string' or value == '' then return 'uncategorized' end
  return value:lower():gsub('-', '_')
end

function M.validate(record)
  local errors = {}
  if type(record) ~= 'table' then
    return nil, { 'diagnostic: expected object' }
  end
  if not M.normalizeCategory(record.category) then
    errors[#errors + 1] = 'diagnostic.category: unknown category ' .. tostring(record.category)
  end
  if not M.normalizeSeverity(record.severity) then
    errors[#errors + 1] = 'diagnostic.severity: unknown severity ' .. tostring(record.severity)
  end
  if not M.normalizePhase(record.phase) then
    errors[#errors + 1] = 'diagnostic.phase: unknown phase ' .. tostring(record.phase)
  end
  if type(record.message) ~= 'string' or record.message == '' then
    errors[#errors + 1] = 'diagnostic.message: expected non-empty string'
  end
  if #errors > 0 then return nil, errors end
  return true, nil
end

return M
