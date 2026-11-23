-- Bounded LOAD lifecycle status GMST codec. Carries startup outcome, hashes,
-- counts, and the compact 2-bit-per-candidate decision vector for GLOBAL.
local M = {KEY = 'sMOMLoadStatus', VERSION = 2}
local canonical = require('scripts.mom.contracts.canonical')
local MAGIC = 'MOMLOAD2'
local STATES = {preparing = true, ready = true, failed = true}
local OUTCOMES = {noop = true, committed = true, rejected = true,
  restored_failure = true, partial = true}
local COUNT_FIELDS = {'changedCount', 'noopCount', 'createdCount', 'attemptedWrites'}
local MAX_ENCODED_LEN = 4096

local function integer(value)
  return type(value) == 'number' and value >= 0 and value <= 9007199254740991 and value % 1 == 0
end
local function message(value) return tostring(value or ''):gsub('[|%z\1-\31]', ' '):sub(1, 2048) end
local function hash(value) return value == nil or canonical.hashBody(value) ~= nil end
local function validDecisions(value)
  if value == nil or value == '' then return true end
  if type(value) ~= 'string' or #value > 1536 then return false end
  local countText, hex = value:match('^(%d+):([0-9a-f]+)$')
  local count = tonumber(countText)
  return count ~= nil and count >= 1 and count % 1 == 0 and #hex == math.ceil(count / 2)
end

function M.encode(value)
  if type(value) ~= 'table' or value.version ~= M.VERSION or not STATES[value.status]
      or not hash(value.sourceHash) or not validDecisions(value.decisions) then
    return nil, 'invalid LOAD status'
  end
  local content = value.content or {}
  if type(content) ~= 'table' or not hash(content.contentHash)
      or (content.status ~= nil and not OUTCOMES[content.status]) then
    return nil, 'invalid LOAD content status'
  end
  if value.status == 'ready' and (value.sourceHash == nil or content.contentHash == nil
      or (content.status ~= 'noop' and content.status ~= 'committed')) then
    return nil, 'incomplete successful LOAD status'
  end
  if value.status == 'preparing' and (value.sourceHash ~= nil or content.status ~= nil
      or content.contentHash ~= nil or (value.decisions ~= nil and value.decisions ~= '')) then
    return nil, 'preparing LOAD status contains execution facts'
  end
  if value.status == 'failed' and (content.status == 'noop' or content.status == 'committed') then
    return nil, 'failed LOAD status contains successful content outcome'
  end
  local decisionsField = (value.decisions ~= nil and value.decisions ~= '') and value.decisions or '-'
  local fields = {
    MAGIC, value.status, value.sourceHash or '-', content.status or '-',
    content.contentHash or '-',
  }
  for _, key in ipairs(COUNT_FIELDS) do
    local count = content[key] or 0
    if not integer(count) then return nil, 'invalid LOAD count ' .. key end
    fields[#fields + 1] = string.format('%.0f', count)
  end
  if value.status == 'ready' and ((content.createdCount or 0) > (content.changedCount or 0)
      or (content.attemptedWrites or 0) ~= (content.changedCount or 0)
      or (content.status == 'noop') ~= ((content.changedCount or 0) == 0)
      or message(value.message) ~= '') then
    return nil, 'successful LOAD outcome is inconsistent'
  end
  fields[#fields + 1] = decisionsField
  fields[#fields + 1] = message(value.message)
  local encoded = table.concat(fields, '|')
  if #encoded > MAX_ENCODED_LEN then return nil, 'LOAD status exceeds bounded GMST length' end
  return encoded
end

function M.decode(encoded)
  if type(encoded) ~= 'string' or #encoded > MAX_ENCODED_LEN then
    return nil, 'LOAD status is missing or malformed'
  end
  local fields = {}
  for field in (encoded .. '|'):gmatch('(.-)|') do fields[#fields + 1] = field end
  if #fields ~= 11 or fields[1] ~= MAGIC then
    return nil, 'LOAD status format is incompatible'
  end
  local value = {
    version = M.VERSION,
    status = fields[2],
    sourceHash = fields[3] ~= '-' and fields[3] or nil,
    content = {
      status = fields[4] ~= '-' and fields[4] or nil,
      contentHash = fields[5] ~= '-' and fields[5] or nil,
    },
    decisions = fields[10] ~= '-' and fields[10] or '',
    message = fields[11],
  }
  for index, key in ipairs(COUNT_FIELDS) do
    value.content[key] = tonumber(fields[index + 5])
    if not integer(value.content[key]) then return nil, 'invalid LOAD count ' .. key end
  end
  local roundtrip, err = M.encode(value)
  if not roundtrip or roundtrip ~= encoded then
    return nil, err or 'LOAD status is not canonical'
  end
  return value
end

function M.read(getGMST)
  getGMST = getGMST or require('openmw.core').getGMST
  local ok, raw = pcall(getGMST, M.KEY)
  if not ok then return nil, 'cannot read LOAD status: ' .. tostring(raw) end
  return M.decode(raw)
end

function M.writer(records)
  local function write(value)
    local encoded, err = M.encode(value)
    if not encoded then return nil, err end
    local ok, failure = pcall(function() records[M.KEY] = encoded end)
    if not ok then return nil, 'cannot publish LOAD status: ' .. tostring(failure) end
    return value
  end
  return {
    prepare = function()
      local ok, existing = pcall(function() return records[M.KEY] end)
      if not ok then return nil, 'cannot inspect LOAD status namespace' end
      if existing ~= nil and M.decode(existing) == nil then
        return nil, 'LOAD status namespace collision'
      end
      return write({version = M.VERSION, status = 'preparing'})
    end,
    publish = write,
  }
end

return M
