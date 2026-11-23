-- Minimal leveled logging utility for MOM modules. Format strings are evaluated
-- only after the active level check passes.
local M = {}
local constants = require('scripts.mom.constants')
local levels = { off = 0, error = 1, warn = 2, info = 3, debug = 4, trace = 5 }
local levelNames = { [0] = 'off', [1] = 'error', [2] = 'warn', [3] = 'info', [4] = 'debug', [5] = 'trace' }
local current = levels.info -- Default to info; adjust via setLevel.
local validLevelNames = { 'off', 'error', 'warn', 'info', 'debug', 'trace' }
local MAX_THROTTLED_KEYS = 256
local repeatCounts = {}
local repeatKeyCount = 0
function M.setLevel(lvl)
  local nextLevel = levels[lvl]
  if nextLevel == nil then
    return M.getLevel(), false, table.concat(validLevelNames, ', ')
  end
  current = nextLevel
  return M.getLevel(), true, table.concat(validLevelNames, ', ')
end
function M.getLevel()
  return levelNames[current] or 'info'
end
function M.isEnabled(lvl)
  local threshold = levels[lvl]
  return threshold ~= nil and threshold <= current
end
local function emit(lvl, tag, fmt, ...)
  if M.isEnabled(lvl) then
    local msg = select('#', ...) > 0 and string.format(fmt, ...) or fmt
    print(string.format('[%s][%s][%s] %s', constants.shortName, lvl:upper(), tag, msg))
  end
end
function M.error(tag, fmt, ...) emit('error', tag, fmt, ...) end
function M.warn(tag, fmt, ...)  emit('warn', tag, fmt, ...) end
function M.info(tag, fmt, ...)  emit('info', tag, fmt, ...) end
function M.debug(tag, fmt, ...) emit('debug', tag, fmt, ...) end
function M.trace(tag, fmt, ...) emit('trace', tag, fmt, ...) end
function M.throttled(lvl, key, tag, fmt, ...)
  key = tostring(key or (tostring(tag) .. ':' .. tostring(fmt)))
  if repeatCounts[key] == nil then
    repeatKeyCount = repeatKeyCount + 1
    if repeatKeyCount > MAX_THROTTLED_KEYS then
      repeatCounts = {}
      repeatKeyCount = 1
    end
  end
  local count = (repeatCounts[key] or 0) + 1
  repeatCounts[key] = count
  if count == 1 then
    emit(lvl, tag, fmt, ...)
  elseif count == 2 then
    emit(lvl, tag, '%s (further repeats suppressed; key=%s)',
      select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt),
      key)
  elseif count % 100 == 0 then
    emit(lvl, tag, 'Repeated runtime failure count=%d key=%s', count, key)
  end
end
return M
