local H = require('scripts.mom_test_orchestrator.helpers')
local I = require('openmw.interfaces')

local M = {
  A = {x = 3000.0, y = 3000.0, z = -311.0},
  B = {x = 3080.0, y = 3000.0, z = -311.0},
}

function M.count(cell, position)
  local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')
  return H.countRecordNearPosition(cell, G.RECORD, position, 16)
end

function M.waitCount(cell, position, expected, description)
  H.waitUntil(function() return M.count(cell, position) == expected end,
    1800, description)
end

function M.status()
  local report = I.MOM and I.MOM.selfcheck and I.MOM.selfcheck() or nil
  H.expect(type(report) == 'table' and report.ok == true
      and type(report.runtime) == 'table'
      and type(report.runtime.counts) == 'table',
    'static evolution runtime status is unavailable')
  return report
end

function M.waitStatus(predicate, description)
  local matched, matchedReport = nil, nil
  local pollDelay = 0
  H.waitUntil(function()
    if pollDelay > 0 then
      pollDelay = pollDelay - 1
      return false
    end
    pollDelay = 9
    local report = M.status()
    matched = predicate(report)
    if matched ~= nil and matched ~= false then
      matchedReport = report
    end
    return matched ~= nil and matched ~= false
  end, 1800, description)
  return matchedReport, matched
end

function M.operationCount(report)
  local lifecycles = report.runtime.counts.operationLifecycles or {}
  return tonumber(lifecycles.static) or 0
end

function M.staticIdle(report)
  local queues = report.runtime.queues or {}
  local intent = queues.staticIntent or {}
  return (tonumber(queues.staticCells) or 0) == 0
    and intent.waiting ~= true
end

function M.logStatus(label, report)
  local counts = report.runtime.counts or {}
  local queues = report.runtime.queues or {}
  print(string.format(
    '[MOMCampaign][STATIC] label=%s manifest=%s staticOperations=%d allLive=%d allTombstones=%d failures=%d scans=%s queue=%d intentWaiting=%s intentCount=%d',
    tostring(label),
    tostring(report.activeManifestHash),
    M.operationCount(report),
    tonumber(counts.liveOperations) or 0,
    tonumber(counts.operationTombstones) or 0,
    tonumber(counts.staticFailures) or 0,
    tostring(counts.staticScans and counts.staticScans.complete or 0),
    tonumber(queues.staticCells) or 0,
    tostring(queues.staticIntent and queues.staticIntent.waiting == true),
    tonumber(queues.staticIntent and queues.staticIntent.waitingCount) or 0
  ))
end

return M
