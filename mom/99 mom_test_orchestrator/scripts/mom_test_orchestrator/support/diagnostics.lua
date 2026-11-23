-- Runtime readiness, status formatting, and optional GC/JIT diagnostics.
local C = require('scripts.mom_test_orchestrator.constants')
local control = require('scripts.mom_test_orchestrator.support.control')
local values = require('scripts.mom_test_orchestrator.support.values')
local world_support = require('scripts.mom_test_orchestrator.support.world')

local bypassOk, bypass = pcall(select, 'sandbox.bypass')
if not bypassOk or type(bypass) ~= 'table' then bypass = nil end
local collectGarbage = bypass and bypass.collectgarbage or nil
local jitLibrary = bypass and bypass.jit or nil

local M = {}

function M.ensureMOMReady()
  local api = world_support.momInterface()
  control.expect(api ~= nil, 'MOM interface unavailable')
  -- OpenMW completes onInit/onLoad before the suite starts. A rejected
  -- startup is a failure, not a reason to repeat a whole-ledger audit per frame.
  local ok, diagnostics = pcall(api.selfcheck)
  control.expect(ok, 'MOM startup selfcheck failed: ' .. tostring(diagnostics))
  if not diagnostics or diagnostics.ok ~= true then
    error('MOM startup is unhealthy; ' .. M.runtimeStatusText())
  end
end

