-- Explicit records used by the single compiler pipeline. These records are
-- plain data; action-family hooks return final family programs instead of
-- attaching compiler-private fields to authored tables.
local M = {}

local plain_data = require('scripts.mom.contracts.plain_data')
local tables = require('scripts.mom.common.tables')

---@class MomSourceAction
---@field kind 'mom-source-action'
---@field family string
---@field diagnosticId string Authored location, never a semantic runtime ID.
---@field spec table|nil Authored verb payload, before cell and predicate lowering.
---@field source table
---@field guardOwner table|nil
---@field priority integer|nil
---@field conflict table|nil
---@field children MomSourceAction[]

---@class MomSyntaxTuple
---@field values any[] Verb arguments with cell and predicates removed; replaced during family preparation.
---@field sourceIndex integer Original authored tuple index, retained with its prepared payload.
---@field predicates table[]|nil

---@class MomFamilyInput
---@field id string Diagnostic location, never a semantic ID.
---@field verb string
---@field payloadKind 'direct'|'tuples'|'inherited_tuples'|'choice'
---@field payload table Family-owned payload; preparation replaces raw syntax in this slot.
---@field select table|nil Authored selector, never reconstructed from resolved target facts.
---@field chance number|nil
---@field previsit boolean|nil
---@field options table|nil Family-specific sibling options.

---@class MomPreparedAction
---@field kind 'mom-prepared-action'
---@field family string
---@field diagnosticId string
---@field input MomFamilyInput Owned syntax consumed by the dynamically bound family.
---@field source table
---@field guardOwner table|nil
---@field priority integer|nil
---@field conflict table|nil
---@field selectPredicates table[]|nil
---@field children MomPreparedAction[]|nil Attached by prepareActions before consumption.

---@class MomCompiledActionSpec
---@field program table Final family program; never an intermediate target-entry list.
---@field select table|nil Authored selection, with normalized cell grouping.
---@field id string|nil Diagnostic label for this family output row.
---@field chance number|nil Overrides the prepared source chance when present.
---@field previsit boolean|nil

---@class MomFamilyProgram
---@field kind 'mom-family-program'
---@field spec MomCompiledActionSpec Final program and common action fields.
---@field claims table
---@field reversible boolean
---@field candidateTypes table|nil
---@field resolvedSelection table|nil Compile-only final exact-ID/query arrays.
---@field directTargets table|nil
---@field queryCells table|nil

---@class MomNormalizedAction
---@field kind 'action'
---@field id string Diagnostic ID; semantic IDs are assigned by manifest compilation.
---@field family string
---@field source table
---@field sourceRef string Bounded diagnostic label excluded from semantic identity.
---@field program table Final family program, shared until the full-tree detach.
---@field claims table
---@field reversible boolean
---@field select table|nil
---@field predicates table[]|nil
---@field candidateTypes table|nil
---@field resolvedSelection table|nil Compile-only final exact-ID/query arrays.
---@field directTargets table|nil
---@field queryCells table|nil
---@field priority integer|nil
---@field conflict table|nil
---@field chance number|nil
---@field previsit boolean
---@field guardOwner table|nil
---@field children MomNormalizedAction[]

local function detach(value, path)
  if value == nil then return nil end
  local out, errors = plain_data.detach(value, {path = path})
  if out ~= nil then return out end
  error('source IR is invalid: ' .. table.concat(errors or {}, ' | '), 0)
end

local function ownedChildren(children)
  if children == nil then return {} end
  assert(type(children) == 'table', 'sourceAction.children: expected array')
  local out = {}
  assert(tables.isArray(children), 'sourceAction.children: expected dense array')
  for i = 1, #children do
    local child = children[i]
    assert(type(child) == 'table' and child.kind == 'mom-source-action',
      'sourceAction.children[' .. tostring(i) .. ']: expected mom-source-action')
    out[i] = child
  end
  return out
end

