-- Canonical authored reference queries. Execution catalog caches are deliberately
-- not part of this value: installing another matching record must not reroll
-- or repeat an unchanged action against its existing targets.
local M = {}
local ref_type = require('scripts.mom.contracts.ref_type')
local canonical = require('scripts.mom.contracts.canonical')
local FIELDS = {ref = true, contentFile = true, type = true, recordId = true, mwscript = true}
local TYPES = {}
for _, name in ipairs(ref_type.names()) do TYPES[name:lower()] = name end

local function array(value, path)
  if type(value) ~= 'table' or #value == 0 then return nil, path .. ': expected non-empty array' end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > #value then
      return nil, path .. ': expected dense array'
    end
    count = count + 1
  end
  if count ~= #value then return nil, path .. ': expected dense array' end
  return value
end
local function strings(raw, path, types)
  if type(raw) == 'string' then raw = {raw} end
  local values, err = array(raw, path)
  if not values then return nil, err end
  local out, seen = {}, {}
  for i, value in ipairs(values) do
    if type(value) ~= 'string' or value == '' then return nil, path .. '[' .. i .. ']: expected non-empty string' end
    value = value:lower()
    if types then
      value = TYPES[value]
      if value == nil then return nil, path .. '[' .. i .. ']: unsupported reference type' end
    end
    if not seen[value] then out[#out + 1], seen[value] = value, true end
  end
  table.sort(out)
  return out
end
local function contains(values, value)
  for _, item in ipairs(values or {}) do if item == value then return true end end
  return false
end
local function intersection(left, right)
  if left == nil then return right end
  if right == nil then return left end
  local out = {}
  for _, item in ipairs(left) do if contains(right, item) then out[#out + 1] = item end end
  return out
end

function M.isObject(value)
  return type(value) == 'table' and value[1] == nil
end
function M.isExtended(select)
  if type(select) ~= 'table' then return false end
  return select.query ~= nil or select.ref ~= nil or select.contentFile ~= nil
    or select.type ~= nil or select.mwscript ~= nil
    or (type(select.recordId) == 'table' and select.recordId.match ~= nil)
end

function M.normalize(raw, path)
  path = path or 'selector'
  if not M.isObject(raw) or next(raw) == nil then return nil, path .. ': expected non-empty selector object' end
  for key in pairs(raw) do if not FIELDS[key] then return nil, path .. '.' .. tostring(key) .. ': is not allowed' end end
  local query = {}
  for _, field in ipairs({'contentFile', 'type', 'mwscript'}) do
    if raw[field] ~= nil then
      local values, err = strings(raw[field], path .. '.' .. field, field == 'type')
      if not values then return nil, err end
      query[field] = values
    end
  end
  if raw.recordId ~= nil then
    if M.isObject(raw.recordId) then
      for key in pairs(raw.recordId) do
        if key ~= 'match' then return nil, path .. '.recordId.' .. tostring(key) .. ': is not allowed; use match' end
      end
      local patterns, err = strings(raw.recordId.match, path .. '.recordId.match')
      if not patterns then return nil, err end
      for _, pattern in ipairs(patterns) do
        local middle = pattern:gsub('^%*', ''):gsub('%*$', '')
        if middle:find('*', 1, true) then
          return nil, path .. '.recordId.match: only leading/trailing * are supported'
        end
      end
      query.matches = {patterns}
    else
      local ids, err = strings(raw.recordId, path .. '.recordId')
      if not ids then return nil, err end
      query.recordId = ids
    end
  end
  if raw.ref ~= nil then
    local pair, err = array(raw.ref, path .. '.ref')
    if not pair or #pair ~= 2 then return nil, err or path .. '.ref: expected [content filename, number or number array]' end
    if type(pair[1]) ~= 'string' or pair[1] == '' then return nil, path .. '.ref[1]: expected content filename' end
    local numbers = pair[2]
    if type(numbers) == 'number' then numbers = {numbers} end
    numbers, err = array(numbers, path .. '.ref[2]')
    if not numbers then return nil, err end
    local out, seen = {}, {}
    for i, value in ipairs(numbers) do
      if type(value) ~= 'number' or value % 1 ~= 0 or value < 0 or value > 0xffffff then
        return nil, path .. '.ref[2][' .. i .. ']: expected integer from 0 through 16777215'
      end
      if not seen[value] then out[#out + 1], seen[value] = value, true end
    end
    table.sort(out)
    query.ref = {file = pair[1]:lower(), numbers = out}
    if query.contentFile and not contains(query.contentFile, query.ref.file) then
      return nil, path .. ': ref and contentFile restrictions disagree'
    end
  end
  return query
end

function M.intersect(left, right)
  if left == nil then return right end
  if right == nil then return left end
  local query = {}
  for _, field in ipairs({'contentFile', 'type', 'mwscript', 'recordId'}) do
    query[field] = intersection(left[field], right[field])
    if query[field] and #query[field] == 0 then query.none = true end
  end
  local groups, seen = {}, {}
  for _, value in ipairs({left, right}) do
    for _, group in ipairs(value.matches or {}) do
      local key = canonical.assertHash(group)
      if not seen[key] then groups[#groups + 1], seen[key] = group, true end
    end
  end
  if #groups > 0 then
    table.sort(groups, function(a, b) return canonical.assertHash(a) < canonical.assertHash(b) end)
    query.matches = groups
  end
  query.ref = left.ref or right.ref
  if left.ref and right.ref then
    query.ref = {file = left.ref.file, numbers = intersection(left.ref.numbers, right.ref.numbers)}
    if left.ref.file ~= right.ref.file or #query.ref.numbers == 0 then query.none = true end
  end
  if query.ref and query.contentFile and not contains(query.contentFile, query.ref.file) then query.none = true end
  if left.none or right.none then query.none = true end
  return query
end

function M.lowerSelect(select, path)
  if not M.isExtended(select) then return select end
  if select.query ~= nil then return select end -- Compiler-owned normalized input.
  local raw = {}
  for key, value in pairs(select) do if key ~= 'cell' then raw[key] = value end end
  local query, err = M.normalize(raw, path)
  if not query then return nil, err end
  return {cell = select.cell, query = query}
end

function M.matchString(value, pattern)
  value = value and tostring(value):lower() or ''
  local first, last = pattern:sub(1, 1) == '*', pattern:sub(-1) == '*'
  local needle = pattern:gsub('^%*', ''):gsub('%*$', '')
  if first and last then return value:find(needle, 1, true) ~= nil end
  if first then return needle == '' or value:sub(-#needle) == needle end
  if last then return value:sub(1, #needle) == needle end
  return value == needle
end
function M.matchesRecord(query, recordId, typeName, mwscript)
  if query.none then return false end
  recordId = tostring(recordId):lower()
  if query.type and not contains(query.type, typeName) then return false end
  if query.recordId and not contains(query.recordId, recordId) then return false end
  if query.mwscript and not contains(query.mwscript, tostring(mwscript or ''):lower()) then return false end
  for _, alternatives in ipairs(query.matches or {}) do
    local matched = false
    for _, pattern in ipairs(alternatives) do if M.matchString(recordId, pattern) then matched = true; break end end
    if not matched then return false end
  end
  return true
end
function M.matchesReference(query, objectId)
  if query.none then return false end
  local index, file = tostring(objectId or ''):match('^content:(%x%x%x%x%x%x):(.+)$')
  if query.contentFile and (file == nil or not contains(query.contentFile, file:lower())) then return false end
  if query.ref and (file == nil or file:lower() ~= query.ref.file
      or not contains(query.ref.numbers, tonumber(index, 16))) then return false end
  return true
end
return M