local function describeMap(values)
  local keys = {}
  for key in pairs(type(values) == 'table' and values or {}) do keys[#keys + 1] = key end
  table.sort(keys)
  local rows = {}
  for i = 1, #keys do rows[i] = tostring(keys[i]) .. '=' .. tostring(values[keys[i]]) end
  return table.concat(rows, ',')
end

function M.runtimeStatusText()
  local api = world_support.momInterface()
  local readable, selfcheck = pcall(function() return api and api.selfcheck or nil end)
  if not readable or type(selfcheck) ~= 'function' then return 'selfcheck=unavailable' end
  local ok, support = pcall(selfcheck)
  if not ok or type(support) ~= 'table' then return 'selfcheck=' .. tostring(support) end
  local runtime = type(support.runtime) == 'table' and support.runtime or {}
  local counts = type(runtime.counts) == 'table' and runtime.counts or {}
  local queues = type(runtime.queues) == 'table' and runtime.queues or {}
  local blockers = type(runtime.blockers) == 'table' and runtime.blockers or {}
  local operationWork = type(runtime.operationWork) == 'table'
    and runtime.operationWork or {}
  local activeOwners = type(runtime.activeOwners) == 'table'
    and runtime.activeOwners or {}
  local stateQueue = type(queues.state) == 'table' and queues.state or {}
  local lastState = type(runtime.lastStateReconciliation) == 'table'
    and runtime.lastStateReconciliation or {}
  local blockerRows = {}
  for i = 1, #(blockers.samples or {}) do
    local row = blockers.samples[i]
    blockerRows[i] = table.concat({
      tostring(row.kind), tostring(row.code), tostring(row.family),
      tostring(row.producerId or row.semanticId),
      tostring(row.targetId), tostring(row.source),
      tostring(row.message),
    }, ':')
  end
  local operationRows = {}
  for i = 1, #(operationWork.samples or {}) do
    local row = operationWork.samples[i]
    operationRows[i] = table.concat({
      tostring(row.producerId), tostring(row.semanticId),
      tostring(row.ownerId), tostring(row.actionId), tostring(row.family),
      tostring(row.lifecycle), tostring(row.durability), tostring(row.form),
      tostring(row.status), tostring(row.operation), tostring(row.nextFrame),
      tostring(row.attempt), tostring(row.phase),
      tostring(row.activeCommandId), tostring(row.awaitingCompletion),
      tostring(row.lastError or row.quarantineReason),
    }, ':')
  end
  local cancellationRows = {}
  for i = 1, #(stateQueue.cancellationSamples or {}) do
    local row = stateQueue.cancellationSamples[i]
    cancellationRows[i] = table.concat({
      tostring(row.hasJob), tostring(row.jobCursor), tostring(row.jobCount),
      tostring(row.ownerCursor), tostring(row.ownerCount), tostring(row.ownerId),
      tostring(row.reason),
    }, ':')
  end
  local discoveryRows = {}
  for i = 1, #(lastState.discovery or {}) do
    local row = lastState.discovery[i]
    discoveryRows[i] = table.concat({
      tostring(row.actionId), tostring(row.status), tostring(row.targetCount),
      tostring(row.reason),
    }, ':')
  end
  local childRows = {}
  local children = type(lastState.children) == 'table'
    and lastState.children or {}
  for levelIndex = 1, #(children.levels or {}) do
    local level = children.levels[levelIndex]
    for i = 1, #(level.discovery or {}) do
      local row = level.discovery[i]
      childRows[#childRows + 1] = table.concat({
        'discover', tostring(level.depth), tostring(row.parentProducerId),
        tostring(row.actionId), tostring(row.status),
        tostring(row.targetCount), tostring(row.reason),
      }, ':')
    end
    for i = 1, #(level.apply or {}) do
      local row = level.apply[i]
      childRows[#childRows + 1] = table.concat({
        'apply', tostring(level.depth), tostring(row.parentProducerId),
        tostring(row.actionId), tostring(row.status),
        tostring(row.targetId), tostring(row.reason),
      }, ':')
    end
    for i = 1, #(level.held or {}) do
      local row = level.held[i]
      childRows[#childRows + 1] = table.concat({
        'held', tostring(level.depth), tostring(row.parentProducerId),
        tostring(row.actionId), tostring(row.status),
        tostring(row.targetId), tostring(row.reason),
      }, ':')
    end
  end
  local activeOwnerRows = {}
  for i = 1, #(activeOwners.samples or {}) do
    local owner = activeOwners.samples[i]
    local actions = {}
    for j = 1, #(owner.actions or {}) do
      local action = owner.actions[j]
      actions[j] = table.concat({
        tostring(action.actionId), tostring(action.family),
        tostring(action.exactId), tostring(action.exactIdCount),
        tostring(action.candidateType),
        tostring(action.cellRouteKind), tostring(action.cellRouteKey),
      }, ':')
    end
    activeOwnerRows[i] = tostring(owner.ownerId) .. '='
      .. tostring(owner.actionCount) .. '{' .. table.concat(actions, '|') .. '}'
  end
  local compile = type(support.compile) == 'table' and support.compile.summary or {}
  local sourceReport = type(compile.sources) == 'table'
    and compile.sources or {}
  local sourceRows = {}
  for i = 1, #(sourceReport.rows or {}) do
    local row = sourceReport.rows[i]
    sourceRows[i] = table.concat({
      tostring(row.path), tostring(row.status), tostring(row.errorKind),
      tostring(row.errorMessage),
    }, ':')
  end
  local compileDiagnosticRows = {}
  local compileDiagnostics = type(compile.diagnostics) == 'table'
    and compile.diagnostics or {}
  for i = 1, #(compileDiagnostics.samples or {}) do
    local row = compileDiagnostics.samples[i]
    compileDiagnosticRows[i] = table.concat({
      tostring(row.sourcePath), tostring(row.category), tostring(row.code),
      tostring(row.message),
    }, ':')
  end
  local selection = type(queues.selectionSessions) == 'table'
    and queues.selectionSessions or {}
  local staticIntent = type(queues.staticIntent) == 'table'
    and queues.staticIntent or {}
  local summary = string.format(
    'frame=%s status=%s ownerTruths={%s} activeOwners=%s[%s] operationStatuses={%s} operationForms={%s} operationLifecycles={%s} operationDurabilities={%s} operations=%s liveOperations=%s operationTombstones=%s scheduledOperations=%s commands=%s activeCommands=%s awaitingCompletions=%s operationWork=%s[%s] staticFailures=%s staticScans={%s} wakeups=%s owners=%s stateJobs=%s statePhases={%s} statePendingOwners=%s[%s] stateCancellations=%s/%s/%s[%s] stateLastInvalidation=%s lastStateDiscovery=%s[%s] lastStateHeld=%s childLevels=%s[%s] staticCells=%s staticIntentWaiting=%s staticIntentCount=%s blockers=%s[%s] compileFamilies={%s} compileSources=%s/%s[%s] compileDiagnostics=%s[%s]',
    tostring(support.frame), tostring(support.status),
    describeMap(counts.ownerTruths),
    tostring(activeOwners.count or 0), table.concat(activeOwnerRows, ','),
    describeMap(counts.operationStatuses),
    describeMap(counts.operationForms),
    describeMap(counts.operationLifecycles),
    describeMap(counts.operationDurabilities),
    tostring(counts.operations),
    tostring(counts.liveOperations),
    tostring(counts.operationTombstones),
    tostring(counts.scheduledOperations),
    tostring(counts.commands),
    tostring(counts.activeCommands),
    tostring(counts.awaitingCompletions),
    tostring(operationWork.count or 0), table.concat(operationRows, ','),
    tostring(counts.staticFailures), describeMap(counts.staticScans),
    tostring(queues.wakeups), tostring(queues.owners),
    tostring(stateQueue.queued), describeMap(stateQueue.phases),
    tostring(stateQueue.pendingOwners),
    table.concat(stateQueue.pendingOwnerIds or {}, ','),
    tostring(stateQueue.cancellationJobs),
    tostring(stateQueue.cancellationBatches),
    tostring(stateQueue.invalidations),
    table.concat(cancellationRows, ','),
    tostring(stateQueue.lastInvalidationReason),
    tostring(lastState.discoveryCount or 0),
    table.concat(discoveryRows, ','),
    tostring(lastState.heldCount or 0),
    tostring(children.levelCount or 0),
    table.concat(childRows, ','),
    tostring(queues.staticCells),
    tostring(staticIntent.waiting == true),
    tostring(staticIntent.waitingCount or 0),
    tostring(blockers.count),
    table.concat(blockerRows, ','), describeMap(compile.byFamily),
    tostring(sourceReport.count), tostring(sourceReport.failed),
    table.concat(sourceRows, ','),
    tostring(compileDiagnostics.total), table.concat(compileDiagnosticRows, ',')
  )
  return summary .. string.format(
    ' selectionSessions=%s/%s selectionHighWater=%s selectionBackpressure=%s'
      .. ' refSnapshots=%s/%s refPages=%s/%s'
      .. ' refSnapshotBackpressure=%s refCursorRejects=%s',
    tostring(selection.current), tostring(selection.limit),
    tostring(selection.highWater), tostring(selection.backpressureCount),
    tostring(selection.snapshots), tostring(selection.snapshotLimit),
    tostring(selection.pageSessions), tostring(selection.pageSessionLimit),
    tostring(selection.snapshotBackpressureCount),
    tostring(selection.pageCursorRejectionCount)
  )
