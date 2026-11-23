-- Lean actor-local script command broker (~190 lines).
-- Manages per-object script attachment refcounting, unique request IDs,
-- lease timeout expiry via common/deadline_queue, and generic opaque
-- completion delivery (no family-specific fields).
local M = {}

local deadline_queue = require('scripts.mom.common.deadline_queue')
local strings = require('scripts.mom.common.strings')

local nonEmpty = strings.isNonEmpty
local DEFAULT_LEASE_FRAMES = 120

function M.new(opts)
  opts = opts or {}
  local isValid = opts.isValid or function(obj) return obj ~= nil end
  local objectIdOf = opts.objectIdOf or function(obj) return tostring(obj and obj.id or '') end
  local attachScript = opts.attachScript or function(obj, path)
    local ok, has = pcall(obj.hasScript, obj, path)
    if ok and has == true then return true end
    local okAdd, err = pcall(obj.addScript, obj, path)
    if not okAdd then return nil, tostring(err) end
    return true
  end
  local detachScript = opts.detachScript or function(obj, path)
    local ok, has = pcall(obj.hasScript, obj, path)
    if not ok or has ~= true then return true end
    local okRem, err = pcall(obj.removeScript, obj, path)
    if not okRem then return nil, tostring(err) end
    return true
  end
  local sendEvent = opts.sendEvent or function(obj, eventName, payload)
    local ok, err = pcall(obj.sendEvent, obj, eventName, payload)
    if not ok then return nil, tostring(err) end
    return true
  end

  local seq = 0
  local requests = {}        -- requestId -> { requestId, opId, objectId, ref, scriptPath, cancelEvent }
  local byOpId = {}          -- opId -> requestId
  local attachments = {}     -- objectId..'\0'..scriptPath -> { ref, scriptPath, count }
  local deadlines = deadline_queue.new()
  local completions = {}     -- FIFO array of { opId, requestId, ok, expired, error, data }

  local function attachKey(objectId, scriptPath)
    return objectId .. '\0' .. scriptPath
  end

  local function acquireAttachment(ref, objectId, scriptPath)
    local key = attachKey(objectId, scriptPath)
    local rec = attachments[key]
    if rec ~= nil then
      rec.ref = ref
      rec.count = rec.count + 1
      return true, nil
    end
    local ok, err = attachScript(ref, scriptPath)
    if not ok then return nil, err end
    attachments[key] = {ref = ref, scriptPath = scriptPath, count = 1}
    return true, nil
  end

  local function releaseAttachment(objectId, scriptPath, fallbackRef)
    local key = attachKey(objectId, scriptPath)
    local rec = attachments[key]
    if rec == nil then return end
    rec.count = rec.count - 1
    if rec.count <= 0 then
      attachments[key] = nil
      local target = isValid(rec.ref) and rec.ref or (isValid(fallbackRef) and fallbackRef or nil)
      if target ~= nil then
        pcall(detachScript, target, scriptPath)
      end
    end
  end

  local broker = {}

  function broker.send(opId, ref, scriptPath, eventName, payload, sendOpts)
    sendOpts = sendOpts or {}
    if not nonEmpty(opId) then return nil, 'local broker requires opId' end
    if not isValid(ref) then return nil, 'local script target ref is invalid' end
    local objectId = objectIdOf(ref)
    if not nonEmpty(objectId) then return nil, 'local script target objectId is unavailable' end

    -- If this op already has an active in-flight request, do not send a duplicate.
    local existingReqId = byOpId[opId]
    if existingReqId ~= nil and requests[existingReqId] ~= nil then
      return existingReqId, nil
    end

    local okAttach, attachErr = acquireAttachment(ref, objectId, scriptPath)
    if not okAttach then return nil, attachErr end

    seq = seq + 1
    local requestId = opId .. ':req:' .. tostring(seq)
    local body = {}
    for k, v in pairs(payload or {}) do body[k] = v end
    body.commandId = opId
    body.requestId = requestId

    local okSend, sendErr = sendEvent(ref, eventName, body)
    if not okSend then
      releaseAttachment(objectId, scriptPath, ref)
      return nil, sendErr
    end

    local frame = tonumber(sendOpts.frame) or 0
    local lease = tonumber(sendOpts.leaseFrames) or DEFAULT_LEASE_FRAMES
    requests[requestId] = {
      requestId = requestId,
      opId = opId,
      objectId = objectId,
      ref = ref,
      scriptPath = scriptPath,
      cancelEvent = sendOpts.cancelEvent,
    }
    byOpId[opId] = requestId
    deadline_queue.upsert(deadlines, requestId, frame + lease)
    return requestId, nil
  end

  function broker.acknowledge(eventData)
    if type(eventData) ~= 'table' then return false end
    local reqId = eventData.requestId
    local opId = eventData.commandId
    local req = nonEmpty(reqId) and requests[reqId] or nil
    if req == nil and nonEmpty(opId) then
      local mapped = byOpId[opId]
      req = mapped and requests[mapped] or nil
    end
    if req == nil then return false end

    requests[req.requestId] = nil
    if byOpId[req.opId] == req.requestId then
      byOpId[req.opId] = nil
    end
    deadline_queue.remove(deadlines, req.requestId)
    releaseAttachment(req.objectId, req.scriptPath, eventData.object or req.ref)

    completions[#completions + 1] = {
      opId = req.opId,
      requestId = req.requestId,
      ok = eventData.ok == true,
      expired = false,
      error = eventData.error,
      data = eventData,
    }
    return true
  end

  function broker.pollTimeouts(frame)
    local expiredCount = 0
    while true do
      local due = deadline_queue.popNextDue(deadlines, frame)
      if due == nil then break end
      local req = requests[due.id]
      if req ~= nil then
        requests[due.id] = nil
        if byOpId[req.opId] == due.id then byOpId[req.opId] = nil end
        if req.cancelEvent and isValid(req.ref) then
          pcall(sendEvent, req.ref, req.cancelEvent, {
            commandId = req.opId,
            requestId = req.requestId,
          })
        end
        releaseAttachment(req.objectId, req.scriptPath, req.ref)
        completions[#completions + 1] = {
          opId = req.opId,
          requestId = req.requestId,
          ok = false,
          expired = true,
          error = 'local script request timed out',
          data = nil,
        }
        expiredCount = expiredCount + 1
      end
    end
    return expiredCount
  end

  function broker.drainCompletions()
    if #completions == 0 then return {} end
    local out = completions
    completions = {}
    return out
  end

  function broker.hasInFlight(opId)
    local reqId = byOpId[opId]
    return reqId ~= nil and requests[reqId] ~= nil
  end

  function broker.inFlightCount()
    local n = 0
    for _ in pairs(requests) do n = n + 1 end
    return n
  end

  function broker.clear()
    for _, req in pairs(requests) do
      if req.cancelEvent and isValid(req.ref) then
        pcall(sendEvent, req.ref, req.cancelEvent, {
          commandId = req.opId,
          requestId = req.requestId,
          clear = true,
        })
      end
    end
    for _, rec in pairs(attachments) do
      if isValid(rec.ref) then
        pcall(detachScript, rec.ref, rec.scriptPath)
      end
    end
    requests = {}
    byOpId = {}
    attachments = {}
    deadline_queue.clear(deadlines)
    completions = {}
  end

  return broker
end

return M
