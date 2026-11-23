local M = {}

local HASH_MODULUS = 4294967296
local PRIMARY_HASH_SEED = 5381
local SECONDARY_HASH_SEED = 2166136261
local PRIMARY_HASH_MULTIPLIER = 33
local SECONDARY_HASH_MULTIPLIER = 65599

--- Return true only for a non-empty string, without coercing other values.
function M.isNonEmpty(value)
  return type(value) == 'string' and value ~= ''
end

--- Normalize a value to a non-empty string, or nil.
--- Converts via tostring; returns nil for nil or empty-string inputs.
function M.normalizeString(value)
  if value == nil then return nil end
  local str = tostring(value)
  if str == '' then return nil end
  return str
end

--- Normalize a value to a lowercase non-empty string, or nil.
--- Converts via tostring; returns nil for nil or empty-string inputs.
function M.lowerString(value)
  if value == nil then return nil end
  local str = tostring(value)
  if str == '' then return nil end
  return str:lower()
end

-- Two distinct modular-polynomial lanes form MOM's portable accidental
-- fingerprint. Both multiplication intermediates remain below 2^49, so the
-- arithmetic is exact even on Lua runtimes whose only number type is an IEEE
-- 754 double. This is deliberately not a cryptographic hash.
function M.beginHashLanes()
  return PRIMARY_HASH_SEED, SECONDARY_HASH_SEED
end

function M.advanceHashBytes(primary, secondary, value, first, last)
  first = first or 1
  last = last or #value
  for i = first, last do
    local byte = value:byte(i)
    primary =
      (primary * PRIMARY_HASH_MULTIPLIER + byte) % HASH_MODULUS
    secondary =
      (secondary * SECONDARY_HASH_MULTIPLIER + byte) % HASH_MODULUS
  end
  return primary, secondary
end

function M.hashStringLanes(value)
  return M.advanceHashBytes(
    PRIMARY_HASH_SEED,
    SECONDARY_HASH_SEED,
    value
  )
end

function M.formatHashLanes(primary, secondary)
  return string.format('%08x%08x', primary, secondary)
end

--- Primary 32-bit lane used only for deterministic scalar sampling.
--- Canonical identity fingerprints use both lanes through hashString().
function M.sampleStringRaw(value)
  -- Keep the hot chance-sampling path single-lane: it needs a uniform scalar,
  -- not an identity fingerprint, and computing the second lane would add work
  -- without changing its decision.
  local primary = PRIMARY_HASH_SEED
  for i = 1, #value do
    primary = (
      primary * PRIMARY_HASH_MULTIPLIER + value:byte(i)
    ) % HASH_MODULUS
  end
  return primary
end

--- Dual-lane hash of a string, returned as a 16-character hex string.
function M.hashString(value)
  return M.formatHashLanes(M.hashStringLanes(value))
end

return M
