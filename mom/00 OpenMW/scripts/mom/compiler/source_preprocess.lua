-- Converts one explicit source action into one or more cell-normalized source
-- records. Predicate programs are first-class fields on the records.
local M = {}

local authored_path = require('scripts.mom.compiler.authored_path')
local source_action_contract = require('scripts.mom.compiler.source_action_contract')
local source_ir = require('scripts.mom.compiler.source_ir')
local spec_key = require('scripts.mom.compiler.spec_key')
local tables = require('scripts.mom.common.tables')
local tuple_contract = require('scripts.mom.compiler.tuple_contract')
local ref_selector = require('scripts.mom.contracts.ref_selector')
local replacement_choice = require('scripts.mom.contracts.replacement_choice')
local keyed = require('scripts.mom.compiler.keyed_targets')

local compileTrailingPredicates = tuple_contract.compileTrailingPredicates
local copyObject = tables.copyObject

local function normalizeTuples(tuples, actionPath, verb, opts)
  local out = {}
  for i = 1, #tuples do
    local tuple = tuples[i]
    local path = tostring(actionPath) .. '.' .. tostring(verb) .. '[' .. tostring(i) .. ']'
    if type(tuple) ~= 'table' then return nil, path .. ': expected tuple array' end
    local argEnd = tuple_contract.argumentEnd(tuple, verb, opts)
    local predicates, err = compileTrailingPredicates(tuple, path, argEnd + 1)
    if err then return nil, err end
    local values = {}
    local first = opts.compact and 1 or 2
    for ai = first, argEnd do values[#values + 1] = tuple[ai] end
    out[i] = {values = values, predicates = predicates, sourceIndex = i,
      cell = not opts.compact and tuple[1] or nil}
  end
  return out, nil
end

local function appendPredicates(first, second)
  if first == nil and second == nil then return nil end
  local out = {}
  for i = 1, #(first or {}) do out[#out + 1] = first[i] end
  for i = 1, #(second or {}) do out[#out + 1] = second[i] end
  return #out > 0 and out or nil
end

local function filterPredicates(spec, actionPath)
  if spec.filters == nil then return nil, nil end
  return tuple_contract.compileFilters(
    spec.filters,
    tostring(actionPath) .. '.filters'
  )
end

local function cellGroupKey(cellSpec)
  if type(cellSpec) == 'string' then return cellSpec end
  return spec_key.fromSpec(cellSpec)
end

local function groupTuplesByCell(tuples)
  local order, byKey = {}, {}
  for i = 1, #tuples do
    local tuple = tuples[i]
    local cell = tuple.cell
    tuple.cell = nil
    local key = cellGroupKey(cell)
    local group = byKey[key]
    if group == nil then
      group = {cell = cell, tuples = {}}
      byKey[key] = group
      order[#order + 1] = key
    end
    group.tuples[#group.tuples + 1] = tuple
  end
  local out = {}
  for i = 1, #order do out[i] = byKey[order[i]] end
  return out
end

local function input(spec, verb, id, payload, payloadKind, cell)
  local select = copyObject(spec.select)
  if cell ~= nil then
    if select.query and select.cell ~= nil and spec_key.fromSpec(select.cell) ~= spec_key.fromSpec(cell) then
      select.cellConstraints = {select.cell}
    end
    select.cell = cell
  end
  local options = nil
  for key, value in pairs(spec) do
    if key ~= verb and key ~= 'id' and key ~= 'select' and key ~= 'chance'
        and key ~= 'previsit' and key ~= 'filters' and key ~= 'actions'
        and key ~= 'key' and key ~= 'admission' and key ~= 'requires'
        and key ~= 'requiresAny' and key ~= 'requiresNot' then
      options = options or {}
      options[key] = value
    end
  end
  if spec.key ~= nil then options = options or {}; options.instanceKey = spec.key end
  return {
    id = id, verb = verb, payload = payload, payloadKind = payloadKind,
    select = (spec.select ~= nil or cell ~= nil) and select or nil,
    chance = spec.chance, previsit = spec.previsit,
    options = options,
  }
end

local DEFAULT_CHOICE_TYPES = {'Static', 'Activator', 'Container'}
local function asSet(raw)
  if type(raw) == 'string' then raw = {raw} end
  if raw == nil then return nil end
  local out = {}; for _, name in ipairs(raw) do out[name] = true end
  return out
end
local function intersectTypes(left, right)
  if left == nil then return right end
  if right == nil then return left end
  local out = {}; for name in pairs(left) do if right[name] then out[name] = true end end
  return out
end
local function hasChoice(spec)
  for _, row in ipairs(spec.attach or {}) do if replacement_choice.isExpression(row[3]) then return true end end
  return false
end
local function choiceRows(sourceAction, spec, tuples, filters, actionPath, opts)
  if opts.isChild then return nil, actionPath .. ': replacement choices require explicit root attachment sources' end
  if spec.disableOriginal ~= true then return nil, actionPath .. ': replacement choices require disableOriginal: true' end
  if spec.select and spec.select.recordId ~= nil then
    local query, err = ref_selector.normalize({recordId = spec.select.recordId}, actionPath .. '.select')
    if not query then return nil, err end
    spec = copyObject(spec)
    spec.select = copyObject(spec.select)
    spec.select.query = ref_selector.intersect(spec.select.query, query)
    spec.select.recordId = nil
  end
  local groups = groupTuplesByCell(tuples)
  local out = {}
  local outerQuery = spec.select and spec.select.query or nil
  local outerTypes = asSet(outerQuery and outerQuery.type or spec.select and spec.select.type)
  for gi, group in ipairs(groups) do
    local rules = {}
    for _, row in ipairs(group.tuples) do
      local at = actionPath .. '.attach[' .. tostring(row.sourceIndex) .. ']'
      local source, ownTypes, parsed = row.values[1], nil, nil
      if ref_selector.isObject(source) then
        local query, err = ref_selector.normalize(source, at .. '[2]')
        if not query then return nil, err end
        if not query.recordId or #query.recordId ~= 1 or query.matches or query.ref or query.contentFile or query.mwscript then
          return nil, at .. '[2]: choice sources require one exact recordId and optional type'
        end
        ownTypes = asSet(query.type)
        parsed = {sourceKeyKind = 'record_id', sourceValue = query.recordId[1]}
      else
        local err; parsed, err = keyed.parseSelectorKey(source)
        if not parsed then return nil, at .. '[2]: ' .. tostring(err) end
      end
      if parsed.sourcePosition then return nil, at .. ': choice sources cannot have position keys' end
      if row.values[3] ~= nil then
        local offset = row.values[3]
        if not tables.isArray(offset) or #offset ~= 3 or offset[1] ~= 0 or offset[2] ~= 0 or offset[3] ~= 0 then
          return nil, at .. ': choice attachments support only an omitted or zero offset'
        end
      end
      if row.values[4] ~= nil then return nil, at .. ': choice attachments cannot override rotation' end
      local descriptor, err
      if replacement_choice.isExpression(row.values[2]) then descriptor, err = replacement_choice.descriptor(row.values[2], at .. '[3]')
      else descriptor, err = replacement_choice.descriptor({choose = {{row.values[2], 1}}}, at .. '[3]') end
      if not descriptor then return nil, err end
      local ignored = {}
      for _, predicate in ipairs(row.predicates or {}) do
        if predicate.kind ~= 'record_id_exclude' then
          return nil, at .. ': choice tuple predicates must be record exclusions'
        end
        for id in pairs(predicate.excludedIds or {}) do ignored[id] = true end
      end
      for _, predicate in ipairs(filters or {}) do
        for id in pairs(predicate.excludedIds or {}) do ignored[id] = true end
      end
      local types = intersectTypes(outerTypes, ownTypes) or asSet(DEFAULT_CHOICE_TYPES)
      if next(types) == nil then return nil, at .. ': choice source type restrictions have an empty intersection' end
      rules[#rules + 1] = {sourceKey = parsed.sourceValue, sourceKind = parsed.sourceKeyKind,
        sourceTypes = types, targets = descriptor.targets, profile = descriptor.profile,
        keepStops = descriptor.keepStops, ignoreRecords = ignored,
        priority = descriptor.priority,
        orderKey = descriptor.orderKey or string.format('%012d', row.sourceIndex)}
    end
    local parsed = input(spec, 'attach', tostring(sourceAction.diagnosticId) .. (#groups > 1 and (':' .. gi) or ''),
      {rules = rules}, 'choice', group.cell)
    -- Source type restrictions are already part of every rule. Remaining
    -- reference/query restrictions still travel through common selection.
    if parsed.select then parsed.select.type = nil; parsed.select.recordId = nil end
    out[#out + 1] = source_ir.prepared(sourceAction, parsed, {selectPredicates = filters})
  end
  return out
end

-- New selector rows lower to the existing direct-payload programs. This keeps
-- record catalog membership out of family programs and leaves legacy row
-- lowering (including its saved action identities) unchanged.
local function structuredRows(sourceAction, spec, verb, tuples, filters, actionPath)
  local out, legacy, attachGroups, attachOrder = {}, {}, {}, {}
  for _, tuple in ipairs(tuples) do
    local raw = tuple.values[1]
    if not ref_selector.isObject(raw) then
      legacy[#legacy + 1] = tuple
    else
      local path = actionPath .. '.' .. verb .. '[' .. tuple.sourceIndex .. '][2]'
      local query, err = ref_selector.normalize(raw, path)
      if query == nil then return nil, err end
      local localSpec = copyObject(spec)
      local select = copyObject(spec.select)
      local base = select.query
      if select.recordId ~= nil then
        local exact, exactErr = ref_selector.normalize({recordId = select.recordId}, actionPath .. '.select')
        if not exact then return nil, exactErr end
        base = ref_selector.intersect(base, exact)
        select.recordId = nil
      end
      select.query = ref_selector.intersect(base, query)
      localSpec.select = select
      if verb == 'attach' then
        local ids = query.recordId
        if ids == nil or #ids ~= 1 or query.matches ~= nil then
          return nil, path .. ': structured attach selectors require one exact recordId source hint'
        end
        local key = spec_key.fromSpec({cell = tuple.cell, query = select.query})
        local group = attachGroups[key]
        if group == nil then
          group = {spec = localSpec, rows = {}, cell = tuple.cell}
          attachGroups[key], attachOrder[#attachOrder + 1] = group, key
        end
        tuple.values[1] = ids[1]
        group.rows[#group.rows + 1] = tuple
      else
        local payload = tuple.values[2] or {}
        local id = tostring(sourceAction.diagnosticId) .. ':query:' .. tostring(tuple.sourceIndex)
        out[#out + 1] = source_ir.prepared(sourceAction,
          input(localSpec, verb, id, payload, 'direct', tuple.cell),
          {selectPredicates = appendPredicates(filters, tuple.predicates)})
      end
    end
  end
  for _, key in ipairs(attachOrder) do
    local group = attachGroups[key]
    out[#out + 1] = source_ir.prepared(sourceAction,
      input(group.spec, verb, tostring(sourceAction.diagnosticId) .. ':query:' .. #out,
        group.rows, 'tuples', group.cell), {selectPredicates = filters})
  end
  for _, group in ipairs(groupTuplesByCell(legacy)) do
    out[#out + 1] = source_ir.prepared(sourceAction,
      input(spec, verb, tostring(sourceAction.diagnosticId) .. ':legacy:' .. #out,
        group.tuples, 'tuples', group.cell), {selectPredicates = filters})
  end
  return out
end

function M.preprocess(sourceAction, opts)
  opts = opts or {}
  if type(sourceAction) ~= 'table' or sourceAction.kind ~= 'mom-source-action' then
    return nil, {'source action: expected mom-source-action'}
  end
  local spec = sourceAction.spec
  local actionId = sourceAction.diagnosticId
  local actionPath = authored_path.fromSource(sourceAction.source, actionId)
  if sourceAction.familyInput ~= nil then return nil, {actionPath .. ': prepared familyInput is not a source action'} end
  local verb, verbErr = source_action_contract.detectVerb(spec)
  if not verb then
    return nil, {tostring(actionPath) .. ': ' .. tostring(verbErr)}
  end
  if spec.select and ref_selector.isExtended(spec.select) then
    local select, err = ref_selector.lowerSelect(spec.select, tostring(actionPath) .. '.select')
    if select == nil then return nil, {err} end
    spec = copyObject(spec)
    spec.select = select
  end
  local payload = spec[verb]
  if verb == 'inventory' and type(payload) == 'table' and type(payload.owners) == 'table' then
    local structured = false
    for _, owner in ipairs(payload.owners) do
      if type(owner) == 'table' and ref_selector.isObject(owner[2]) then structured = true end
    end
    if structured then
      local rows = {}
      for _, owner in ipairs(payload.owners) do rows[#rows + 1] = {owner[1], owner[2], payload.items} end
      payload = rows
    end
  end
  local payloadKind, payloadErr = source_action_contract.classifyPayload(
    payload, verb, {isChild = opts.isChild == true})
  if payloadErr == 'not_table' then
    return nil, {tostring(actionPath) .. '.' .. verb
      .. ': expected array of tuples or direct payload object'}
  end
  local filters, filterErr = filterPredicates(spec, actionPath)
  if filterErr then return nil, {filterErr} end
  if payloadKind == 'direct' then
    return {source_ir.prepared(sourceAction,
      input(spec, verb, tostring(actionId), payload, 'direct'),
      {selectPredicates = filters})}, nil
  end
  local tuples, tupleErr = normalizeTuples(payload, actionPath, verb, {
    isChild = opts.isChild == true, compact = payloadKind == 'compact_child',
  })
  if not tuples then return nil, {tupleErr} end
  if payloadKind == 'compact_child' then
    -- Unlike the direct-payload child families, attachment rows are one
    -- placement batch: splitting them would change source claims and allow
    -- one row to disable an anchor before the other rows capture it.
    if verb == 'attach' then
      local selectPredicates = filters
      if #tuples == 1 then
        selectPredicates = appendPredicates(filters, tuples[1].predicates)
        tuples[1].predicates = nil
      end
      return {source_ir.prepared(sourceAction,
        input(spec, verb, tostring(actionId), tuples, 'inherited_tuples'),
        {selectPredicates = selectPredicates})}, nil
    end
    local out = {}
    for i = 1, #tuples do
      local tuple = tuples[i]
      local id = tostring(actionId) .. (#tuples > 1 and (':' .. tostring(i)) or '')
      out[i] = source_ir.prepared(sourceAction,
        input(spec, verb, id, tuple.values[1], 'direct'),
        {selectPredicates = appendPredicates(filters, tuple.predicates)})
    end
    return out, nil
  end
  if payloadErr == 'mixed_compact_child' then
    return nil, {tostring(actionPath) .. '.' .. verb
      .. ': cannot mix inherited child payload tuples with explicit target tuples'}
  end
  if #tuples == 0 then
    return nil, {tostring(actionPath) .. '.' .. verb .. ': expected at least one tuple'}
  end

  if verb == 'attach' and hasChoice(spec) then
    local rows, err = choiceRows(sourceAction, spec, tuples, filters, tostring(actionPath), opts)
    if not rows then return nil, {err} end
    return rows, nil
  end

  if verb ~= 'place' then
    for _, tuple in ipairs(tuples) do
      if ref_selector.isObject(tuple.values[1]) then
        local rows, err = structuredRows(sourceAction, spec, verb, tuples, filters, tostring(actionPath))
        if rows == nil then return nil, {err} end
        return rows, nil
      end
    end
  end
  local groups = groupTuplesByCell(tuples)
  local out = {}
  for gi = 1, #groups do
    local group = groups[gi]
    local id = tostring(actionId) .. (#groups > 1 and (':' .. tostring(gi)) or '')
    out[gi] = source_ir.prepared(sourceAction,
      input(spec, verb, id, group.tuples, 'tuples', group.cell),
      {selectPredicates = filters})
  end
  return out, nil
end

return M
