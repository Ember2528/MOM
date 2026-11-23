-- Immutable wire contract for LOAD-owned record mutations. Engine values never
-- enter a plan: templates and targets are addressed by stable content IDs.
local M = {VERSION = 1, KIND = 'mom-content-plan'}
local plain_data = require('scripts.mom.contracts.plain_data')
local canonical = require('scripts.mom.contracts.canonical')

function M.definition(plan)
  local writes = {}
  for _, row in ipairs(plan.writes or {}) do
    writes[#writes + 1] = {type = row.type, id = row.id, template = row.template,
      create = row.create, patch = row.patch}
  end
  return {version = plan.version, writes = writes}
end

function M.integrity(plan)
  return canonical.assertHash({version = plan.version, writes = plan.writes}, {path = 'contentPlanIntegrity'})
end

function M.identity(plan)
  return canonical.assertHash(M.definition(plan), {path = 'contentPlan'})
end

function M.validate(plan)
  local ok, errors = plain_data.validate(plan, {path = 'contentPlan'})
  if not ok then return nil, errors end
  errors = {}
  if type(plan) ~= 'table' or plan.kind ~= M.KIND or plan.version ~= M.VERSION then
    return nil, {'contentPlan: unsupported kind or version'}
  end
  if type(plan.writes) ~= 'table' then return nil, {'contentPlan.writes: expected array'} end
  for key in pairs(plan.writes) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > #plan.writes then
      return nil, {'contentPlan.writes: expected dense array'}
    end
  end
  local seen = {}
  for i, row in ipairs(plan.writes) do
    local path = 'contentPlan.writes[' .. tostring(i) .. ']'
    if type(row) ~= 'table' or type(row.type) ~= 'string'
        or type(row.id) ~= 'string' or row.id == ''
        or type(row.template) ~= 'string' or row.template == ''
        or type(row.create) ~= 'boolean' or type(row.patch) ~= 'table'
        or type(row.baseline) ~= 'table' or type(row.changed) ~= 'boolean' then
      errors[#errors + 1] = path .. ': invalid record write'
    else
      local key = row.type .. '\0' .. row.id
      if seen[key] then errors[#errors + 1] = path .. ': duplicate record write' end
      seen[key] = true
    end
  end
  if #errors > 0 then return nil, errors end
  if plan.integrityHash ~= M.integrity(plan) then
    return nil, {'contentPlan.integrityHash: write integrity mismatch'}
  end
  if plan.contentHash ~= M.identity(plan) then
    return nil, {'contentPlan.contentHash: content identity mismatch'}
  end
  return true, nil
end
return M
