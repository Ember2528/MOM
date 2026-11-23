-- Plain-data, immutable index for action-owned keyed target entries.
--
-- Compiler code pays the O(entry count log entry count) construction cost
-- once. Runtime lookup is O(log distinct records + log distinct positions),
-- and duplicate/predicate fanout is exposed as two ordered arrays that callers
-- can consume cooperatively without retaining the authored entry list again.
local M = {}

local plain_data = require('scripts.mom.contracts.plain_data')
local sortedKeys = require('scripts.mom.common.tables').sortedKeys
local ref_position = require('scripts.mom.domain.ref.position')
local target_predicate_index =
  require('scripts.mom.contracts.target_predicate_index')

local lower = require('scripts.mom.common.strings').lowerString

-- The executor supplies this only for the exact output being captured. Other
-- refs in the same hook must keep their physical record identity.
function M.authoredRecordId(runtimeContext, target, physicalRecordId)
  if type(runtimeContext) == 'table' and target ~= nil
      and runtimeContext.authoredTarget == target then
    local authored = lower(runtimeContext.authoredRecordId)
    if authored ~= nil then return authored end
  end
  return lower(physicalRecordId)
end

local function typeName(entry)
  local value = entry and (entry.inferredType or entry.typeName) or nil
  return type(value) == 'string' and value ~= '' and value or nil
end

local function copy(value, path)
  local out, errors = plain_data.detach(value, {path = path})
  if out == nil then return nil, table.concat(errors or {}, ' | ') end
  return out, nil
end

local function recordKey(record)
  return record.typeName .. '\0' .. record.recordId
end

local function entryKey(entry)
  return typeName(entry), lower(entry and entry.sourceRecordId)
end

