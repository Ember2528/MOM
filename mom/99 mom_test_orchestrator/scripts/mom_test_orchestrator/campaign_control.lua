local I = require('openmw.interfaces')
local storage = require('openmw.storage')

local M = {}

local SECTION = 'MOMTestCampaignControl'
local section = storage.globalSection(SECTION)
local handoffOk, handoff = pcall(require, 'scripts.mom_test_orchestrator.campaign_handoff')
if not handoffOk or type(handoff) ~= 'table' then handoff = {} end

local function hexEncode(value)
  return tostring(value):gsub('.', function(char)
    return string.format('%02x', string.byte(char))
  end)
end

local function hexDecode(value)
  assert(type(value) == 'string' and value:match('^[0-9a-fA-F]*$')
      and #value % 2 == 0, 'campaign handoff value is malformed')
  return value:gsub('(%x%x)', function(pair)
    return string.char(tonumber(pair, 16))
  end)
end

function M.emitValue(key, value)
  assert(type(key) == 'string' and key:match('^[A-Za-z0-9_.-]+$'),
    'campaign handoff key is invalid')
  local encoded = hexEncode(value)
  print(string.format('[MOMCampaign][VALUE] key=%s hex=%s', key, encoded))
end

function M.handoffValue(key)
  local encoded = handoff[key]
  assert(type(encoded) == 'string', 'campaign handoff value is unavailable: ' .. tostring(key))
  return hexDecode(encoded)
end

function M.logDiagnostics(scenarioId, cellId)
  local selfcheck = I.MOM and I.MOM.selfcheck and I.MOM.selfcheck() or nil
  local compile = I.MOM and I.MOM.compileReport and I.MOM.compileReport() or nil
  local runtime = type(selfcheck) == 'table' and selfcheck.runtime or nil
  local counts = type(runtime) == 'table' and runtime.counts or nil
  local blockers = type(runtime) == 'table' and runtime.blockers or nil
  print(string.format(
    '[MOMCampaign][DIAGNOSTICS] scenario=%s cell=%s status=%s active=%s operations=%d scheduled=%d staticOperations=%d staticFailures=%d blockers=%d',
    tostring(scenarioId),
    tostring(cellId),
    tostring(type(selfcheck) == 'table' and selfcheck.status or 'unavailable'),
    tostring(type(compile) == 'table' and compile.activeManifestHash or nil),
    tonumber(type(counts) == 'table' and counts.operations) or 0,
    tonumber(type(counts) == 'table' and counts.scheduledOperations) or 0,
    tonumber(type(counts) == 'table'
      and type(counts.operationLifecycles) == 'table'
      and counts.operationLifecycles.static) or 0,
    tonumber(type(counts) == 'table' and counts.staticFailures) or 0,
    tonumber(type(blockers) == 'table' and blockers.count) or 0
  ))
  for i = 1, #(type(blockers) == 'table' and blockers.samples or {}) do
    local issue = blockers.samples[i]
    print(string.format(
      '[MOMCampaign][BLOCKER] kind=%s code=%s operation=%s target=%s family=%s status=%s error=%s',
      tostring(issue.kind),
      tostring(issue.code),
      tostring(issue.producerId or issue.semanticId),
      tostring(issue.targetId),
      tostring(issue.family),
      tostring(issue.status),
      tostring(issue.message)
    ))
  end
  local queues = type(runtime) == 'table' and runtime.queues or nil
  local stateQueue = type(queues) == 'table' and queues.state or nil
  print(string.format(
    '[MOMCampaign][QUEUES] owners=%s stateQueued=%s statePlanning=%s stateCommitting=%s wakeups=%s staticCells=%s',
    tostring(type(queues) == 'table' and queues.owners or nil),
    tostring(type(stateQueue) == 'table' and stateQueue.queued or nil),
    tostring(type(stateQueue) == 'table' and stateQueue.planningJobs or nil),
    tostring(type(stateQueue) == 'table' and stateQueue.committing or nil),
    tostring(type(queues) == 'table' and queues.wakeups or nil),
    tostring(type(queues) == 'table' and queues.staticCells or nil)
  ))
  local operationWork =
    type(runtime) == 'table' and runtime.operationWork or nil
  for i = 1,
      #(type(operationWork) == 'table' and operationWork.samples or {}) do
    local operation = operationWork.samples[i]
    print(string.format(
      '[MOMCampaign][OPERATION] producer=%s semantic=%s owner=%s action=%s family=%s lifecycle=%s durability=%s form=%s status=%s operation=%s attempt=%s phase=%s nextFrame=%s command=%s error=%s',
      tostring(operation.producerId),
      tostring(operation.semanticId),
      tostring(operation.ownerId),
      tostring(operation.actionId),
      tostring(operation.family),
      tostring(operation.lifecycle),
      tostring(operation.durability),
      tostring(operation.form),
      tostring(operation.status),
      tostring(operation.operation),
      tostring(operation.attempt),
      tostring(operation.phase),
      tostring(operation.nextFrame),
      tostring(operation.activeCommandId),
      tostring(operation.lastError or operation.quarantineReason)
    ))
  end
end

function M.saveAndExit(scenarioId, description, cellId)
  M.logDiagnostics(scenarioId, cellId)
  section:set('request', {
    scenarioId = tostring(scenarioId),
    description = tostring(description or scenarioId),
  })
  print(string.format(
    '[MOMCampaign][SAVE_REQUEST] scenario=%s description=%s',
    tostring(scenarioId),
    tostring(description or scenarioId)
  ))
  while true do coroutine.yield() end
end

return M
