-- Coalesced guard owner wakeup router and tri-state guard evaluator.
-- Evaluates immutable compiled guard programs directly (zero per-eval cloning),
-- honors guard.needsScene, and schedules unknown-truth retries via deadline_queue.
local M = {}

local deadline_queue = require('scripts.mom.common.deadline_queue')
local plain_data = require('scripts.mom.contracts.plain_data')
local strings = require('scripts.mom.common.strings')

local VALID_STATES = {active = true, inactive = true, unknown = true}
local DEFAULT_UNKNOWN_RETRY_DELAY = 10
local nonEmpty = strings.isNonEmpty

local function prepareOwnerGuard(owner, guardRegistry)
  local guard = owner and owner.guard
  if type(guard) ~= 'table' then return nil, 'owner guard is missing' end
  if guard.op == 'always' then
    return {op = 'always', fragments = {}}, nil
  end
  if guard.op ~= 'all' or type(guard.fragments) ~= 'table' or #guard.fragments == 0 then
    return nil, 'owner guard is invalid'
  end
  local fragments = {}
  for i = 1, #guard.fragments do
    local frag = guard.fragments[i]
    local entry = guardRegistry and guardRegistry.byId and guardRegistry.byId[frag.family] or nil
    local evaluate = entry and entry.module and entry.module.evaluate or nil
    if type(evaluate) ~= 'function' then
      return nil, 'guard evaluator unavailable: ' .. tostring(frag.family)
    end
    fragments[i] = {
      family = frag.family,
      evaluate = evaluate,
      program = frag.program,
      isolateProgram = nonEmpty(entry.module.providerInterface),
    }
  end
  return {op = 'all', fragments = fragments}, nil
end

local function evalFragment(frag, capabilities)
  local program = frag.isolateProgram and plain_data.cloneValidated(frag.program) or frag.program
  local ok, res = pcall(frag.evaluate, program, capabilities)
  if not ok then
    return 'unknown', 'guard evaluator failed: ' .. tostring(res)
  end
  if type(res) ~= 'table' or not VALID_STATES[res.state] then
    return 'unknown', 'guard evaluator returned an invalid result'
  end
  if res.state == 'unknown' then
    return 'unknown', tostring(res.reason or 'guard state unavailable')
  end
  return res.state, nil
end