local function sourceAction(spec, fields, copy)
  fields = fields or {}
  assert(fields.familyInput == nil, 'source actions require ordinary specs; prepared familyInput is compiler-owned')
  return {
    kind = 'mom-source-action',
    family = fields.family or assert(require('scripts.mom.compiler.authored_contract').actionKindForVerb(
      require('scripts.mom.compiler.authored_intent').verb(spec))),
    diagnosticId = assert(fields.diagnosticId),
    spec = copy(spec, 'sourceAction.spec'),
    uniqueSourceKey = fields.uniqueSourceKey,
    allowEmptyCellSelection = fields.allowEmptyCellSelection,
    source = copy(fields.source, 'sourceAction.source') or {},
    guardOwner = copy(fields.guardOwner, 'sourceAction.guardOwner'),
    priority = fields.priority,
    compositionOrder = copy(fields.compositionOrder, 'sourceAction.compositionOrder'),
    conflict = copy(fields.conflict, 'sourceAction.conflict'),
    children = ownedChildren(fields.children),
  }
end

-- Child records are already compiler-owned source IR. Transferring those
-- records avoids recloning the complete descendant tree once per ancestor;
-- the source-attempt boundary performs the one full-tree detachment.
function M.sourceAction(spec, fields)
  return sourceAction(spec, fields, detach)
end

local function owned(value) return value end

-- Constructs a source record from freshly owned fields without per-node copies.
-- Compatibility admission validates the complete tree before bootstrap detaches
-- it from the translator; this constructor does not establish that proof.
function M.sourceActionOwned(spec, fields)
  return sourceAction(spec, fields, owned)
end

function M.prepared(sourceAction, input, fields)
  fields = fields or {}
  return {
    kind = 'mom-prepared-action',
    family = sourceAction.family,
    diagnosticId = sourceAction.diagnosticId,
    input = input,
    source = sourceAction.source,
    guardOwner = sourceAction.guardOwner,
    priority = sourceAction.priority,
    allowEmptyCellSelection = sourceAction.allowEmptyCellSelection,
    conflict = sourceAction.conflict,
    loadDecision = sourceAction.loadDecision,
    selectPredicates = fields.selectPredicates,
    -- prepareActions attaches prepared children after their own preprocessing;
    -- this payload record need not retain another link to source children.
  }
end

-- Keep the family-hook ABI envelope stable. `spec.program` is already final;
-- only normalizedAction() projects this envelope into the compiler's action IR.
---@param spec MomCompiledActionSpec
---@param fields table|nil
---@return MomFamilyProgram
function M.familyProgram(spec, fields)
  fields = fields or {}
  return {
    kind = 'mom-family-program',
    spec = spec,
    claims = fields.claims,
    reversible = fields.reversible,
    candidateTypes = fields.candidateTypes,
    resolvedSelection = fields.resolvedSelection,
    directTargets = fields.directTargets,
    queryCells = fields.queryCells,
  }
end

-- The one field-ownership boundary between family output and normalized IR.
-- Families own program/claims/target facts and the lowered select. Source
-- preparation owns provenance, predicates, priority, conflict, and children.
-- This transfers references; lowerActions() performs the full-tree
-- detach after every hook has returned, with no per-node defensive copy.
---@param prepared MomPreparedAction
---@param familyOutput MomFamilyProgram
---@param children MomNormalizedAction[]
---@param index integer
---@param sourceRef string
---@return MomNormalizedAction
function M.normalizedAction(prepared, familyOutput, children, index, sourceRef)
  local compiledSpec = familyOutput.spec
  local diagnosticId = compiledSpec.id or (tostring(prepared.diagnosticId) .. ':' .. tostring(index))
  local node = {
    kind = 'action',
    id = tostring(diagnosticId),
    family = prepared.family,
    source = prepared.source,
    sourceRef = sourceRef,
    program = compiledSpec.program,
    claims = familyOutput.claims,
    reversible = familyOutput.reversible,
    select = compiledSpec.select,
    predicates = prepared.selectPredicates,
    candidateTypes = familyOutput.candidateTypes,
    resolvedSelection = familyOutput.resolvedSelection,
    directTargets = familyOutput.directTargets,
    queryCells = familyOutput.queryCells,
    priority = prepared.priority,
    allowEmptyCellSelection = prepared.allowEmptyCellSelection,
    conflict = prepared.conflict,
    chance = compiledSpec.chance ~= nil and compiledSpec.chance or prepared.input.chance,
    previsit = compiledSpec.previsit == true,
    guardOwner = prepared.guardOwner,
    children = children,
  }
  return node
end

local FAMILY_PROGRAM_FIELDS = {
  kind = true,
  spec = true,
  claims = true,
  reversible = true,
  candidateTypes = true,
  resolvedSelection = true,
  directTargets = true,
  queryCells = true,
}

