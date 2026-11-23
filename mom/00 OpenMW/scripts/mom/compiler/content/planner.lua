-- Read-only content compiler. It resolves the pre-edit catalog once and
-- produces a detached plan; only executor.lua may issue writes.
local composition = require('scripts.mom.contracts.composition_order')
local M = {}
local schema = require('scripts.mom.compiler.content.schema')
local contract = require('scripts.mom.contracts.content_plan')
local plain_data = require('scripts.mom.contracts.plain_data')
local canonical = require('scripts.mom.contracts.canonical')
local NODE_FIELDS = {kind = true, payload = true, source = true, priority = true,
  order = true, compositionOrder = true}

local function copy(value) return assert(plain_data.detach(value)) end
local read = schema.lookup
local function validateEntries(raw, path)
  if not schema.array(raw) then return nil, path .. ': expected dense entry array' end
  local out = {}
  for i, value in ipairs(raw) do
    local itemPath = path .. '[' .. tostring(i) .. ']'
    local ok, err = schema.object(value, {id = true, level = true}, itemPath)
    if not ok then return nil, err end
    local id = schema.id(value.id)
    if not id or not schema.integer(value.level, 0, 65535) then
      return nil, itemPath .. ': expected record id and integer level in [0, 65535]'
    end
    out[#out + 1] = {id = id, level = value.level}
  end
  return out
end
M.validateEntries = validateEntries
local function applyOperation(entries, op, path)
  local ok, err = schema.object(op, {op = true, match = true, entries = true}, path)
  if not ok then return nil, err end
  local kind = op.op
  if kind ~= 'append' and kind ~= 'add_if_absent' and kind ~= 'remove'
      and kind ~= 'replace' and kind ~= 'set' and kind ~= 'merge_by_id' then
    return nil, path .. '.op: unsupported list operation'
  end
  local replacement
  if kind ~= 'remove' then
    replacement, err = validateEntries(op.entries, path .. '.entries')
    if not replacement then return nil, err end
  elseif op.entries ~= nil then return nil, path .. '.entries: remove does not accept entries' end
  local match
  if kind == 'remove' or kind == 'replace' then
    ok, err = schema.object(op.match, {id = true, level = true}, path .. '.match')
    if not ok then return nil, err end
    match = {id = schema.id(op.match.id), level = op.match.level}
    if not match.id or (match.level ~= nil and not schema.integer(match.level, 0, 65535)) then
      return nil, path .. '.match: expected ID and optional level in [0, 65535]'
    end
  elseif op.match ~= nil then return nil, path .. '.match: only remove/replace accept a match' end
  if kind == 'set' then return replacement end
  local out = (kind == 'remove' or kind == 'replace') and {} or copy(entries)
  if kind == 'append' then
    for _, entry in ipairs(replacement) do out[#out + 1] = entry end
    return out
  end
  if kind == 'add_if_absent' then
    -- Identity here is the explicit ID+level pair. Native append retains
    -- weighting duplicates; this operation never coalesces existing entries.
    local seen = {}
    for _, entry in ipairs(out) do seen[entry.id .. '\0' .. tostring(entry.level)] = true end
    for _, entry in ipairs(replacement) do
      local key = entry.id .. '\0' .. tostring(entry.level)
      if not seen[key] then out[#out + 1], seen[key] = entry, true end
    end
    return out
  end
  if kind == 'merge_by_id' then
    -- VFR's additive policy updates every occurrence of an ID without
    -- discarding weighting duplicates or other edits already in this plan.
    local levels, order, seen = {}, {}, {}
    for _, entry in ipairs(replacement) do
      if levels[entry.id] == nil then order[#order + 1] = entry.id end
      levels[entry.id] = entry.level
    end
    for _, entry in ipairs(out) do
      if levels[entry.id] ~= nil then entry.level = levels[entry.id] end
      seen[entry.id] = true
    end
    for _, id in ipairs(order) do
      if not seen[id] then out[#out + 1] = {id = id, level = levels[id]} end
    end
    return out
  end
  local inserted = false
  for _, entry in ipairs(entries) do
    if entry.id == match.id and (match.level == nil or entry.level == match.level) then
      if kind == 'replace' and not inserted then
        for _, value in ipairs(replacement) do out[#out + 1] = value end
        inserted = true
      end
    else out[#out + 1] = copy(entry) end
  end
  return out
end
M.applyOperation = applyOperation

local function compile(nodes, opts)
  opts = opts or {}
  local content = opts.content or {}
  if not schema.array(nodes) then return nil, {'content nodes: expected array'} end
  local valid, detachErrors = plain_data.validate(nodes, {path = 'contentNodes'})
  if not valid then return nil, detachErrors end
  local ordered, creates, errors = {}, {}, {}
  for index, node in ipairs(nodes) do
    local path = type(node.source) == 'string' and node.source or ('content[' .. tostring(index) .. ']')
    local ok, err = schema.object(node, NODE_FIELDS, path)
    if ok then ok, err = composition.validate(node.compositionOrder, path .. '.compositionOrder') end
    if not ok then errors[#errors + 1] = err
    elseif (node.kind ~= 'record' and node.kind ~= 'leveled') or type(node.payload) ~= 'table'
        or (node.priority ~= nil and not schema.integer(node.priority, -2147483648, 2147483647))
        or (node.order ~= nil and not schema.integer(node.order, 0, 2147483647)) then
      errors[#errors + 1] = path .. ': invalid content kind, payload, priority, or order'
    else
      ordered[#ordered + 1] = {node = node, source = path, priority = node.priority or 0,
        order = node.order or index, compositionOrder = node.compositionOrder}
      if node.payload.create == true then
        local key = tostring(node.payload.type) .. '\0' .. tostring(schema.id(node.payload.id))
        if creates[key] then errors[#errors + 1] = path .. ': duplicate named record creation' end
        creates[key] = true
      end
    end
  end
  if #errors > 0 then return nil, errors end
  table.sort(ordered, composition.less)
  local targets, order, diagnostics = {}, {}, {}
  local metrics = {inputCount = #nodes, recordReads = 0, changedCount = 0, noopCount = 0,
    createdCount = 0, unverifiedMembers = 0}
  local function fail(path, message) errors[#errors + 1] = path .. ': ' .. message end
  local function target(row)
    local payload, path = row.node.payload, row.source
    local ok, err = schema.object(payload, schema.payloadFields[row.node.kind], path)
    if not ok then fail(path, err); return end
    local typeName, id = payload.type, schema.id(payload.id)
    local spec = schema.types[typeName]
    if not spec or not id or id:match('^mom__content_') then
      fail(path, 'unsupported type, invalid ID, or reserved MOM ID'); return
    end
    if (row.node.kind == 'leveled') ~= (spec.entries ~= nil) then
      fail(path, 'record/list verb does not match target type'); return
    end
    if payload.create ~= nil and type(payload.create) ~= 'boolean' then
      fail(path, 'create must be boolean'); return
    end
    local create = payload.create == true
    if not create and payload.template ~= nil then fail(path, 'template requires create=true'); return end
    local template = create and schema.id(payload.template) or id
    if not template then fail(path, 'named creation requires an installed template'); return end
    if create and creates[typeName .. '\0' .. template] then
      fail(path, 'same-plan template/dependency chains are unsupported'); return
    end
    local records, storeError = schema.store(content, typeName)
    if not records then fail(path, storeError); return end
    local key = typeName .. '\0' .. id
    local existing = targets[key]
    if existing then
      if existing.create ~= create or existing.template ~= template then
        fail(path, 'target creation/template policies conflict'); return
      end
      return existing, records, spec
    end
    metrics.recordReads = metrics.recordReads + 1
    local original, readError = read(records, id)
    if readError then fail(path, 'cannot read target: ' .. readError); return end
    if create and original ~= nil then fail(path, 'named record already exists'); return end
    if not create and original == nil then fail(path, 'target record is unavailable'); return end
    if create then
      metrics.recordReads = metrics.recordReads + 1
      original, readError = read(records, template)
      if original == nil then fail(path, 'installed template is unavailable: ' .. tostring(readError or template)); return end
    end
    local entry = {type = typeName, id = id, template = template, create = create,
      patch = {}, baseline = {}, changed = create, sources = {}, claims = {}, original = original}
    if spec.entries then
      local values, listError = schema.entries(original, spec.entries)
      if not values then fail(path, 'cannot read list: ' .. listError); return end
      local normalized, entryError = validateEntries(values, path .. '.' .. spec.entries)
      if not normalized then fail(path, entryError); return end
      entry.listBaseline, entry.listCurrent = normalized, copy(normalized)
    end
    targets[key], order[#order + 1] = entry, key
    return entry, records, spec
  end
  for _, row in ipairs(ordered) do
    local entry, records, spec = target(row)
    if entry then
      local payload, path = row.node.payload, row.source
      local patch, patchError = schema.patch(entry.type, payload.patch or {}, path .. '.patch', opts.modelExists)
      if not patch then fail(path, patchError)
      else
        entry.sources[#entry.sources + 1] = path
        for field, value in pairs(patch) do
          local previous = entry.claims[field]
          if previous and previous.priority == row.priority
              and previous.value ~= value then
            fail(path, 'conflicting equal-priority writes to ' .. entry.type .. '/' .. entry.id .. '.' .. field)
          elseif not previous or previous.priority <= row.priority then
            if entry.baseline[field] == nil then
              local baseline, readError = schema.read(entry.original, field)
              if readError then fail(path, 'field unavailable: ' .. field .. ': ' .. readError)
              else entry.baseline[field] = baseline end
            end
            entry.patch[field] = value
            entry.claims[field] = {priority = row.priority, value = value}
          end
        end
        if spec.entries then
          if payload.operations ~= nil and not schema.array(payload.operations) then
            fail(path, 'operations must be a dense array')
          else
            for index, op in ipairs(payload.operations or {}) do
              local nextList, operationError = applyOperation(entry.listCurrent, op,
                path .. '.operations[' .. tostring(index) .. ']')
              if not nextList then fail(path, operationError) else entry.listCurrent = nextList end
            end
          end
        elseif next(patch) == nil and not entry.create then fail(path, 'record patch must not be empty') end
      end
    end
  end
  if #errors > 0 then return nil, errors end
  -- Follow only nested list edges reached by affected lists. Installed cycles
  -- are not rewritten; reject a newly introduced edge that closes a cycle.
  local listCache = {}
  local function listEntries(typeName, id)
    local key = typeName .. '\0' .. id
    if targets[key] then return targets[key].listCurrent end
    if listCache[key] ~= nil then return listCache[key] or nil end
    local records = schema.store(content, typeName)
    local value = records and read(records, id)
    local entries = value and schema.entries(value, schema.types[typeName].entries)
    listCache[key] = entries or false
    return entries
  end
  local function reaches(typeName, start, finish)
    local pending, seen = {start}, {}
    while #pending > 0 do
      local id = table.remove(pending)
      if id == finish then return true end
      if not seen[id] then
        seen[id] = true
        for _, item in ipairs(listEntries(typeName, id) or {}) do
          if listEntries(typeName, item.id) then pending[#pending + 1] = item.id end
        end
      end
    end
    return false
  end
  for _, key in ipairs(order) do
    local entry = targets[key]
    local spec = schema.types[entry.type]
    if spec.entries then
      local previous = {}
      for _, item in ipairs(entry.listBaseline) do previous[item.id] = true end
      local covered = {}
      for _, item in ipairs(entry.listCurrent) do
        if not covered[item.id] then
          covered[item.id] = true
          if listEntries(entry.type, item.id) then
            if not previous[item.id] and reaches(entry.type, item.id, entry.id) then
              fail(entry.sources[1], 'new cyclic list reference through ' .. item.id)
            end
          else
            local otherType = entry.type == 'CreatureLevelledList' and 'ItemLevelledList' or 'CreatureLevelledList'
            if listEntries(otherType, item.id) then fail(entry.sources[1], 'list member has incompatible list type: ' .. item.id)
            else
              metrics.unverifiedMembers = metrics.unverifiedMembers + 1
              if #diagnostics < 64 then diagnostics[#diagnostics + 1] = {
                severity = 'info', code = 'content_member_unverified', source = entry.sources[1],
                type = entry.type, id = item.id,
                message = 'symbolic list member existence/type is not verified in LOAD',
              } end
            end
          end
        end
      end
      if not schema.equal(spec.entries, entry.listBaseline, entry.listCurrent) then
        entry.patch[spec.entries] = copy(entry.listCurrent)
        entry.baseline[spec.entries] = copy(entry.listBaseline)
      end
    end
  end
  if #errors > 0 then return nil, errors end
  table.sort(order)
  local writes = {}
  for _, key in ipairs(order) do
    local entry = targets[key]
    for field, desired in pairs(entry.patch) do
      if not schema.unchanged(field, entry.baseline[field], desired) then entry.changed = true end
    end
    if entry.changed then metrics.changedCount = metrics.changedCount + 1
    else metrics.noopCount = metrics.noopCount + 1 end
    if entry.create then metrics.createdCount = metrics.createdCount + 1 end
    writes[#writes + 1] = {type = entry.type, id = entry.id, template = entry.template,
      create = entry.create, patch = copy(entry.patch), baseline = copy(entry.baseline),
      changed = entry.changed, sources = copy(entry.sources)}
  end
  local plan = {kind = contract.KIND, version = contract.VERSION, writes = writes,
    diagnostics = diagnostics, metrics = metrics}
  plan.contentHash = contract.identity(plan)
  plan.integrityHash = contract.integrity(plan)
  return plan
end

function M.compile(nodes, opts)
  local ok, plan, errors = pcall(compile, nodes, opts)
  if not ok then return nil, {'content compile failed: ' .. tostring(plan)} end
  return plan, errors
end
M.types = schema.types
M.store = schema.store
return M
