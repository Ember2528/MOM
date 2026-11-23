-- Canonical claim vocabulary shared by the compiler, runtime, and ledger.
local M = {}

local plain_data = require('scripts.mom.contracts.plain_data')

local SHARED_IDS = {
  'actor.equipment',
  'actor.life',
  'output.existence',
  'ref.enabled',
  'ref.inventory',
  'ref.item_data',
  'ref.lock',
  'ref.owner',
  'ref.position',
  'ref.rotation',
  'ref.scale',
}

local SHARED = {}
for i = 1, #SHARED_IDS do SHARED[SHARED_IDS[i]] = true end

local function validId(value)
  if type(value) ~= 'string' or value == '' then return false end
  if value:sub(1, 1) == '.' or value:sub(-1) == '.' or value:find('..', 1, true) then
    return false
  end
  for segment in value:gmatch('[^.]+') do
    if segment:match('^[a-z][a-z0-9_]*$') == nil then return false end
  end
  return true
end

function M.validateDomain(domain, family)
  if type(domain) ~= 'string' or domain == '' then
    return nil, 'expected non-empty claim domain'
  end
  if SHARED[domain] then return true, nil end

  local privateFamily, name = domain:match('^family:([^:]+):([^:]+)$')
  if privateFamily == nil then return nil, 'unknown claim domain ' .. domain end
  if not validId(privateFamily) then
    return nil, 'private claim family is not a canonical extension ID'
  end
  if not validId(name) then return nil, 'private claim name is not canonical' end
  if family ~= nil and privateFamily ~= family then
    return nil, 'private claim family ' .. privateFamily
      .. ' does not match action family ' .. tostring(family)
  end
  return true, nil
end

function M.normalize(values, family, path, opts)
  path = path or 'claims'
  opts = opts or {}
  local errors = {}
  if type(values) ~= 'table' then return nil, {path .. ': expected array'} end
  local plain, plainErrors = plain_data.validate(values, {path = path})
  if not plain then return nil, plainErrors end
  if next(values) ~= nil and plain_data.shape(values) ~= 'array' then
    return nil, {path .. ': expected dense array'}
  end
  if opts.nonEmpty and #values == 0 then errors[#errors + 1] = path .. ': must not be empty' end

  local out, seen = {}, {}
  for i = 1, #values do
    local value = values[i]
    local valid, reason = M.validateDomain(value, family)
    if not valid then
      errors[#errors + 1] = path .. '[' .. tostring(i) .. ']: ' .. tostring(reason)
    elseif seen[value] then
      errors[#errors + 1] = path .. '[' .. tostring(i) .. ']: duplicate claim ' .. value
    else
      seen[value] = true
      out[#out + 1] = value
    end
  end
  table.sort(out)
  if opts.sorted and #out == #values then
    for i = 1, #out do
      if out[i] ~= values[i] then
        errors[#errors + 1] = path .. ': claims must be sorted'
        break
      end
    end
  end
  if #errors > 0 then return nil, errors end
  return out, nil
end

-- Union already accepted claim lists without revalidating their vocabulary.
local function sortedUnique(values)
  local out, seen = {}, {}
  for i = 1, #(values or {}) do
    local value = values[i]
    if type(value) == 'string' and value ~= '' and not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end
  table.sort(out)
  return out
end

function M.union(left, right)
  local values = {}
  for _, source in ipairs({left or {}, right or {}}) do
    for i = 1, #source do values[#values + 1] = source[i] end
  end
  return sortedUnique(values)
end

return M