end

function M.runtimeOperationTargetCount(family, targetKind, recordId)
  local api = world_support.momInterface()
  local readable, selfcheck = pcall(function() return api and api.selfcheck or nil end)
  if not readable or type(selfcheck) ~= 'function' then return 0 end
  local normalizedRecordId = values.normalizeRecordId(recordId)
  if type(family) ~= 'string'
      or family == ''
      or type(targetKind) ~= 'string'
      or targetKind == ''
      or normalizedRecordId == nil then return 0 end
  local ok, diagnostics = pcall(selfcheck, {
    operation = {
      family = family,
      targetKind = targetKind,
      targetRecordId = normalizedRecordId,
      statuses = {'applied', 'noop'},
    },
  })
  if not ok or type(diagnostics) ~= 'table' then return 0 end
  local runtime = type(diagnostics.runtime) == 'table' and diagnostics.runtime or {}
  local operations = type(runtime.operationWork) == 'table'
    and runtime.operationWork or {}
  -- Counts cover the complete filtered journal; samples remain bounded and
  -- can omit a terminal operation behind retained generations.
  local count = operations.count
  return type(count) == 'number' and count >= 0 and count % 1 == 0 and count or 0
end

function M.logGcDiagnostics(stage)
  if type(collectGarbage) ~= 'function' then return end
  local countOk, countKb = pcall(collectGarbage, 'count')
  local runningOk, running = pcall(collectGarbage, 'isrunning')
  if not countOk then return end
  print(string.format(
    '[MOMTestOrchestrator][INFO] Lua diagnostics %s: heapKb=%s gcRunning=%s',
    tostring(stage),
    tostring(countKb),
    runningOk and tostring(running) or 'unknown'
  ))
end

function M.collectGc()
  if type(collectGarbage) ~= 'function' then return end
  local ok, err = pcall(collectGarbage, 'collect')
  if not ok then
    print('[MOMTestOrchestrator][WARN] GC collect failed: ' .. tostring(err))
    return
  end
  M.logGcDiagnostics('after collect')
end

function M.flushJitDiagnostics()
  if type(jitLibrary) ~= 'table' or type(jitLibrary.flush) ~= 'function' then return end
  local ok, err = pcall(jitLibrary.flush)
  if not ok then
    print('[MOMTestOrchestrator][WARN] JIT flush failed: ' .. tostring(err))
    return
  end
  local statusOk, enabled = pcall(jitLibrary.status)
  print(string.format(
    '[MOMTestOrchestrator][INFO] JIT flushed: enabled=%s version=%s arch=%s',
    statusOk and tostring(enabled) or 'unknown',
    tostring(jitLibrary.version),
    tostring(jitLibrary.arch)
  ))
end

function M.waitForSuiteReady()
  control.waitUntil(function()
    return world_support.playerReady() and world_support.momInterface() ~= nil
  end, C.LONG_TIMEOUT_FRAMES * 10, 'suite startup readiness')
end

return M
