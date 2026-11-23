-- Declarative replacement choices shared by native and imported actions.
-- This module has no engine bindings. Only compiler-owned descriptors contain
-- compiled profiles; authored expressions retain the ordinary declarative form.
local M = {}
local tables = require('scripts.mom.common.tables')
local plain = require('scripts.mom.contracts.plain_data')
local keyed = require('scripts.mom.compiler.keyed_targets')
local model = require('scripts.mom.contracts.model_path')
local spatial = require('scripts.mom.domain.variation.spatial')
local finite = require('scripts.mom.common.numbers').isFinite
local canonical = require('scripts.mom.contracts.canonical')
local cache = setmetatable({}, {__mode = 'k'})
local FIELDS = {choose = true, profile = true, keep = true, keepWeight = true, order = true}
local function target(raw, path)
  local kind, value
  if type(raw) == 'string' and raw ~= '' then
    kind = keyed.isLikelyMeshPath(raw) and 'model_path' or 'record_id'
    value = raw
  elseif tables.isObject(raw) then
    local count = 0
    for key in pairs(raw) do
      if key ~= 'recordId' and key ~= 'model' then return nil, path .. '.' .. tostring(key) .. ': is not allowed' end
      count = count + 1
    end
    if count ~= 1 then return nil, path .. ': expected exactly one of recordId or model' end
    kind, value = raw.model ~= nil and 'model_path' or 'record_id', raw.model or raw.recordId
    if type(value) ~= 'string' or value == '' then return nil, path .. ': expected non-empty target string' end
  else return nil, path .. ': expected target string, recordId or model object' end
  value = kind == 'model_path' and model.normalize(value) or value:lower()
  if not value then return nil, path .. ': invalid target' end
  return {targetKind = kind, targetValue = value}
end
function M.isExpression(raw) return type(raw) == 'table' and raw.choose ~= nil end
function M.normalize(raw, path)
  path = path or 'replacement'
  if not tables.isObject(raw) then return nil, path .. ': expected replacement expression' end
  for key in pairs(raw) do if not FIELDS[key] then return nil, path .. '.' .. tostring(key) .. ': is not allowed' end end
  if not tables.isArray(raw.choose) or #raw.choose == 0 then return nil, path .. '.choose: expected non-empty target/weight tuples' end
  if raw.keep ~= nil and raw.keep ~= 'stop' and raw.keep ~= 'continue' then return nil, path .. '.keep: expected stop or continue' end
  if raw.order ~= nil and (type(raw.order) ~= 'string' or raw.order == '') then return nil, path .. '.order: expected non-empty semantic order key' end
  if raw.keepWeight ~= nil and (not finite(raw.keepWeight) or raw.keepWeight < 0) then return nil, path .. '.keepWeight: expected nonnegative finite weight' end
  local out = {choose = {}, keep = raw.keep or 'stop', order = raw.order, keepWeight = raw.keepWeight}
  local targets, weights, positive = {}, {raw.keepWeight or 0}, (raw.keepWeight or 0) > 0
  for i, tuple in ipairs(raw.choose) do
    local at = path .. '.choose[' .. tostring(i) .. ']'
    if not tables.isArray(tuple) or #tuple ~= 2 then return nil, at .. ': expected [target, weight]' end
    if not finite(tuple[2]) or tuple[2] < 0 then return nil, at .. '[2]: expected nonnegative finite weight' end
    local value, err = target(tuple[1], at .. '[1]'); if not value then return nil, err end
    targets[i] = value
    out.choose[i] = {{[value.targetKind == 'model_path' and 'model' or 'recordId'] = value.targetValue}, tuple[2]}
    weights[#weights + 1], positive = tuple[2], positive or tuple[2] > 0
  end
  local profileInput = raw.profile
  if profileInput == nil then
    if not positive then return nil, path .. '.choose: at least one weight must be positive' end
    profileInput = {default = weights}
  elseif type(profileInput) ~= 'table' then return nil, path .. '.profile: expected spatial profile object' end
  local profile, err = spatial.compile(profileInput, {variantCount = #targets})
  if not profile then return nil, path .. '.profile: ' .. tostring(err) end
  if raw.profile ~= nil then
    local copied, errors = plain.detach(raw.profile, {path = path .. '.profile'})
    if not copied then return nil, table.concat(errors or {}, ' | ') end
    out.profile = copied
  end
  local descriptor = {targets = targets, profile = profile, keepStops = out.keep == 'stop', orderKey = out.order}
  cache[out] = {hash = canonical.assertHashValidated(out), descriptor = descriptor}
  return out, nil, descriptor
end
function M.descriptor(raw, path)
  local fingerprint = type(raw) == 'table' and canonical.hash(raw) or nil
  local cached = type(raw) == 'table' and cache[raw]
  if cached and fingerprint and cached.hash == fingerprint then return cached.descriptor end
  local normalized, err, descriptor = M.normalize(raw, path)
  if not normalized then return nil, err end
  -- Reusing a profile must never turn an edited expression into a stale
  -- promotion proof. Keys are weak and every hit verifies semantic input.
  if type(raw) == 'table' and fingerprint then cache[raw] = {hash = fingerprint, descriptor = descriptor} end
  return descriptor
end
function M.constant(raw, path)
  local descriptor, err = M.descriptor(raw, path)
  if not descriptor then return nil, nil, err end
  local selected = spatial.constantChoice(descriptor.profile)
  if selected == nil then return nil, 'variable' end
  if selected == 0 then return nil, 'keep' end
  return descriptor.targets[selected], 'target'
end
return M