local function appendRecord(recordsByKey, entry, order, payload)
  local candidateType, recordId = entryKey(entry)
  if candidateType == nil or recordId == nil then
    return nil, 'target match entry requires resolved type and record identity'
  end
  if entry.sourceKeyKind ~= nil and entry.sourceKeyKind ~= 'record_id' then
    return nil, 'target match entry must be record-resolved'
  end
  local key = candidateType .. '\0' .. recordId
  local record = recordsByKey[key]
  if record == nil then
    record = {
      typeName = candidateType,
      recordId = recordId,
      any = {},
      positionsByKey = {},
    }
    recordsByKey[key] = record
  end
  local filters, filterError = copy(entry.filters or {}, 'targetMatch.filters')
  if filters == nil then return nil, filterError end
  local retainedPayload, payloadError = copy(payload or {}, 'targetMatch.payload')
  if retainedPayload == nil then return nil, payloadError end
  local retained = {
    order = order,
    predicateIndex = target_predicate_index.build(filters),
    payload = retainedPayload,
  }
  local positionKey = ref_position.keyForPosition(entry.sourcePosition)
  if positionKey == nil then
    record.any[#record.any + 1] = retained
  else
    local values = record.positionsByKey[positionKey]
    if values == nil then
      values = {}
      record.positionsByKey[positionKey] = values
    end
    values[#values + 1] = retained
  end
  return true, nil
end

local function normalizeOrder(record)
  -- Only entries for the same record and position can overlap. Any-position
  -- entries are barriers shared by every position; retain precedence across
  -- those barriers without retaining unrelated tuples' source ordinals.
  -- For source order [A1, any1, B1, A2, any2], position A must see
  -- [A1, any1, A2, any2] and B must see [any1, B1, any2]. With five
  -- entries the stride is six: any1/any2 get orders 6/12, A1 gets 1,
  -- and both B1 and A2 get 7 because different positions cannot overlap.
  local count = #record.any
  for _, entries in pairs(record.positionsByKey) do count = count + #entries end
  local stride = count + 1
  for _, entries in pairs(record.positionsByKey) do
    local anyIndex, withinSegment = 1, 0
    for i = 1, #entries do
      local entry = entries[i]
      while record.any[anyIndex] ~= nil
          and record.any[anyIndex].order < entry.order do
        anyIndex = anyIndex + 1
        withinSegment = 0
      end
      withinSegment = withinSegment + 1
      entry.order = (anyIndex - 1) * stride + withinSegment
    end
  end
  for i = 1, #record.any do record.any[i].order = i * stride end
end

function M.build(entries, payloadForEntry)
  if type(entries) ~= 'table' then return nil, 'target match entries must be an array' end
  local recordsByKey = {}
  for i = 1, #entries do
    local entry = entries[i]
    if type(entry) ~= 'table' then
      return nil, 'target match entry ' .. tostring(i) .. ' must be a table'
    end
    local payload = type(payloadForEntry) == 'function'
      and payloadForEntry(entry, i) or {}
    local appended, appendError = appendRecord(recordsByKey, entry, i, payload)
    if not appended then
      return nil, 'target match entry ' .. tostring(i) .. ': ' .. tostring(appendError)
    end
  end
  local records = {}
  for _, key in ipairs(sortedKeys(recordsByKey)) do
    local source = recordsByKey[key]
    normalizeOrder(source)
    local positions = {}
    for _, positionKey in ipairs(sortedKeys(source.positionsByKey)) do
      positions[#positions + 1] = {
        key = positionKey,
        entries = source.positionsByKey[positionKey],
      }
    end
    records[#records + 1] = {
      typeName = source.typeName,
      recordId = source.recordId,
      any = source.any,
      positions = positions,
    }
  end
  return {
    entryCount = #entries,
    records = records,
  }, nil
end

local function binarySearch(values, expected, keyFor)
  local first, last = 1, #(values or {})
  while first <= last do
    local middle = math.floor((first + last) / 2)
    local value = values[middle]
    local key = keyFor(value)
    if key == expected then return value end
    if key < expected then first = middle + 1 else last = middle - 1 end
  end
  return nil
end

function M.record(plan, facts)
  if type(plan) ~= 'table' or type(facts) ~= 'table' then return nil end
  local candidateType = facts.typeName
  local recordId = lower(facts.recordId)
  if type(candidateType) ~= 'string' or candidateType == '' or recordId == nil then
    return nil
  end
  return binarySearch(
    plan.records,
    candidateType .. '\0' .. recordId,
    recordKey
  )
end

function M.positionEntries(record, facts)
  if type(record) ~= 'table' then return nil end
  local origin = type(facts) == 'table' and facts.origin or nil
  local positionKey = ref_position.keyForPosition(
    type(origin) == 'table' and origin.position or nil
  )
  if positionKey == nil then return nil end
  local row = binarySearch(
    record.positions,
    positionKey,
    function(value) return value.key end
  )
  return row and row.entries or nil
end

function M.next(plan, facts, cursor)
  local record = M.record(plan, facts)
  if record == nil then return nil, cursor, true end
  local any = record.any or {}
  local positioned = M.positionEntries(record, facts) or {}
  local anyIndex = cursor and cursor.anyIndex or 1
  local positionIndex = cursor and cursor.positionIndex or 1
  local anyEntry = any[anyIndex]
  local positionEntry = positioned[positionIndex]
  local selected
  if anyEntry ~= nil
      and (positionEntry == nil or anyEntry.order < positionEntry.order) then
    selected = anyEntry
    anyIndex = anyIndex + 1
  elseif positionEntry ~= nil then
    selected = positionEntry
    positionIndex = positionIndex + 1
  end
  local complete = selected == nil
  return selected, {
    anyIndex = anyIndex,
    positionIndex = positionIndex,
    complete = complete,
  }, complete
end

function M.matches(entry, facts)
  if type(entry) ~= 'table' then return nil, 'target match entry is invalid' end
  return target_predicate_index.matches(entry.predicateIndex, facts)
end

function M.readFacts(api, target, runtimeContext)
  local read = type(api) == 'table' and api.selectionFacts or nil
  if type(read) ~= 'function' then
    return nil, 'target selection facts capability is unavailable'
  end
  local ok, raw, reason = pcall(read, target, runtimeContext)
  if not ok then return nil, 'target selection facts failed: ' .. tostring(raw) end
  if type(raw) ~= 'table' then
    return nil, tostring(reason or 'target selection facts are invalid')
  end
  local physicalRecordId = lower(raw.recordId)
  local recordId = physicalRecordId
  local candidateType = raw.typeName
  if recordId == nil or type(candidateType) ~= 'string' or candidateType == '' then
    return nil, 'target selection facts require recordId and typeName'
  end
  recordId = M.authoredRecordId(runtimeContext, target, recordId)
  local position = type(raw.origin) == 'table'
    and ref_position.normalizePosition(raw.origin.position) or nil
  local orientation = type(raw.orientation) == 'table' and {
    yawDegrees = tonumber(raw.orientation.yawDegrees),
    tiltXDegrees = tonumber(raw.orientation.tiltXDegrees),
    tiltYDegrees = tonumber(raw.orientation.tiltYDegrees),
  } or nil
  return {
    recordId = recordId,
    -- Keep the physical record in the cooperative snapshot so a changed
    -- generated record still restarts a keyed match before mutation.
    physicalRecordId = type(runtimeContext) == 'table'
      and runtimeContext.authoredTarget == target
      and runtimeContext.authoredRecordId ~= nil and physicalRecordId or nil,
    typeName = candidateType,
    origin = {position = position},
    orientation = orientation,
  }, nil
end

function M.validate(plan, path)
  path = tostring(path or 'targetMatchPlan')
  if type(plan) ~= 'table'
      or type(plan.entryCount) ~= 'number' or plan.entryCount < 0
      or plan.entryCount % 1 ~= 0 or type(plan.records) ~= 'table' then
    return nil, path .. ': invalid target match plan header'
  end
  local previousRecord, counted = nil, 0
  for i = 1, #plan.records do
    local record = plan.records[i]
    if type(record) ~= 'table' or type(record.typeName) ~= 'string'
        or record.typeName == '' or lower(record.recordId) ~= record.recordId
        or type(record.any) ~= 'table' or type(record.positions) ~= 'table' then
      return nil, path .. '.records[' .. tostring(i) .. ']: invalid record bucket'
    end
    local key = recordKey(record)
    if previousRecord ~= nil and key <= previousRecord then
      return nil, path .. '.records: buckets must be strictly sorted'
    end
    previousRecord = key
    local previousOrder = 0
    for j = 1, #record.any do
      local entry = record.any[j]
      if type(entry) ~= 'table' or type(entry.order) ~= 'number'
          or entry.order <= previousOrder
          or type(entry.predicateIndex) ~= 'table'
          or type(entry.payload) ~= 'table' then
        return nil, path .. '.records[' .. tostring(i)
          .. '].any[' .. tostring(j) .. ']: invalid entry'
      end
      previousOrder = entry.order
      counted = counted + 1
    end
    local previousPosition = nil
    for j = 1, #record.positions do
      local position = record.positions[j]
      if type(position) ~= 'table' or type(position.key) ~= 'string'
          or position.key == '' or type(position.entries) ~= 'table'
          or (previousPosition ~= nil and position.key <= previousPosition) then
        return nil, path .. '.records[' .. tostring(i)
          .. '].positions[' .. tostring(j) .. ']: invalid position bucket'
      end
      previousPosition = position.key
      previousOrder = 0
      for k = 1, #position.entries do
        local entry = position.entries[k]
        if type(entry) ~= 'table' or type(entry.order) ~= 'number'
            or entry.order <= previousOrder
            or type(entry.predicateIndex) ~= 'table'
            or type(entry.payload) ~= 'table' then
          return nil, path .. '.records[' .. tostring(i)
            .. '].positions[' .. tostring(j) .. '].entries[' .. tostring(k)
            .. ']: invalid entry'
        end
        previousOrder = entry.order
        counted = counted + 1
      end
    end
  end
  if counted ~= plan.entryCount then
    return nil, path .. ': entryCount does not match retained entries'
  end
  return true, nil
end

return M
