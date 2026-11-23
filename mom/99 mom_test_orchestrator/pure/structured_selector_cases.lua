local support = require('pure.test_support')
local expect = support.expect
local query = require('scripts.mom.contracts.ref_selector')
local canonical = require('scripts.mom.contracts.canonical')
local identity = require('scripts.mom.contracts.plan_identity')
local resolver = require('scripts.mom.compiler.variant_resolver')
local lowering = require('scripts.mom.compiler.source_lowering')
local manifest = require('scripts.mom.compiler.compile_manifest')
local registry = require('scripts.mom.compiler.extension_registry')
local record_queries = require('pure.cases.record_queries')

local function catalog()
  local entries = {}
  for _, id in ipairs({'modify_ref', 'modify_inventory', 'kill_actor', 'place_ref'}) do
    entries[#entries + 1] = {path = 'scripts/mom/actions/' .. id .. '.lua',
      module = require('scripts.mom.actions.' .. id)}
  end
  return {kind = 'mom-extension-catalog',
    actions = assert(registry.build('action', entries, {requireProgramVersion = true})),
    guards = assert(registry.build('guard', {}, {})),
    compat = assert(registry.build('compat', {}, {}))}
end

local function context(records)
  records = records or {rat = {type = 'Creature'}, crate = {type = 'Container'},
    gold_001 = {type = 'Miscellaneous'}, urn = {type = 'Static', mwscript = 'example'}}
  local refRecords = {
    recordExists = function(id, types)
      local record = records[id]
      if record == nil then return false, 'invalid_record_id' end
      if types and not types[record.type] then return false, 'wrong_record_type', record.type end
      return true, nil, record.type
    end,
    resolveLiveRefType = function(id)
      local record = records[id]
      return record and record.type or nil, record == nil and 'invalid_record_id' or nil
    end,
    resolveRecordQuery = function(selector)
      local out = {}
      for id, record in pairs(records) do
        if query.matchesRecord(selector, id, record.type, record.mwscript) then
          out[#out + 1] = {typeName = record.type, recordId = id}
        end
      end
      table.sort(out, function(a, b) return a.typeName .. a.recordId < b.typeName .. b.recordId end)
      return out
    end,
  }
  local entry = {key = 'room', id = 'Room', idLower = 'room', name = 'Room', nameLower = 'room',
    displayName = 'Room', displayNameLower = 'room', interiorKey = 'room', isExterior = false}
  return {recordCtx = refRecords, cellIndex = {
    entries = {entry}, byKey = {room = entry}, byId = {room = {entry}},
    byName = {room = {entry}}, byDisplayName = {room = {entry}},
    byExteriorWorldspace = {}, byRegion = {}, byWorldspace = {},
  }, modelExists = function() return true end}
end

local function compile(actions, records, opts)
  local config = {version = 0, variants = {fixture = {actions = actions}}}
  local resolved, resolveError = resolver.resolve(config, {activeContent = {}, sourcePath = 'query.yaml'})
  if resolved == nil then return nil, {resolveError.message} end
  local extensions, ctx = catalog(), context(records)
  if opts then ctx.contentFileActive = opts.contentFileActive end
  local prepared, _, prepareErrors = lowering.prepareActions(resolved.actions, extensions)
  if prepared == nil then return nil, prepareErrors end
  local normalized, lowerErrors = lowering.lowerActions(prepared, ctx, extensions)
  if normalized == nil then return nil, lowerErrors end
  return manifest.compileOwned(normalized, ctx, extensions)
end
local function compiled(actions, records, opts)
  local result, errors = compile(actions, records, opts)
  expect(result ~= nil, 'structured selector failed: ' .. table.concat(errors or {}, ' | '))
  return result
end
local function onlyAction(result)
  expect(#result.actionIds == 1, 'expected one action')
  return result.actionsById[result.actionIds[1]]
end

local function normalizedQueryAndInvalidForms()
  local one = assert(query.normalize({type = {'creature', 'Creature'}, ref = {'Morrowind.ESM', {9, 2, 9}},
    recordId = {match = {'*RAT*', '*rat*'}}}))
  expect(one.type[1] == 'Creature' and #one.type == 1 and one.ref.file == 'morrowind.esm'
      and canonical.encode(one.ref.numbers) == canonical.encode({2, 9})
      and #one.matches[1] == 1, 'query alternatives are not normalized sets')
  for _, value in ipairs({{ref = {'a', -1}}, {ref = {'a', 1.5}}, {ref = {'a', 0x1000000}},
      {ref = {'a', '0x10'}}, {ref = {'a', {}}}, {type = {}}, {type = 'Bogus'},
      {recordId = {match = 'a*b'}}, {recordId = {luaPattern = 'rat'}}, {query = {}},
      {ref = {'a', 1}, contentFile = 'b'}}) do
    local normalized = query.normalize(value)
    expect(normalized == nil, 'invalid selector normalized successfully')
  end
  local invalid = compile({{select = {query = {type = {'Creature'}}}, modify = {scale = 1.2}}})
  expect(invalid == nil, 'author spoofed compiler-owned query input')
end

local function fullAndDirectFormsShareMeaning()
  local selector = {ref = {'Morrowind.esm', 67647}, type = 'NPC'}
  local full = onlyAction(compiled({{modify = {{'*', selector, {scale = 0.1}}}}}))
  local direct = onlyAction(compiled({{select = {cell = '*', ref = {'MORROWIND.ESM', {67647}}, type = {'npc'}},
    modify = {scale = 0.1}}}))
  expect(full.id == direct.id and full.program.basePatch.scale.value == 0.1,
    'equivalent tuple/direct content ref forms have different semantic IDs')
  local noCell = onlyAction(compiled({{select = selector, modify = {scale = 0.1}}}))
  expect(noCell.selection.cell == nil and noCell.selection.query.ref.numbers[1] == 67647,
    'exact reference unexpectedly requires an origin cell')
  local wrongKill = compile({{select = {cell = '*', type = 'Static'}, kill = {}}})
  expect(wrongKill == nil, 'kill accepted explicitly non-actor candidates')
end

local function inventoryOwnerFormsAndQueries()
  local selector = {ref = {'Morrowind.esm', 1}, type = 'Container'}
  local tuples = onlyAction(compiled({{inventory = {{'Room', selector, {gold_001 = {'add', 2}}}}}}))
  local owners = onlyAction(compiled({{inventory = {owners = {{'Room', selector}},
    items = {gold_001 = {'add', 2}}}}}))
  local direct = onlyAction(compiled({{select = {cell = 'Room', ref = {'Morrowind.esm', 1}, type = 'Container'},
    inventory = {gold_001 = {'add', 2}}}}))
  expect(tuples.id == owners.id and owners.id == direct.id,
    'inventory owner tuple/direct/shared-items query forms differ')
end

local function recordCatalogMembershipDoesNotResetIdentity()
  local action = {modify = {{'*', {recordId = {match = '*glass*'}}, {scale = 0.8}}}}
  local first = onlyAction(compiled({action}, {glass_weapon = {type = 'Weapon'}}))
  local second = onlyAction(compiled({action}, {glass_weapon = {type = 'Weapon'}, glass_armor = {type = 'Armor'}}))
  expect(first.id == second.id and first.specificity == second.specificity
      and #first.selection.queryRecords == 1 and #second.selection.queryRecords == 2,
    'another matching record/type changed old action identity or failed to join execution cache')
  expect(query.matchesRecord(first.selection.query, 'glass_weapon', 'Weapon')
      and not query.matchesRecord(first.selection.query, 'iron_weapon', 'Weapon'),
    'record query matcher did not filter matching and unrelated records')
  local script = onlyAction(compiled({{modify = {{'*', {type = 'Static', mwscript = 'EXAMPLE'}, {scale = 0.8}}}}}))
  expect(#script.selection.queryRecords == 1 and script.selection.queryRecords[1].recordId == 'urn',
    'MWScript query failed to resolve record catalog')
end

local function exactRefsUseDirectLookup()
  local action = onlyAction(compiled({{select = {ref = {'Morrowind.esm', 1}}, modify = {enabled = false}}}))
  expect(action.selection.query.ref.file == 'morrowind.esm'
      and action.selection.query.ref.numbers[1] == 1,
    'exact ref query lost canonical content file or ref number')
  expect(query.matchesReference(action.selection.query, 'content:000001:morrowind.esm')
      and not query.matchesReference(action.selection.query, 'content:000002:morrowind.esm'),
    'exact ref matcher accepted wrong objectId or rejected matching objectId')
end

local function absentContentFilesSkipWithoutWidening()
  local absent = {contentFileActive = function() return false end}
  local byFile = compiled({{modify = {{'*', {type = 'Static', contentFile = {'Missing.esp', 'Other.esp'}}, {scale = 0.8}}}}}, nil, absent)
  local byRef = compiled({{modify = {{'*', {ref = {'Missing.esp', 1}}, {scale = 0.8}}}}}, nil, absent)
  expect(#byFile.actionIds == 0 and #byRef.actionIds == 0,
    'known absent provenance/reference query fell back to a broad selection')
  local actions = {{modify = {{'*', {type = 'Static', contentFile = {'Present.esp', 'Future.esp'}}, {scale = 0.8}}}}}
  local first = onlyAction(compiled(actions, nil, {contentFileActive = function(name) return name == 'present.esp' end}))
  local second = onlyAction(compiled(actions, nil, {contentFileActive = function() return true end}))
  expect(first.id == second.id and #first.selection.query.contentFile == 2,
    'content file availability changed authored query identity')
end

local function originIntersectionChildrenAndRelocation()
  local moved = onlyAction(compiled({{modify = {{'*', {ref = {'Morrowind.esm', 1}},
    {relocate = {cell = 'Room', position = {4, 5, 6}}}}}}}))
  expect(moved.program.basePatch.relocate.cell.key == 'room', 'exact ref relocation did not compile')
  local full = compiled({{place = {{'Room', 'urn', {1, 2, 3}, {}}}, actions = {
    {modify = {{{exact = 'Room'}, {type = 'Static'}, {scale = 0.8}}}},
    {attach = {{'Room', {recordId = 'urn', type = 'Static'}, 'urn', {0, 0, 2}}}},
  }}})
  expect(#full.actionIds == 3, 'full child rows with structured cell/target were misclassified')
  local bad = compile({{attach = {{'Room', {type = 'Static'}, 'urn'}}}})
  expect(bad == nil, 'attach accepted an unproven source record envelope')
  local constrained = onlyAction(compiled({{select = {cell = 'Room', type = 'Container'},
    modify = {{'*', {ref = {'Morrowind.esm', 1}}, {enabled = false}}}}}))
  expect(#constrained.selection.additionalCells == 1,
    'row query silently overwrote the action origin-cell restriction')
end

return {run = function()
  return support.runCases('structured selectors', {
    {'record query specialization matches complete catalog scans', record_queries.narrowQueriesMatchFullScanSemantics},
    {'record queries touch only required stores and IDs', record_queries.exactAndTypedQueriesAvoidUnrelatedStores},
    {'record query caches are invocation-local', record_queries.freshCompilationSeesFinalCatalogChanges},
    {'canonical queries and invalid forms', normalizedQueryAndInvalidForms},
    {'tuple and direct query equivalence', fullAndDirectFormsShareMeaning},
    {'structured inventory owner forms', inventoryOwnerFormsAndQueries},
    {'stable identity with changing actual catalog membership', recordCatalogMembershipDoesNotResetIdentity},
    {'direct reference query matching', exactRefsUseDirectLookup},
    {'known absent content files skip without broadening', absentContentFilesSkipWithoutWidening},
    {'origin intersection, full child rows and relocation', originIntersectionChildrenAndRelocation},
  })
end}
