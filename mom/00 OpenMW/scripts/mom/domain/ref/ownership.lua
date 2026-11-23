local M = {}

local function readField(ownerApi, field)
  local ok, value = pcall(function()
    return ownerApi[field]
  end)
  if not ok or value == nil or value == '' then return nil end
  return value
end

local function setField(ownerApi, field, value)
  ownerApi[field] = value
end

local function trySetField(ownerApi, field, value)
  local ok, err = pcall(setField, ownerApi, field, value)
  if not ok then return false, err end
  return true
end

function M.copy(owner)
  if owner == nil then return nil end
  local out = {
    clear = owner.clear == true or nil,
    recordId = owner.recordId,
    factionId = owner.factionId,
  }
  if out.factionId ~= nil then
    out.factionRank = owner.factionRank
  end
  return next(out) and out or nil
end

function M.snapshot(ownerApi)
  if ownerApi == nil then return nil end
  local out = {
    recordId = readField(ownerApi, 'recordId'),
    factionId = readField(ownerApi, 'factionId'),
  }
  if out.factionId ~= nil then
    out.factionRank = readField(ownerApi, 'factionRank')
  end
  return next(out) and out or nil
end

function M.apply(ref, owner)
  local ownerApi = ref and ref.owner or nil
  if ownerApi == nil then
    return false, 'missing owner API'
  end
  if owner == nil or owner.clear == true then
    local ok, err = trySetField(ownerApi, 'recordId', nil)
    if not ok then return false, err end
    ok, err = trySetField(ownerApi, 'factionId', nil)
    if not ok then return false, err end
    -- OpenMW exposes no Lua clear for factionRank; without factionId it is ignored.
    return true
  end
  if owner.recordId ~= nil then
    local ok, err = trySetField(ownerApi, 'recordId', owner.recordId)
    if not ok then return false, err end
  end
  if owner.factionId ~= nil then
    local ok, err = trySetField(ownerApi, 'factionId', owner.factionId)
    if not ok then return false, err end
  end
  if owner.factionRank ~= nil then
    local ok, err = trySetField(ownerApi, 'factionRank', owner.factionRank)
    if not ok then return false, err end
  end
  return true
end

return M
