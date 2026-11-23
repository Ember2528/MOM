-- Sole content mutation owner. Existing record-copy APIs provide detached
-- backups and draft staging; no mutable template handle is treated as a copy.
local M = {}
local contract = require('scripts.mom.contracts.content_plan')
local schema = require('scripts.mom.compiler.content.schema')
local planner = require('scripts.mom.compiler.content.planner')
local plain_data = require('scripts.mom.contracts.plain_data')
local canonical = require('scripts.mom.contracts.canonical')

local get = schema.lookup
local function set(records, id, value)
  local ok, err = pcall(function() records[id] = value end)
  if not ok then return nil, tostring(err) end
  return true
end
local function validatePatch(row)
  local spec = schema.types[row.type]
  if not spec then return nil, 'unsupported content type ' .. tostring(row.type) end
  local scalar, entries = {}, nil
  for key, value in pairs(row.patch) do
    if key == spec.entries then entries = value else scalar[key] = value end
  end
  local normalized, err = schema.patch(row.type, scalar, 'content write patch')
  if not normalized then return nil, err end
  if entries ~= nil then
    entries, err = planner.validateEntries(entries, 'content write entries')
    if not entries then return nil, err end
    normalized[spec.entries] = entries
  end
  if not plain_data.equalValidated(row.patch, normalized) then return nil, 'content write is not normalized' end
  return true
end
local function verifyFields(records, id, patch, typeName, raw)
  local record, err = get(records, id)
  if record == nil then return nil, err or ('record unavailable: ' .. id) end
  local spec = schema.types[typeName]
  for field, desired in pairs(patch) do
    local actual
    if field == spec.entries then actual, err = schema.entries(record, field)
    else actual, err = schema.read(record, field) end
    if err then return nil, err end
    if not schema.equal(field, actual, desired, raw) then return nil, 'record field did not round-trip: ' .. id .. '.' .. field end
  end
  return true