local function evaluateGuard(prepared, capabilities)
  if prepared.op == 'always' then return 'active', nil end
  local unknownReasons = nil
  for i = 1, #prepared.fragments do
    local state, reason = evalFragment(prepared.fragments[i], capabilities)
    if state == 'inactive' then
      return 'inactive', nil
    elseif state == 'unknown' then
      unknownReasons = unknownReasons or {}
      if #unknownReasons < 4 then
        unknownReasons[#unknownReasons + 1] = reason
      end
    end
  end
  if unknownReasons ~= nil then
    return 'unknown', table.concat(unknownReasons, ' | ')
  end
  return 'active', nil
end

function M.new(manifest, guardRegistry, opts)
  opts = opts or {}
  local retryDelay = math.max(1, math.floor(tonumber(opts.unknownRetryDelay) or DEFAULT_UNKNOWN_RETRY_DELAY))
  local owners = {}            -- ownerId -> { id, prepared, truth, reason, dirty }
  local ownerIds = manifest.ownerIds or {}
  local dirtySet = {}          -- ownerId -> true
  local retryQueue = deadline_queue.new()
  local byEvent = {}           -- eventName -> { ownerId, ... }
  local watchTime = false
  local watchWeather = false
  local watchedWeatherRegions = nil -- true (broad) or { [regionKey] = true }
  local unknownSet = {}        -- ownerId -> true (currently unknown truth)

  local function subscribe(eventName, ownerId)
    local list = byEvent[eventName]
    if list == nil then list = {}; byEvent[eventName] = list end
    for i = 1, #list do if list[i] == ownerId then return end end
    list[#list + 1] = ownerId
  end

  for i = 1, #ownerIds do
    local ownerId = ownerIds[i]
    local ownerSpec = manifest.ownersById[ownerId]
    local prepared, err = prepareOwnerGuard(ownerSpec, guardRegistry)
    if prepared == nil then return nil, err end
    owners[ownerId] = {
      id = ownerId,
      spec = ownerSpec,
      prepared = prepared,
      truth = 'unknown',
      reason = 'not evaluated yet',
      evaluated = false,
    }
    unknownSet[ownerId] = true
    dirtySet[ownerId] = true
    for _, sub in ipairs(ownerSpec.subscriptions or {}) do
      subscribe(sub, ownerId)
      if sub == 'timeHourChanged' or sub == 'timeDayChanged' then
        watchTime = true
      elseif sub == 'weatherChanged' then
        watchWeather = true
        watchedWeatherRegions = true
      elseif sub:sub(1, 15) == 'weatherChanged:' then
        watchWeather = true
        if watchedWeatherRegions ~= true then
          watchedWeatherRegions = watchedWeatherRegions or {}
          local regionKey = strings.lowerString(sub:sub(16))
          if regionKey ~= nil then watchedWeatherRegions[regionKey] = true end
        end
      end
    end
  end

  local mgr = {
    watchTime = watchTime,
    watchWeather = watchWeather,
    watchedWeatherRegions = watchedWeatherRegions,
  }

  function mgr.markDirty(ownerId)
    if owners[ownerId] ~= nil then
      dirtySet[ownerId] = true
      deadline_queue.remove(retryQueue, ownerId)
    end
  end

  function mgr.markAllDirty()
    for i = 1, #ownerIds do
      local id = ownerIds[i]
      dirtySet[id] = true
      deadline_queue.remove(retryQueue, id)
    end
  end

  function mgr.dispatchEvent(eventName)
    if not nonEmpty(eventName) then return 0 end
    local marked = 0
    local function wakeList(list)
      if list == nil then return end
      for i = 1, #list do
        local id = list[i]
        if not dirtySet[id] then
          dirtySet[id] = true
          deadline_queue.remove(retryQueue, id)
          marked = marked + 1
        end
      end
    end
    wakeList(byEvent[eventName])
    -- Route keyed notifications (e.g. weatherChanged:bitter coast, questStageChanged:foo)
    -- to broad base subscribers too.
    local colon = eventName:find(':', 1, true)
    if colon ~= nil then
      wakeList(byEvent[eventName:sub(1, colon - 1)])
    else
      -- Broad event (e.g. weatherChanged, questStageChanged) wakes keyed listeners too.
      local prefix = eventName .. ':'
      local prefixLen = #prefix
      for sub, list in pairs(byEvent) do
        if sub:sub(1, prefixLen) == prefix then
          wakeList(list)
        end
      end
    end
    return marked
  end

  function mgr.onCellEntered()
    if watchWeather then
      mgr.dispatchEvent('weatherChanged')
    end
  end

  -- Evaluates all dirty owners and due unknown-retry owners.
  -- Returns `{ changed = { ownerId, ... }, evaluated = count }`.
  function mgr.evaluateDue(frame, capabilities)
    while true do
      local due = deadline_queue.popNextDue(retryQueue, frame)
      if due == nil then break end
      dirtySet[due.id] = true
    end
    if next(dirtySet) == nil then
      return {changed = {}, evaluated = 0}
    end
    local toEval = {}
    for ownerId in pairs(dirtySet) do toEval[#toEval + 1] = ownerId end
    table.sort(toEval)
    dirtySet = {}

    local changed = {}
    for i = 1, #toEval do
      local ownerId = toEval[i]
      local owner = owners[ownerId]
      local prevTruth = owner.truth
      local wasEval = owner.evaluated
      local nextTruth, reason = evaluateGuard(owner.prepared, capabilities)
      owner.truth = nextTruth
      owner.reason = reason
      owner.evaluated = true
      if nextTruth == 'unknown' then
        unknownSet[ownerId] = true
        deadline_queue.upsert(retryQueue, ownerId, frame + retryDelay)
      else
        unknownSet[ownerId] = nil
        deadline_queue.remove(retryQueue, ownerId)
      end
      if (not wasEval) or nextTruth ~= prevTruth then
        changed[#changed + 1] = ownerId
      end
    end
    return {changed = changed, evaluated = #toEval}
  end

  function mgr.truth(ownerId)
    local owner = owners[ownerId]
    return owner and owner.truth or 'inactive'
  end

  function mgr.unknownOwners()
    return unknownSet
  end

  function mgr.unknownCount()
    local n = 0
    for _ in pairs(unknownSet) do n = n + 1 end
    return n
  end

  function mgr.hasPending(frame)
    return next(dirtySet) ~= nil or deadline_queue.hasDue(retryQueue, frame)
  end

  return mgr, nil
end

return M
