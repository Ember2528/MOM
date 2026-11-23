local selector = require('scripts.mom.contracts.ref_selector')
local canonical = require('scripts.mom.contracts.canonical')
local ref_type = require('scripts.mom.contracts.ref_type')
local expect = require('pure.test_support').expect
local M = {}

local function withCatalog(callback)
  package.preload['openmw.types'] = package.preload['openmw.types'] or function() return {} end
  local types = require('openmw.types')
  local records_api = require('scripts.mom.compiler.record_index')
  local previous, values, counts = {}, {}, {}
  for _, name in ipairs(ref_type.names()) do
    previous[name] = types[name]
    counts[name] = {id = 0, script = 0, lookup = 0}
    local count = counts[name]
    local data = {
      {id = 'shared', mwscript = 'common_script'},
      {id = name:lower() .. '_one', mwscript = 'special_script'},
      {id = name:lower() .. '_two'},
    }
    values[name] = data
    local records, byId = {}, {}
    for i, raw in ipairs(data) do
      local record = setmetatable({}, {__index = function(_, field)
        if field == 'id' then count.id = count.id + 1 end
        if field == 'mwscript' then count.script = count.script + 1 end
        return raw[field]
      end})
      records[i], byId[raw.id] = record, record
    end
    setmetatable(records, {__index = function(_, id)
      count.lookup = count.lookup + 1
      return byId[id]
    end})
    types[name] = {records = records}
  end
  local ok, err = pcall(callback, records_api, values, counts, types)
  for _, name in ipairs(ref_type.names()) do types[name] = previous[name] end
  if not ok then error(err, 0) end
end

local function fullScan(values, query)
  local out = {}
  for _, typeName in ipairs(ref_type.names()) do
    for _, record in ipairs(values[typeName]) do
      if selector.matchesRecord(query, record.id, typeName, record.mwscript) then
        out[#out + 1] = {typeName = typeName, recordId = record.id}
      end
    end
  end
  table.sort(out, function(a, b)
    return a.typeName < b.typeName or (a.typeName == b.typeName and a.recordId < b.recordId)
  end)
  return out
end

function M.narrowQueriesMatchFullScanSemantics()
  withCatalog(function(api, values)
    local queries = {
      {}, {type = 'Static'}, {type = {'Static', 'Book'}},
      {recordId = {'shared', 'static_one', 'book_one', 'missing'}},
      {type = {'Static', 'Book'}, recordId = {'shared', 'static_two'}},
      {type = 'Book', recordId = {match = '*_one'}},
      {recordId = {match = {'*one', '*two'}}, mwscript = 'special_script'},
      {recordId = {'shared', 'book_two'}, mwscript = 'common_script'},
      {type = 'Static', contentFile = 'morrowind.esm'},
    }
    local context = api.build()
    for _, raw in ipairs(queries) do
      local query = next(raw) == nil and {} or assert(selector.normalize(raw))
      local actual = context.resolveRecordQuery(query)
      expect(canonical.encode(actual) == canonical.encode(fullScan(values, query)),
        'narrow record lookup changed matches, ambiguous record IDs, or canonical order')
    end
    local none = selector.intersect(assert(selector.normalize({type = 'Static'})),
      assert(selector.normalize({type = 'Book'})))
    expect(#context.resolveRecordQuery(none) == 0, 'empty type intersection scanned or selected records')
  end)
end

function M.exactAndTypedQueriesAvoidUnrelatedStores()
  withCatalog(function(api, _, counts)
    local context = api.build()
    local exact = assert(selector.normalize({type = 'Static', recordId = {'shared', 'missing'}}))
    local first = context.resolveRecordQuery(exact)
    expect(#first == 1 and first[1].recordId == 'shared'
        and counts.Static.id == 1 and counts.Static.lookup == 2 and counts.Static.script == 0,
      'typed exact query scanned records or read unused script fields')
    for name, count in pairs(counts) do
      if name ~= 'Static' then
        expect(count.id == 0 and count.lookup == 0 and count.script == 0,
          'typed exact query touched an unrelated record store')
      end
    end
    expect(context.resolveRecordQuery(exact) == first and counts.Static.lookup == 2,
      'repeated canonical record query bypassed the invocation cache')
    local pattern = assert(selector.normalize({type = 'Book', recordId = {match = '*one'}}))
    expect(#context.resolveRecordQuery(pattern) == 1
        and counts.Book.id == 3 and counts.Book.script == 0 and counts.Book.lookup == 0,
      'typed pattern query failed to restrict its numeric catalog traversal')
    local none = selector.intersect(assert(selector.normalize({type = 'NPC'})),
      assert(selector.normalize({type = 'Door'})))
    expect(#context.resolveRecordQuery(none) == 0 and counts.NPC.id == 0 and counts.Door.id == 0,
      'known-empty query touched record catalogs')
  end)
end

function M.freshCompilationSeesFinalCatalogChanges()
  withCatalog(function(api, _, _, types)
    local query = assert(selector.normalize({type = 'Static', recordId = 'created_in_load'}))
    local previous = api.build()
    expect(#previous.resolveRecordQuery(query) == 0, 'missing record was unexpectedly present')
    local record = {id = 'created_in_load'}
    types.Static.records.created_in_load = record
    types.Static.records[#types.Static.records + 1] = record
    local current = api.build()
    local found = current.resolveRecordQuery(query)
    expect(#found == 1 and found[1].recordId == 'created_in_load'
        and #previous.resolveRecordQuery(query) == 0,
      'record-query cache escaped a compiler invocation or ignored final content')
  end)
end

return M
