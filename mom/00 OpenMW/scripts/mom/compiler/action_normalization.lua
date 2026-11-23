-- Engine-free canonical meaning shared by every source frontend. Context
-- placement happens only after this normalization; no records or cells are read.
local M = {}
local plain = require('scripts.mom.contracts.plain_data')
local refs = require('scripts.mom.contracts.ref_selector')
local tables = require('scripts.mom.common.tables')
local choices = require('scripts.mom.contracts.replacement_choice')
local tuple = require('scripts.mom.compiler.tuple_contract')
local function scalar(values)
  if type(values) == 'table' and #values == 1 then return values[1] end
  return values
end
local function cell(value)
  if type(value) ~= 'table' then return value end
  local onlyMatch = true
  for key in pairs(value) do if key ~= 'match' then onlyMatch = false end end
  if onlyMatch and (next(value) == nil or value.match == '*'
      or (tables.isArray(value.match) and #value.match == 1 and value.match[1] == '*')) then return '*' end
  return value
end
local function selector(raw, path)
  if not tables.isObject(raw) then return raw end
  local query, err = refs.normalize(raw, path)
  if not query then return nil, err end
  local out = {}
  for _, field in ipairs({'type', 'contentFile', 'mwscript', 'recordId'}) do
    if query[field] then out[field] = scalar(query[field]) end
  end
  if query.matches then out.recordId = {match = scalar(query.matches[1])} end
  if query.ref then out.ref = {query.ref.file, scalar(query.ref.numbers)} end
  return out
end
local function filters(raw, path)
  if raw == nil then return nil end
  local _, err = tuple.compileFilters(raw, path)
  if err then return nil, err end
  local list = type(raw[1]) == 'string' and {raw} or raw
  for _, predicate in ipairs(list) do predicate[1] = predicate[1]:lower() end
  return list
end
local function placementTarget(raw, path)
  if tables.isObject(raw) then
    for key in pairs(raw) do
      if key ~= 'recordId' then return nil, path .. ': absolute choices require record-ID targets' end
    end
    raw = raw.recordId
  end
  if type(raw) ~= 'string' or raw == '' then return nil, path .. ': expected placed record id' end
  return raw:lower()
end
local function placementChoice(raw, path)
  if not tables.isArray(raw.choose) or #raw.choose == 0 then
    return nil, path .. '.choose: expected non-empty target/weight tuples'
  end
  for index, entry in ipairs(raw.choose) do
    local at = path .. '.choose[' .. tostring(index) .. ']'
    if not tables.isArray(entry) or #entry ~= 2 then return nil, at .. ': expected [record, weight]' end
    local normalized, err = placementTarget(entry[1], at .. '[1]')
    if not normalized then return nil, err end
    entry[1] = normalized
  end
  return raw
end
function M.spec(raw, path, opts)
  path, opts = path or 'action', opts or {}
  local spec, errors = plain.detach(raw, {path = path})
  if not spec then return nil, table.concat(errors or {}, ' | ') end
  if not tables.isObject(spec) then return nil, path .. ': expected action object' end
  if spec.select ~= nil then
    if not tables.isObject(spec.select) then return nil, path .. '.select: expected object' end
    local fields = {}
    for key, value in pairs(spec.select) do if key ~= 'cell' then fields[key] = value end end
    local normalized
    if next(fields) then
      normalized, errors = selector(fields, path .. '.select')
      if not normalized then return nil, errors end
    else normalized = {} end
    if spec.select.cell ~= nil then normalized.cell = cell(spec.select.cell) end
    spec.select = normalized
  end
  if spec.filters ~= nil then
    local normalized, err = filters(spec.filters, path .. '.filters')
    if not normalized then return nil, err end
    spec.filters = normalized
  end
  for _, verb in ipairs({'attach', 'modify', 'inventory', 'kill', 'place'}) do
    local rows = spec[verb]
    if tables.isArray(rows) and #rows > 0 then
      for index, row in ipairs(rows) do
        if type(row) == 'table' then
          local at = path .. '.' .. verb .. '[' .. tostring(index) .. ']'
          local compact = tuple.isChildCompactTuple(row, verb, opts)
          if not compact then
            row[1] = cell(row[1])
            if verb ~= 'place' and tables.isObject(row[2]) then
              local normalized, err = selector(row[2], at .. '[2]')
              if not normalized then return nil, err end
              row[2] = normalized
            end
          end
          local targetIndex = verb == 'attach' and (compact and 1 or 3) or nil
          if targetIndex and type(row[targetIndex]) == 'table' then
            local normalized, err = choices.normalize(row[targetIndex], at .. '[' .. targetIndex .. ']')
            if not normalized then return nil, err end
            row[targetIndex] = normalized
          end
          if verb == 'place' and row[2] ~= nil then
            local normalized, err
            if type(row[2]) == 'table' then normalized, err = placementChoice(row[2], at .. '[2]')
            else normalized, err = placementTarget(row[2], at .. '[2]') end
            if not normalized then return nil, err end
            row[2] = normalized
          end
          local start = tuple.predicateStart(row, verb, opts)
          for i = start, #row do
            if type(row[i]) == 'table' and type(row[i][1]) == 'string' then row[i][1] = row[i][1]:lower() end
          end
        end
      end
    end
  end
  for index, child in ipairs(spec.actions or {}) do
    local normalized, err = M.spec(child, path .. '.actions[' .. tostring(index) .. ']', {isChild = true})
    if not normalized then return nil, err end
    spec.actions[index] = normalized
  end
  return spec
end
return M
