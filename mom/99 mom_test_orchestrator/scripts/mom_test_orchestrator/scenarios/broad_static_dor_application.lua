local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')

local DOR_BROAD_STATIC_SOURCE_RECORD_ID = 'in_cave_plant10'
local DOR_BROAD_STATIC_TARGET_RECORD_ID = 'in_cave_plant00'
local DOR_BROAD_STATIC_EXPECTED_COUNT = 629
-- The real host performs paged identity recovery around each output mutation.
-- Keep a finite regression bound while allowing three ordinary scenario windows
-- for the intentionally high-cardinality workload.
local DOR_BROAD_STATIC_TIMEOUT_FRAMES = C.LONG_TIMEOUT_FRAMES * 3
local function countRecord(cell, recordId, requireEnabled)
  local normalized = H.normalizeRecordId(recordId)
  return H.countObjects(cell, function(obj)
    return H.objectRecordId(obj) == normalized
      and (requireEnabled ~= true or obj.enabled ~= false)
  end)
end

local function countDisabledRecord(cell, recordId)
  local normalized = H.normalizeRecordId(recordId)
  return H.countObjects(cell, function(obj)
    return H.objectRecordId(obj) == normalized
      and obj.enabled == false
  end)
end

return {
  id = 'broad_static_dor_application',
  description = 'DOR-style wildcard static replacement applies to hundreds of pre-existing refs in one cell.',
  run = function()
    H.teleportInterior(C.VASSAMSI_GROTTO, C.VASSAMSI_GROTTO_SAFE_POSITION,
      'Vassamsi Grotto broad DOR static setup')
    local cell = H.requireCurrentInterior(C.VASSAMSI_GROTTO)
    local expected = DOR_BROAD_STATIC_EXPECTED_COUNT

    local disabled, replacements = 0, 0
    local ok, waitError = pcall(function()
      H.waitUntil(function()
        disabled = countDisabledRecord(cell, DOR_BROAD_STATIC_SOURCE_RECORD_ID)
        replacements = countRecord(
          cell,
          DOR_BROAD_STATIC_TARGET_RECORD_ID,
          true
        )
        return disabled >= expected and replacements >= expected
      end, DOR_BROAD_STATIC_TIMEOUT_FRAMES,
        'DOR broad static cave plant replacement')
    end)
    if not ok then
      error(string.format(
        '%s: disabled=%d replacements=%d expected=%d; %s',
        tostring(waitError),
        disabled,
        replacements,
        expected,
        H.runtimeStatusText()
      ))
    end
  end,
}