end
local function cleanup(temps)
  local errors = {}
  for i = #temps, 1, -1 do
    local temp = temps[i]
    local existing, readError = get(temp.records, temp.id)
    if readError then errors[#errors + 1] = 'cannot inspect temporary record ' .. temp.id .. ': ' .. readError
    elseif existing ~= nil then
      local ok, err = set(temp.records, temp.id, nil)
      local remaining, verifyError = get(temp.records, temp.id)
      if not ok or verifyError or remaining ~= nil then
        errors[#errors + 1] = 'cannot remove temporary record ' .. temp.id .. ': ' .. tostring(err or verifyError or 'record remains')
      end
    end
  end
  return errors
end
local function result(status, plan, fields)
  fields = fields or {}
  fields.status = status
  fields.contentHash = plan and plan.contentHash or nil
  fields.changedCount = fields.changedCount or 0
  fields.noopCount = plan and plan.metrics and plan.metrics.noopCount or 0
  fields.createdCount = plan and plan.metrics and plan.metrics.createdCount or 0
  fields.attemptedWrites = fields.attemptedWrites or 0
  fields.errors = fields.errors or {}
  fields.cleanupErrors = fields.cleanupErrors or {}
  return fields
end

function M.execute(plan, opts)
  opts = opts or {}
  local valid, validationErrors = contract.validate(plan)
  if not valid then return result('rejected', nil, {errors = validationErrors}) end
  local contexts, temps = {}, {}
  local prefix = 'mom__content_' .. assert(canonical.hashBody(plan.contentHash)) .. '_'
  -- Every collision, target, baseline and normalized field is checked before
  -- staging touches a store. Temporary IDs never participate in selection.
  for index, row in ipairs(plan.writes) do
    local ok, err = validatePatch(row)
    if not ok then return result('rejected', plan, {errors = {err}}) end
    local records, storeError = schema.store(opts.content or {}, row.type)
    if not records then return result('rejected', plan, {errors = {storeError}}) end
    local target, targetError = get(records, row.id)
    if targetError or (row.create and target ~= nil) or (not row.create and target == nil) then
      return result('rejected', plan, {errors = {targetError or 'content target existence changed: ' .. row.id}})
    end
    local template, templateError = get(records, row.template)
    if template == nil then return result('rejected', plan, {errors = {templateError or 'content template disappeared: ' .. row.template}}) end
    local baselineOk, baselineError = verifyFields(records, row.template, row.baseline, row.type, true)
    if not baselineOk then return result('rejected', plan, {errors = {'content baseline changed: ' .. tostring(baselineError)}}) end
    if row.changed then
      local context = {row = row, records = records, backup = prefix .. tostring(index) .. '_backup',
        stage = prefix .. tostring(index) .. '_stage'}
      for _, id in ipairs({context.backup, context.stage}) do
        local previous, readError = get(records, id)
        if readError or previous ~= nil then
          return result('rejected', plan, {errors = {readError or ('temporary record collision: ' .. id)}})
        end
      end
      contexts[#contexts + 1] = context
    end
  end
  if #contexts == 0 then return result('noop', plan) end
  local function stagedFailure(message)
    local cleanupErrors = cleanup(temps)
    return result(#cleanupErrors == 0 and 'rejected' or 'partial', plan,
      {errors = {message}, cleanupErrors = cleanupErrors})
  end
  for _, context in ipairs(contexts) do
    local row, records = context.row, context.records
    -- Back up templates for creations too, so staging always reads a detached
    -- pre-edit copy even when another planned write patches that template.
    temps[#temps + 1] = {records = records, id = context.backup}
    local original, readError = get(records, row.template)
    if original == nil then return stagedFailure(readError or 'template disappeared before backup') end
    local ok, err = set(records, context.backup, original)
    if not ok then return stagedFailure('cannot snapshot ' .. row.id .. ': ' .. err) end
    local snapshot, snapshotError = get(records, context.backup)
    if snapshot == nil then return stagedFailure(snapshotError or 'backup was not created') end
    local draft = assert(plain_data.detach(row.patch))
    if draft.chanceNone ~= nil then draft.chanceNone = schema.nativeValue('chanceNone', draft.chanceNone) end
    if draft.color ~= nil and type(opts.colorFromRGB) == 'function' then
      local converted, color = pcall(opts.colorFromRGB, draft.color)
      if not converted then return stagedFailure('cannot prepare light color: ' .. tostring(color)) end
      draft.color = color
    end
    draft.template = snapshot
    temps[#temps + 1] = {records = records, id = context.stage}
    ok, err = set(records, context.stage, draft)
    if not ok then return stagedFailure('draft rejected for ' .. row.id .. ': ' .. err) end
    ok, err = verifyFields(records, context.stage, row.patch, row.type)
    if not ok then return stagedFailure('draft rejected for ' .. row.id .. ': ' .. err) end
  end
  local attempted, commitError = {}, nil
  for _, context in ipairs(contexts) do
    attempted[#attempted + 1] = context
    local staged, stageError = get(context.records, context.stage)
    if staged == nil then commitError = stageError or 'staged record disappeared'; break end
    local ok, err = set(context.records, context.row.id, staged)
    if not ok then commitError = err; break end
    ok, err = verifyFields(context.records, context.row.id, context.row.patch, context.row.type)
    if not ok then commitError = err; break end
  end
  if commitError then
    local restorationErrors = {}
    for i = #attempted, 1, -1 do
      local context = attempted[i]
      local backup, readError = get(context.records, context.backup)
      local ok, err
      if context.row.create then ok, err = set(context.records, context.row.id, nil)
      elseif backup == nil then err = readError or 'backup disappeared'
      else ok, err = set(context.records, context.row.id, backup) end
      if not ok then restorationErrors[#restorationErrors + 1] = 'cannot restore ' .. context.row.id .. ': ' .. tostring(err)
      elseif context.row.create then
        local value, verifyError = get(context.records, context.row.id)
        if value ~= nil or verifyError then restorationErrors[#restorationErrors + 1] = 'created record remains: ' .. context.row.id end
      else
        local restored, verifyError = verifyFields(context.records, context.row.id, context.row.baseline, context.row.type, true)
        if not restored then restorationErrors[#restorationErrors + 1] = 'restore verification failed: ' .. tostring(verifyError) end
      end
    end
    local cleanupErrors = cleanup(temps)
    local errors = {'content commit failed: ' .. tostring(commitError)}
    for _, err in ipairs(restorationErrors) do errors[#errors + 1] = err end
    return result(#restorationErrors == 0 and #cleanupErrors == 0 and 'restored_failure' or 'partial', plan,
      {errors = errors, cleanupErrors = cleanupErrors, attemptedWrites = #attempted})
  end
  local cleanupErrors = cleanup(temps)
  return result(#cleanupErrors == 0 and 'committed' or 'partial', plan,
    {changedCount = #contexts, attemptedWrites = #attempted, cleanupErrors = cleanupErrors})
end
return M
