-- Unit & stress tests for runtime core: arbiter, guards, local_broker, deadline_queue.
local M = {}

local arbiter = require('scripts.mom.runtime.arbiter')
local deadline_queue = require('scripts.mom.common.deadline_queue')
local guards_api = require('scripts.mom.runtime.guards')
local local_broker_api = require('scripts.mom.runtime.local_broker')
local test_support = require('pure.test_support')
local expect = test_support.expect

local function arbiterRankingConflictsAndCleanups()
  local candidates = {
    {
      id = 'low', semanticId = 's:low', actionId = 'act:low', targetId = 't1', depth = 0,
      priority = 0, specificity = 1, order = 1, chance = 1,
      claims = {'ref.enabled', 'output.existence'},
    },
    {
      id = 'high', semanticId = 's:high', actionId = 'act:high', targetId = 't1', depth = 0,
      priority = 10, specificity = 0, order = 5, chance = 1,
      claims = {'ref.enabled'},
    },
    {
      id = 'coincident', semanticId = 's:coincident', actionId = 'act:coinc', targetId = 't1', depth = 0,
      priority = 0, specificity = 0, order = 2, chance = 1,
      claims = {'output.existence'},
    },
    {
      id = 'occupied_loser', semanticId = 's:occ', actionId = 'act:occ', targetId = 't2', depth = 0,
      priority = 100, specificity = 10, order = 1, chance = 1,
      claims = {'ref.scale'},
    },
  }
  local occupied = {t2 = {['ref.scale'] = 'op:held'}}
  local res = arbiter.arbitrate(candidates, occupied)
  expect(#res.winners == 2 and res.winners[1].id == 'coincident' and res.winners[2].id == 'high',
    'arbiter did not pick highest-priority winner and independent output.existence sibling in apply order')
  expect(#res.blocked == 2, 'arbiter did not record lower-priority and occupied-claim losers')

  local ordered = arbiter.orderCleanups({
    {depth = 0, semanticId = 'root'},
    {depth = 2, semanticId = 'grandchild'},
    {depth = 1, semanticId = 'child_b'},
    {depth = 1, semanticId = 'child_a'},
  })
  expect(ordered[1].semanticId == 'grandchild'
      and ordered[2].semanticId == 'child_a'
      and ordered[3].semanticId == 'child_b'
      and ordered[4].semanticId == 'root',
    'arbiter cleanup ordering did not place deepest children first deterministically')
end

local function guardRuntimeBackoffAndEvents()
  local truthValue = nil
  local evalCalls = 0
  local mod = {
    id = 'fixture',
    evaluate = function()
      evalCalls = evalCalls + 1
      if truthValue == nil then return {state = 'unknown', reason = 'pending'} end
      return {state = truthValue and 'active' or 'inactive'}
    end,
  }
  local manifest = {
    ownerIds = {'o1'},
    ownersById = {
      o1 = {
        id = 'o1',
        guard = {op = 'all', fragments = {{family = 'fixture', program = {}}}},
        actionIds = {},
        subscriptions = {'external:fixture:changed'},
      },
    },
    indexes = {ownersByEvent = {['external:fixture:changed'] = {'o1'}}},
  }
  local g = assert(guards_api.new(manifest, {byId = {fixture = {module = mod}}}, {unknownRetryDelay = 10}))
  local r1 = g.evaluateDue(1, {})
  expect(r1.evaluated == 1 and g.truth('o1') == 'unknown' and g.unknownCount() == 1,
    'initial unknown guard evaluation was not tracked')

  local r2 = g.evaluateDue(5, {})
  expect(r2.evaluated == 0, 'unknown guard re-evaluated before retry backoff expired')

  truthValue = true
  local r3 = g.evaluateDue(11, {})
  expect(r3.evaluated == 1 and #r3.changed == 1 and g.truth('o1') == 'active' and g.unknownCount() == 0,
    'guard did not retry on due frame and transition to active')

  truthValue = false
  g.dispatchEvent('external:fixture:changed')
  local r4 = g.evaluateDue(12, {})
  expect(r4.evaluated == 1 and #r4.changed == 1 and g.truth('o1') == 'inactive',
    'dispatched event did not wake subscribed guard owner')
end

local function localBrokerRefcountDedupeAndTimeout()
  local attached, sent, detached = {}, {}, {}
  local valid = true
  local ref = {id = 'actor:1'}
  local broker = local_broker_api.new({
    isValid = function(obj) return valid and obj == ref end,
    objectIdOf = function(obj) return obj.id end,
    attachScript = function(obj, path) attached[#attached + 1] = obj.id .. ':' .. path; return true end,
    detachScript = function(obj, path) detached[#detached + 1] = obj.id .. ':' .. path; return true end,
    sendEvent = function(obj, ev, body) sent[#sent + 1] = {ev = ev, body = body}; return true end,
  })
  local req1 = assert(broker.send('op:1', ref, 'scripts/mom/local/kill.lua', 'MOMKillNow', {health = 0}, {frame = 1, leaseFrames = 5}))
  local req1Dup = assert(broker.send('op:1', ref, 'scripts/mom/local/kill.lua', 'MOMKillNow', {health = 0}, {frame = 2, leaseFrames = 5}))
  expect(req1 == req1Dup and #sent == 1 and #attached == 1,
    'local broker sent duplicate request for same in-flight opId')

  local req2 = assert(broker.send('op:2', ref, 'scripts/mom/local/kill.lua', 'MOMKillNow', {health = 0}, {frame = 2, leaseFrames = 3, cancelEvent = 'MOMKillCancel'}))
  expect(#attached == 1 and broker.inFlightCount() == 2,
    'local broker did not refcount shared script attachment')

  expect(broker.acknowledge({requestId = req1, commandId = 'op:1', ok = true, dead = true}) == true,
    'local broker rejected matching acknowledgement')
  expect(#detached == 0 and broker.inFlightCount() == 1,
    'local broker detached script while second op remained in flight')

  local expired = broker.pollTimeouts(6)
  expect(expired == 1 and #detached == 1 and broker.inFlightCount() == 0,
    'local broker did not expire timed-out op and detach final script refcount')
  local done = broker.drainCompletions()
  expect(#done == 2 and done[1].ok == true and done[2].expired == true,
    'local broker completions lost ack or timeout result')
end

local function stressArbiterAndDeadlineQueue()
  local candidates = {}
  for i = 1, 500 do
    candidates[i] = {
      id = 'c:' .. tostring(i),
      semanticId = 'sem:' .. tostring(i),
      actionId = 'act:' .. tostring(i),
      targetId = 'target:' .. tostring(i % 100),
      depth = 0,
      priority = i % 7,
      specificity = i % 3,
      order = i,
      chance = 1,
      claims = {'ref.enabled'},
    }
  end
  local arb = arbiter.arbitrate(candidates, {})
  expect(#arb.winners == 100 and #arb.blocked == 400,
    '500-candidate arbitration did not yield exactly 100 winners across 100 targets')

  local q = deadline_queue.new()
  for i = 1, 1000 do
    deadline_queue.upsert(q, 'item:' .. tostring(i), 1001 - i)
  end
  local popped, last = 0, -1
  while true do
    local due = deadline_queue.popNextDue(q, 2000)
    if due == nil then break end
    expect(due.dueFrame >= last, 'deadline queue popped out of monotonic order')
    last = due.dueFrame
    popped = popped + 1
  end
  expect(popped == 1000, 'deadline queue lost items during 1000-item drain')
end

function M.run()
  return test_support.runCases('runtime core', {
    {'arbiter ranking conflicts and cleanup order', arbiterRankingConflictsAndCleanups},
    {'guard runtime unknown backoff and event wakeups', guardRuntimeBackoffAndEvents},
    {'local broker refcounting deduplication and timeouts', localBrokerRefcountDedupeAndTimeout},
    {'stress 500-candidate arbitration and 1000-item deadline queue', stressArbiterAndDeadlineQueue, {stress = true}},
  })
end

return M
