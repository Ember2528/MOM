-- Tuple boundaries and shared predicate grammar for authored admission and preparation.
local M = {}
local predicate_contract = require('scripts.mom.contracts.predicate')
local ref_selector = require('scripts.mom.contracts.ref_selector')

local CHILD_COMPACT_VERBS = {
  modify = true,
  inventory = true,
  kill = true,
}

local function isChildOpt(opts)
  if type(opts) == 'table' then
    return opts.isChild == true
  end
  return opts == true
end

function M.isPredicateTuple(value)
  return type(value) == 'table' and type(value[1]) == 'string'
end

function M.isChildCompactTuple(tuple, verb, opts)
  if isChildOpt(opts) and verb == 'attach' then
    -- Explicit attach rows always begin with a cell followed by an anchor
    -- string. Abbreviated rows begin with a replacement string followed by
    -- an optional vector, rotation, or predicate.
    return type(tuple) == 'table' and type(tuple[1]) == 'string'
      and type(tuple[2]) ~= 'string'
      and not ref_selector.isObject(tuple[2])
  end
  if not (isChildOpt(opts) and CHILD_COMPACT_VERBS[verb]) then
    return false
  end
  if type(tuple) ~= 'table' or type(tuple[1]) ~= 'table' then return false end
  return tuple[2] == nil or M.isPredicateTuple(tuple[2])
end

function M.childAttachArgumentEnd(tuple)
  local argEnd = 1
  if tuple[2] ~= nil and not M.isPredicateTuple(tuple[2]) then argEnd = 2 end
  if tuple[3] ~= nil and not M.isPredicateTuple(tuple[3]) then argEnd = 3 end
  return argEnd
end

function M.attachArgumentEnd(tuple)
  local argEnd = 3
  if tuple[4] ~= nil and not M.isPredicateTuple(tuple[4]) then
    argEnd = 4
  end
  if tuple[5] ~= nil and not M.isPredicateTuple(tuple[5]) then
    argEnd = 5
  end
  return argEnd
end

function M.killArgumentEnd(tuple)
  if tuple[3] ~= nil and not M.isPredicateTuple(tuple[3]) then
    return 3
  end
  return 2
end

function M.argumentEnd(tuple, verb, opts)
  if M.isChildCompactTuple(tuple, verb, opts) then
    if verb == 'attach' then return M.childAttachArgumentEnd(tuple) end
    return 1
  end
  if verb == 'place' then return 4 end
  if verb == 'attach' then return M.attachArgumentEnd(tuple) end
  if verb == 'modify' or verb == 'inventory' then return 3 end
  if verb == 'kill' then return M.killArgumentEnd(tuple) end
  return #tuple
end

function M.predicateStart(tuple, verb, opts)
  return M.argumentEnd(tuple, verb, opts) + 1
end

-- Prepared-family argument shape; authored tuple admission retains its own diagnostics.
function M.validateArity(tuple, path, maxArity)
  if #tuple > maxArity then
    return nil, { path .. ': tuple is too long' }
  end
  for key in pairs(tuple) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > maxArity then
      return nil, { path .. '.' .. tostring(key) .. ': is not allowed; expected tuple array' }
    end
  end
  return true, nil
end

-- Called independently by admission and preparation; no parsed-result cache is shared.
function M.compileTrailingPredicates(tuple, path, firstPredicateIndex)
  local predicates = nil
  for i = firstPredicateIndex, #tuple do
    if not M.isPredicateTuple(tuple[i]) then
      return nil, tostring(path) .. '[' .. tostring(i) .. ']: expected predicate tuple'
    end
    local predicate, err = predicate_contract.compileTuple(
      tuple[i],
      tostring(path) .. '[' .. tostring(i) .. ']'
    )
    if err then return nil, err end
    if predicates == nil then predicates = {} end
    predicates[#predicates + 1] = predicate
  end
  return predicates, nil
end

function M.compileFilters(filters, path)
  if filters == nil then return nil, nil end
  if type(filters) ~= 'table' then
    return nil, tostring(path) .. ': expected array or predicate tuple'
  end
  if type(filters[1]) == 'string' then
    local predicate, err = predicate_contract.compileTuple(filters, tostring(path))
    if err then return nil, err end
    return {predicate}, nil
  end
  local predicates = {}
  for i = 1, #filters do
    local item = filters[i]
    if type(item) ~= 'table' or type(item[1]) ~= 'string' then
      return nil, string.format('%s[%d]: expected predicate tuple', tostring(path), i)
    end
    local predicate, err = predicate_contract.compileTuple(
      item,
      string.format('%s[%d]', tostring(path), i)
    )
    if err then return nil, err end
    predicates[#predicates + 1] = predicate
  end
  return predicates, nil
end

return M