local function validateResolvedSelection(value, path, errors)
  if value == nil or type(value) ~= 'table' then return end
  local fields = {exactIds = true, exactIdQueries = true, candidateTypes = true, skipped = true}
  for key in pairs(value) do
    if not fields[key] then errors[#errors + 1] = path .. '.' .. tostring(key) .. ': field is not allowed' end
  end
  for field in pairs(fields) do
    if type(value[field]) ~= 'table' then
      errors[#errors + 1] = path .. '.' .. field .. ': expected table'
      return
    end
  end
  for i = 1, #value.exactIds do
    if type(value.exactIds[i]) ~= 'string' or value.exactIds[i] == '' then
      errors[#errors + 1] = path .. '.exactIds: expected non-empty record IDs'
      return
    end
  end
  for i = 1, #value.exactIdQueries do
    local query = value.exactIdQueries[i]
    if type(query) ~= 'table' or type(query.recordId) ~= 'string' or query.recordId == ''
        or type(query.typeName) ~= 'string' or query.typeName == '' then
      errors[#errors + 1] = path .. '.exactIdQueries: expected record/type pairs'
      return
    end
  end
  for key, enabled in pairs(value.candidateTypes) do
    if type(key) ~= 'string' or key == '' or enabled ~= true then
      errors[#errors + 1] = path .. '.candidateTypes: expected type set'
      return
    end
  end
  for i = 1, #value.skipped do
    local item = value.skipped[i]
    if type(item) ~= 'table' or type(item.recordId) ~= 'string' or type(item.reason) ~= 'string' then
      errors[#errors + 1] = path .. '.skipped: expected record ID and reason'
      return
    end
  end
end

function M.validateFamilyProgram(value, path)
  path = path or 'familyProgram'
  local errors = {}
  if type(value) ~= 'table' then
    return nil, {path .. ': expected mom-family-program object'}
  end
  if getmetatable(value) ~= nil then
    return nil, {path .. ': metatables are not allowed'}
  end
  for key in pairs(value) do
    if not FAMILY_PROGRAM_FIELDS[key] then
      errors[#errors + 1] = path .. '.' .. tostring(key) .. ': field is not allowed'
    end
  end
  if value.kind ~= 'mom-family-program' then
    errors[#errors + 1] = path .. '.kind: expected mom-family-program'
  end
  if type(value.spec) ~= 'table' then
    errors[#errors + 1] = path .. '.spec: expected object'
  elseif getmetatable(value.spec) ~= nil then
    errors[#errors + 1] = path .. '.spec: metatables are not allowed'
  elseif type(rawget(value.spec, 'program')) ~= 'table' then
    errors[#errors + 1] = path .. '.spec.program: expected final program object'
  end
  if type(value.claims) ~= 'table' then
    errors[#errors + 1] = path .. '.claims: expected object'
  elseif getmetatable(value.claims) ~= nil then
    errors[#errors + 1] = path .. '.claims: metatables are not allowed'
  end
  if type(value.reversible) ~= 'boolean' then
    errors[#errors + 1] = path .. '.reversible: expected boolean'
  end
  for _, field in ipairs({'candidateTypes', 'resolvedSelection', 'directTargets', 'queryCells'}) do
    if value[field] ~= nil and type(value[field]) ~= 'table' then
      errors[#errors + 1] = path .. '.' .. field .. ': expected object'
    elseif type(value[field]) == 'table' and getmetatable(value[field]) ~= nil then
      errors[#errors + 1] = path .. '.' .. field .. ': metatables are not allowed'
    end
  end
  validateResolvedSelection(value.resolvedSelection, path .. '.resolvedSelection', errors)
  if #errors > 0 then return nil, errors end
  return true, nil
end

-- Project only the shared final fields; the consumed family payload is not retained.
function M.compiledSpec(input)
  return {id = input.id, select = input.select, chance = input.chance, previsit = input.previsit}
end

-- A fresh shallow envelope shares the selector payload references.
function M.mergePublicSelect(baseSelect, override)
  local merged = {}
  for key, value in pairs(baseSelect or {}) do
    merged[key] = value
  end
  for key, value in pairs(override or {}) do
    merged[key] = value
  end
  return merged
end

return M
