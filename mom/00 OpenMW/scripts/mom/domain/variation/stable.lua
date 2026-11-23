-- Deterministic declaration-level admission and absolute placement choice.
-- This is independent of source format, engine context and runtime state.
local M = {}
local finite = require('scripts.mom.common.numbers').isFinite
local HASH_M = 2147483647
function M.unit(key, seed, salt)
  assert(type(key) == 'string' and key ~= '', 'sampling key must be a non-empty string')
  assert(seed == nil or finite(seed), 'sampling seed must be finite')
  assert(type(salt) == 'string', 'sampling salt must be a string')
  local h = (math.floor(seed or 0) % HASH_M) + 1
  local bytes = salt .. '\0' .. key:lower()
  for index = 1, #bytes do h = (h * 48271 + bytes:byte(index)) % HASH_M end
  return h / HASH_M
end
function M.pick(entries, key, seed, salt)
  local sum = 0
  for _, entry in ipairs(entries) do
    assert(type(entry) == 'table' and finite(entry[2]) and entry[2] > 0,
      'choice entries require a target and positive finite weight')
    sum = sum + entry[2]
  end
  assert(#entries > 0 and finite(sum), 'choice weights must have a positive finite sum')
  local draw, accumulated = M.unit(key, seed, salt) * sum, 0
  for _, entry in ipairs(entries) do
    accumulated = accumulated + entry[2]
    if draw < accumulated then return entry[1] end
  end
  return entries[#entries][1]
end
return M
