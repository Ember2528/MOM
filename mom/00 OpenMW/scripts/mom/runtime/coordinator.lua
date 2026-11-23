-- Unified runtime coordinator owning one active manifest + ledger + engine session.
-- Frame tick: local completions -> observed cells -> guard events -> guard eval -> reconcile.
local M = {}

local executor_api = require('scripts.mom.runtime.executor')
local guards_api = require('scripts.mom.runtime.guards')
local local_broker_api = require('scripts.mom.runtime.local_broker')
local reconciler_api = require('scripts.mom.runtime.reconciler')
local strings = require('scripts.mom.common.strings')

local nonEmpty = strings.isNonEmpty

local function prepareBindings(manifest, extensionCatalog)
  local actionModules = {}
  local actionsCatalog = extensionCatalog.actions
  local targetFilters = {}
  local grouped = {}

  for _, actionId in ipairs(manifest.actionIds or {}) do
    local action = manifest.actionsById[actionId]
    local entry = actionsCatalog and actionsCatalog.byId and actionsCatalog.byId[action.family] or nil
    if entry == nil or type(entry.module) ~= 'table' then
      return nil, {'missing action module for family ' .. tostring(action.family)}
    end
    actionModules[action.family] = entry.module
    local list = grouped[action.family]
    if list == nil then list = {}; grouped[action.family] = list end
    list[#list + 1] = action
  end

  -- Also retain all discovered runtime action modules so historical/stale ops
  -- from a prior manifest (e.g. startup_plan_change_restart) can still revert!
  for id, entry in pairs(actionsCatalog and actionsCatalog.byId or {}) do
    if type(entry.module) == 'table' and entry.module.execution ~= 'load' then
      actionModules[id] = entry.module
    end
  end

  for family, actions in pairs(grouped) do
    local mod = actionModules[family]
    if type(mod.prepareTargetFilters) == 'function' then
      local ok, filters = pcall(mod.prepareTargetFilters, actions)
      if not ok or type(filters) ~= 'table' then
        return nil, {'prepareTargetFilters failed for ' .. family .. ': ' .. tostring(filters)}
      end
      for actionId, fn in pairs(filters) do
        targetFilters[actionId] = fn
      end
    end
  end

  local guardProviderInterfaces = {}
  local guardCatalog = extensionCatalog.guards
  for guardId in pairs(manifest.extensions and manifest.extensions.guards or {}) do
    local entry = guardCatalog and guardCatalog.byId and guardCatalog.byId[guardId] or nil
    local iface = entry and entry.module and entry.module.providerInterface or nil
    if nonEmpty(iface) then
      guardProviderInterfaces[guardId] = iface
    end
  end

  return {
    actionModules = actionModules,
    targetFilters = targetFilters,
    guardProviderInterfaces = guardProviderInterfaces,
  }, nil
end

function M.prepareActivation(opts)
  local manifest = assert(opts.manifest, 'prepareActivation requires manifest')
  local extensionCatalog = assert(opts.extensionCatalog, 'prepareActivation requires extensionCatalog')
  local bindings, err = prepareBindings(manifest, extensionCatalog)
  if bindings == nil then return nil, err end
  local guards, guardErr = guards_api.new(manifest, extensionCatalog.guards, {
    unknownRetryDelay = opts.unknownRetryDelay,
  })
  if guards == nil then return nil, {guardErr} end
  return {
    manifest = manifest,
    actionModules = bindings.actionModules,
    targetFilters = bindings.targetFilters,
    guardProviderInterfaces = bindings.guardProviderInterfaces,
    guards = guards,
  }, nil
end

function M.new(opts)
  local bundle = assert(opts.activationBundle, 'coordinator requires activationBundle')
  local ledger = assert(opts.ledger, 'coordinator requires ledger')
  local session = assert(opts.session, 'coordinator requires session')

  ledger:setManifestHash(bundle.manifest.contentHash)

  local localBroker = local_broker_api.new({
    isValid = session.world.isValid,
    objectIdOf = function(ref)
      local id = ref and ref.id
      return id ~= nil and tostring(id) or ''
    end,
  })

  local executor = executor_api.new({
    ledger = ledger,
    session = session,
    localBroker = localBroker,
    actionModules = bundle.actionModules,
    targetFilters = bundle.targetFilters,
    manifest = bundle.manifest,
  })

  local reconciler = reconciler_api.new({
    manifest = bundle.manifest,
    ledger = ledger,
    session = session,
    guards = bundle.guards,
    executor = executor,
    localBroker = localBroker,
    actionModules = bundle.actionModules,
    targetFilters = bundle.targetFilters,
  })

  -- Enqueue previsited cells immediately.
  for _, entry in ipairs(opts.previsitCells or {}) do
    if entry and entry.facts and entry.facts.key then
      reconciler.enqueueCell(entry.facts.key)
    end
  end

  return {
    manifest = bundle.manifest,
    ledger = ledger,
    session = session,
    guards = bundle.guards,
    localBroker = localBroker,
    executor = executor,
    reconciler = reconciler,
    frame = math.max(ledger:frame(), tonumber(opts.currentFrame) or 0),
  }, nil
end

function M.tick(rt, opts)
  local frame = opts and opts.frame or (rt.frame + 1)
  rt.frame = frame
  rt.ledger:setFrame(frame)
  rt.session:beginFrame(frame)

  -- 1. Poll local-script lease timeouts & deliver completed local events.
  rt.localBroker.pollTimeouts(frame)
  local completions = rt.localBroker.drainCompletions()
  for i = 1, #completions do
    if rt.executor.deliverCompletion(completions[i], frame) then
      rt.reconciler.markStateDirty()
    end
  end

  -- 2. Sync observed cells (world.activeCells / players / activeActors).
  local entered = rt.session:syncObservedCells(frame)
  if entered ~= nil and #entered > 0 then
    for i = 1, #entered do
      rt.reconciler.enqueueCell(entered[i].facts.key)
    end
    rt.guards.onCellEntered()
  end

  -- 3. Poll time & weather guard changes only when subscribed.
  local events = rt.session:pollGuardEvents(frame, rt.guards.watchTime, rt.guards.watchWeather)
  for i = 1, #(events or {}) do
    rt.guards.dispatchEvent(events[i])
  end

  -- 4. Evaluate dirty & due-retry guard owners.
  local evalRes = rt.guards.evaluateDue(frame, rt.session.guardCapabilities)
  if #evalRes.changed > 0 then
    rt.reconciler.markStateDirty()
  end

  -- 5. Advance pending ops, per-cell static scans, and state reconciliation.
  local stepCounts = rt.reconciler.step(frame)

  return {
    frame = frame,
    guardsEvaluated = evalRes.evaluated,
    discovery = stepCounts.discovery,
    mutations = stepCounts.mutations,
    pending = stepCounts.pending,
  }, nil
end

function M.observeObject(rt, object, frame)
  local currentFrame = frame or rt.frame
  if not rt.session.world.isValid(object) then return true, nil end
  -- Ignore MOM's own spawned generated outputs during active-object observation.
  local objectId = object.id ~= nil and tostring(object.id) or nil
  if objectId ~= nil and rt.ledger:getOutputIdByObjectId(objectId) ~= nil then
    return true, nil
  end
  local entry, isNew = rt.session:observeObject(object, currentFrame)
  if entry ~= nil then
    if isNew then
      rt.reconciler.enqueueCell(entry.facts.key)
      rt.guards.onCellEntered()
    else
      rt.reconciler.observeActiveObject(object, entry.facts.key)
    end
  end
  return true, nil
end

function M.observeCell(rt, cell, frame)
  local entry, isNew = rt.session:observeCell(cell, frame or rt.frame)
  if entry ~= nil and isNew then
    rt.reconciler.enqueueCell(entry.facts.key)
    rt.guards.onCellEntered()
  end
  return true, nil
end

function M.enqueueEvent(rt, eventName)
  rt.guards.dispatchEvent(eventName)
  return true, nil
end

function M.acknowledgeLocal(rt, eventData)
  local matched = rt.localBroker.acknowledge(eventData)
  local completions = rt.localBroker.drainCompletions()
  for i = 1, #completions do
    if rt.executor.deliverCompletion(completions[i], rt.frame) then
      rt.reconciler.markStateDirty()
    end
  end
  return {matched = matched}, nil
end

function M.saveSnapshot(rt)
  return rt.ledger:save()
end

function M.audit(rt)
  return rt.ledger:audit()
end

function M.status(rt, options)
  return rt.reconciler.status(options)
end

function M.clear(rt)
  if rt.localBroker then rt.localBroker.clear() end
  if rt.session and rt.session.clear then rt.session:clear() end
  return true
end

return M
