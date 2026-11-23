-- Authored action grammar and diagnostics before source normalization.
local M = {}

local authored_contract = require('scripts.mom.compiler.authored_contract')
local cell_selection = require('scripts.mom.compiler.cell_selection')
local selection_validation = require('scripts.mom.compiler.selection_validation')
local plain_data = require('scripts.mom.contracts.plain_data')
local tables = require('scripts.mom.common.tables')
local tuple_contract = require('scripts.mom.compiler.tuple_contract')
local ref_selector = require('scripts.mom.contracts.ref_selector')
local replacement_choice = require('scripts.mom.contracts.replacement_choice')
local composition_order = require('scripts.mom.contracts.composition_order')

local compileFilters = tuple_contract.compileFilters
local compileTrailingPredicates = tuple_contract.compileTrailingPredicates
local fieldPath = tables.fieldPath
local isArray = tables.isArray
local isObject = tables.isObject
local COMMON_ACTION_FIELDS = authored_contract.familyInputActionFields
local ACTION_FIELD_ERRORS = authored_contract.actionFieldErrors
local AUTHORED_COMMON_ACTION_FIELDS = tables.copyObject(COMMON_ACTION_FIELDS)
AUTHORED_COMMON_ACTION_FIELDS.id = nil
local ACTION_SIBLING_FIELDS = {
  place = {},
  attach = {disableOriginal = true, transferContents = true},
  modify = {},
  kill = {},
  inventory = {},
  record = {},
  leveled = {},
}

local function addError(errors, message)
  errors[#errors + 1] = tostring(message)
end

local function firstError(errors)
  return errors and errors[1] or nil
end

local function validateDisallowedActionFields(action, path)
  for key, err in pairs(ACTION_FIELD_ERRORS) do
    if action[key] ~= nil then
      return string.format('%s.%s: %s', tostring(path), tostring(key), tostring(err))
    end
  end
  return nil
end

local function validateAdvancedActionFields(action, path)
  if action.previsit ~= nil and type(action.previsit) ~= 'boolean' then
    return string.format('%s.previsit: expected boolean', tostring(path))
  end
  return nil
end

local validateActionSpec

local detectVerb = require('scripts.mom.compiler.authored_intent').verb

local function validateTupleArrayShape(tuple, path, maxArity, errors)
  if type(tuple) ~= 'table' then
    addError(errors, tostring(path) .. ': expected tuple array')
    return
  end
  if #tuple > maxArity then
    addError(errors, tostring(path) .. ': tuple is too long')
  end
  for key in pairs(tuple) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > maxArity then
      addError(errors, fieldPath(path, key) .. ': is not allowed; expected tuple array')
      return
    end
  end
end

local function validateActionTupleArrayShape(tuple, path, errors)
  if type(tuple) ~= 'table' then
    addError(errors, tostring(path) .. ': expected tuple array')
    return
  end
  validateTupleArrayShape(tuple, path, #tuple, errors)
end

local function validateTrailingPredicates(tuple, path, firstPredicateIndex, errors)
  local _, err = compileTrailingPredicates(tuple, path, firstPredicateIndex)
  if err then
    addError(errors, err)
    return
  end
end

local function validateVector3(value, path, errors)
  if type(value) ~= 'table' then
    addError(errors, tostring(path) .. ': expected [x, y, z] array')
    return
  end
  for key in pairs(value) do
    if type(key) ~= 'number' or key % 1 ~= 0 or key < 1 or key > 3 then
      addError(errors, fieldPath(path, key) .. ': is not allowed; expected [x, y, z] array')
      return
    end
  end
  for i = 1, 3 do
    if type(value[i]) ~= 'number' then
      addError(errors, tostring(path) .. '[' .. tostring(i) .. ']: expected number')
    end
  end
end

local function validateRotation(value, path, errors)
  if type(value) ~= 'table' then
    addError(errors, tostring(path) .. ': expected rotation object')
    return
  end
  for key, raw in pairs(value) do
    if key ~= 'yaw' and key ~= 'pitch' and key ~= 'roll' then
      addError(errors, tostring(path) .. '.' .. tostring(key) .. ': is not allowed')
      return
    end
    if type(raw) ~= 'number' then
      addError(errors, tostring(path) .. '.' .. tostring(key) .. ': expected number')
      return
    end
  end
end

local function validateCellAtTupleHead(tuple, path, errors)
  local cell = tuple and tuple[1] or nil
  if cell == nil then
    addError(errors, tostring(path) .. '[1]: missing cell')
    return
  end
  if cell == '_parent' then
    addError(errors, tostring(path) .. '[1]: _parent is not supported; child actions inherit parent targets with direct payloads or compact payload rows')
    return
  end
  local cellType = type(cell)
  if cellType ~= 'string' and cellType ~= 'table' then
    addError(errors, tostring(path) .. '[1]: cell must be a string or object, got ' .. cellType)
  end
end

local function validateStringTupleField(value, path, errors, label)
  if type(value) ~= 'string' or value == '' then
    addError(errors, tostring(path) .. ': expected ' .. tostring(label or 'string'))
  end
end

local function validateTargetField(value, path, errors, label)
  if type(value) == 'string' then return validateStringTupleField(value, path, errors, label) end
  local _, err = ref_selector.normalize(value, path)
  if err then addError(errors, err) end
end

local function validatePlaceTuple(tuple, path, errors)
  validateActionTupleArrayShape(tuple, path, errors)
  if #errors > 0 then return end
  validateCellAtTupleHead(tuple, path, errors)
  local okDestination, destinationErr = cell_selection.validateExactDestinationSpec(
    tuple[1],
    tostring(path) .. '[1]'
  )
  if not okDestination then addError(errors, destinationErr) end
  if type(tuple[2]) == 'table' then
    local choice = tuple[2]
    local at = tostring(path) .. '[2]'
    for key in pairs(choice) do
      if not ({choose=true,seed=true,key=true,salt=true})[key] then addError(errors, at .. '.' .. tostring(key) .. ': is not allowed') end
    end
    if not isArray(choice.choose) or #choice.choose == 0 then addError(errors, at .. '.choose: expected non-empty target/weight tuples')
    else
      for i, entry in ipairs(choice.choose) do
        if not isArray(entry) or #entry ~= 2 then addError(errors, at .. '.choose[' .. i .. ']: expected [record, weight]')
        else
          local target = entry[1]
          if type(target) == 'table' then
            for key in pairs(target) do if key ~= 'recordId' then addError(errors, at .. ': absolute choices require record-ID targets') end end
            target = target.recordId
          end
          validateStringTupleField(target, at .. '.choose[' .. i .. '][1]', errors, 'placed record id')
          if type(entry[2]) ~= 'number' or entry[2] ~= entry[2] or entry[2] <= 0 or entry[2] == math.huge then
            addError(errors, at .. '.choose[' .. i .. '][2]: expected positive finite weight')
          end
        end
      end
    end
    if choice.seed ~= nil and (type(choice.seed) ~= 'number' or choice.seed ~= choice.seed or math.abs(choice.seed) == math.huge) then
      addError(errors, at .. '.seed: expected finite seed')
    end
    for _, key in ipairs({'key','salt'}) do if choice[key] ~= nil then validateStringTupleField(choice[key], at .. '.' .. key, errors) end end
  else validateStringTupleField(tuple[2], tostring(path) .. '[2]', errors, 'placed record id') end
  validateVector3(tuple[3], tostring(path) .. '[3]', errors)
  validateRotation(tuple[4], tostring(path) .. '[4]', errors)
  if #tuple > 4 then
    validateTrailingPredicates(tuple, path, 5, errors)
    if #errors == 0 then
      addError(errors, tostring(path) .. ': trailing predicates are not supported for absolute place tuples')
    end
  end
end

local function validateAttachTuple(tuple, path, errors)
  validateActionTupleArrayShape(tuple, path, errors)
  if #errors > 0 then return end
  validateCellAtTupleHead(tuple, path, errors)
  validateTargetField(tuple[2], tostring(path) .. '[2]', errors, 'anchor selector string')
  if type(tuple[3]) == 'table' then
    local _, err = replacement_choice.normalize(tuple[3], tostring(path) .. '[3]')
    if err then addError(errors, err) end
  else validateStringTupleField(tuple[3], tostring(path) .. '[3]', errors, 'replacement target string') end
  local argEnd = tuple_contract.attachArgumentEnd(tuple)
  if argEnd >= 4 then validateVector3(tuple[4], tostring(path) .. '[4]', errors) end
  if argEnd >= 5 then validateRotation(tuple[5], tostring(path) .. '[5]', errors) end
  validateTrailingPredicates(tuple, path, argEnd + 1, errors)
end

local function validateInventoryOwnerItemsPayload(payload, path, errors)
  if payload.owner ~= nil then
    addError(errors, tostring(path) .. '.owner: is not allowed; use owners')
    return
  end
  for key in pairs(payload) do
    if key ~= 'owners' and key ~= 'items' then
      addError(errors, fieldPath(path, key) .. ': is not allowed')
      return
    end
  end
  if type(payload.owners) ~= 'table' then
    addError(errors, tostring(path) .. '.owners: expected non-empty array of owner tuples')
    return
  end
  if not isArray(payload.owners) then
    addError(errors, tostring(path) .. '.owners: expected array of owner tuples')
    return
  end
  if #payload.owners == 0 then
    addError(errors, tostring(path) .. '.owners: expected at least one owner tuple')
    return
  end
  if not isObject(payload.items) then
    addError(errors, tostring(path) .. '.items: expected inventory payload object')
    return
  end
  for i = 1, #payload.owners do
    local ownerPath = string.format('%s.owners[%d]', tostring(path), i)
    local owner = payload.owners[i]
    validateTupleArrayShape(owner, ownerPath, 2, errors)
    if #errors > 0 then return end
    validateCellAtTupleHead(owner, ownerPath, errors)
    validateTargetField(owner[2], tostring(ownerPath) .. '[2]', errors, 'owner selector string')
    if #errors > 0 then return end
  end
end

local function validateModifyTuple(tuple, path, errors)
  validateActionTupleArrayShape(tuple, path, errors)
  if #errors > 0 then return end
  validateCellAtTupleHead(tuple, path, errors)
  validateTargetField(tuple[2], tostring(path) .. '[2]', errors, 'target string')
  if type(tuple[3]) ~= 'table' then
    addError(errors, tostring(path) .. '[3]: expected patch object')
  end
  validateTrailingPredicates(tuple, path, 4, errors)
end

local function validateInventoryTuple(tuple, path, errors)
  validateActionTupleArrayShape(tuple, path, errors)
  if #errors > 0 then return end
  validateCellAtTupleHead(tuple, path, errors)
  validateTargetField(tuple[2], tostring(path) .. '[2]', errors, 'owner selector string')
  if type(tuple[3]) ~= 'table' then
    addError(errors, tostring(path) .. '[3]: expected inventory payload object')
  end
  validateTrailingPredicates(tuple, path, 4, errors)
end

local function validateKillTuple(tuple, path, errors)
  validateActionTupleArrayShape(tuple, path, errors)
  if #errors > 0 then return end
  validateCellAtTupleHead(tuple, path, errors)
  validateTargetField(tuple[2], tostring(path) .. '[2]', errors, 'target string')
  local argEnd = tuple_contract.killArgumentEnd(tuple)
  if tuple[3] ~= nil and type(tuple[3]) ~= 'table' then
    addError(errors, tostring(path) .. '[3]: expected options object')
  end
  validateTrailingPredicates(tuple, path, argEnd + 1, errors)
end

local function validateChildCompactTuple(tuple, verb, path, errors)
  validateActionTupleArrayShape(tuple, path, errors)
  if #errors > 0 then return end
  if verb == 'attach' then
    if type(tuple[1]) == 'table' then
      local _, err = replacement_choice.normalize(tuple[1], tostring(path) .. '[1]')
      if err then addError(errors, err) end
    else validateStringTupleField(tuple[1], tostring(path) .. '[1]', errors, 'replacement target string') end
    local argEnd = tuple_contract.childAttachArgumentEnd(tuple)
    if argEnd >= 2 then validateVector3(tuple[2], tostring(path) .. '[2]', errors) end
    if argEnd >= 3 then validateRotation(tuple[3], tostring(path) .. '[3]', errors) end
    validateTrailingPredicates(tuple, path, argEnd + 1, errors)
    return
  end
  if type(tuple[1]) ~= 'table' then
    addError(errors, tostring(path) .. '[1]: expected inherited child payload object')
    return
  end
  validateTrailingPredicates(tuple, path, tuple_contract.predicateStart(tuple, verb, true), errors)
end

local function classifyPayload(payload, verb, opts)
  if type(payload) ~= 'table' then return nil, 'not_table' end
  if payload[1] == nil then return 'direct' end
  local compactChildCount = 0
  for i = 1, #payload do
    if tuple_contract.isChildCompactTuple(payload[i], verb, opts) then
      compactChildCount = compactChildCount + 1
    end
  end
  if compactChildCount > 0 then
    if compactChildCount ~= #payload then return nil, 'mixed_compact_child' end
    return 'compact_child'
  end
  return 'explicit'
end

local function validatePayloadShape(action, verb, path, errors, opts)
  local payload = action[verb]
  if verb == 'record' or verb == 'leveled' then
    if not isObject(payload) then addError(errors, tostring(path) .. '.' .. verb .. ': expected definition object') end
    return
  end
  local payloadKind, payloadErr = classifyPayload(payload, verb, opts)
  if payloadErr == 'not_table' then
    addError(errors, tostring(path) .. '.' .. tostring(verb) .. ': expected array of tuples or direct payload object')
    return
  end
  if payloadKind == 'direct' then
    if verb == 'place' or verb == 'attach' then
      addError(errors, tostring(path) .. '.' .. tostring(verb) .. ': expected non-empty tuple array')
    elseif verb == 'kill' then
      for key in pairs(payload) do
        addError(errors, tostring(path) .. '.kill.' .. tostring(key) .. ': is not allowed')
        break
      end
    elseif verb == 'inventory' and authored_contract.hasInventoryOwnerItemsKeys(payload) then
      validateInventoryOwnerItemsPayload(payload, tostring(path) .. '.inventory', errors)
    end
    return
  end
  if payloadErr == 'mixed_compact_child' then
    addError(errors, tostring(path) .. '.' .. tostring(verb) .. ': cannot mix inherited child payload tuples with explicit target tuples')
    return
  end
  for i = 1, #payload do
    local tuplePath = string.format('%s.%s[%d]', tostring(path), tostring(verb), i)
    local tuple = payload[i]
    if payloadKind == 'compact_child' then
      validateChildCompactTuple(tuple, verb, tuplePath, errors)
    elseif verb == 'place' then
      validatePlaceTuple(tuple, tuplePath, errors)
    elseif verb == 'attach' then
      validateAttachTuple(tuple, tuplePath, errors)
    elseif verb == 'modify' then
      validateModifyTuple(tuple, tuplePath, errors)
    elseif verb == 'inventory' then
      validateInventoryTuple(tuple, tuplePath, errors)
    elseif verb == 'kill' then
      validateKillTuple(tuple, tuplePath, errors)
    end
    if #errors > 0 then return end
  end
end

local function validateAuthoredActionKeys(action, verb, path, errors)
  local allowed = {}
  for key in pairs(AUTHORED_COMMON_ACTION_FIELDS) do allowed[key] = true end
  allowed[verb] = true
  for key in pairs(ACTION_SIBLING_FIELDS[verb] or {}) do allowed[key] = true end
  for key in pairs(action or {}) do
    if not allowed[key] then
      addError(errors, fieldPath(path, key) .. ': is not allowed')
      return
    end
  end
end

local function validateChildActions(action, path, errors, opts)
  if action.actions == nil then return end
  if opts and opts.canHaveChildren == false then
    addError(errors, tostring(path) .. '.actions: only place and attach actions can own child actions')
    return
  end
  if not isArray(action.actions) then
    addError(errors, tostring(path) .. '.actions: expected array')
    return
  end
  for i, child in ipairs(action.actions) do
    local childErr = validateActionSpec(child, string.format('%s.actions[%d]', tostring(path), i), {
      isChild = true,
    })
    if childErr then
      addError(errors, childErr)
      return
    end
  end
end

validateActionSpec = function(action, path, opts)
  if not isObject(action) then
    return string.format('%s: expected action object', tostring(path))
  end
  local errors = {}
  local actionFieldErr = validateDisallowedActionFields(action, path)
  if actionFieldErr then return actionFieldErr end
  local advancedErr = validateAdvancedActionFields(action, path)
  if advancedErr then return advancedErr end
  local verb, verbErr = detectVerb(action)
  if not verb then return tostring(path) .. ': ' .. tostring(verbErr) end
  validateAuthoredActionKeys(action, verb, path, errors)
  if #errors > 0 then return firstError(errors) end
  if action.select ~= nil then
    local okSelect, selectErrors = selection_validation.validateSelectSpec(action.select, path)
    if not okSelect then return selectErrors[1] end
  end
  local _, filterErr = compileFilters(
    action.filters,
    tostring(path) .. '.filters'
  )
  if filterErr then return filterErr end
  validatePayloadShape(action, verb, path, errors, opts)
  if #errors > 0 then return firstError(errors) end
  validateChildActions(action, path, errors, {
    canHaveChildren = verb == 'place' or verb == 'attach',
  })
  if #errors > 0 then return firstError(errors) end
  return nil
end

M.classifyPayload = classifyPayload
M.detectVerb = detectVerb
M.validate = validateActionSpec

function M.validatePublicFields(spec, compiler, actionPath)
  local publicFields = {}
  for i = 1, #((compiler and compiler.publicFields) or {}) do
    publicFields[compiler.publicFields[i]] = true
  end
  local errors = {}
  for key in pairs(spec or {}) do
    if not COMMON_ACTION_FIELDS[key] and not publicFields[key] then
      errors[#errors + 1] = tostring(actionPath) .. '.' .. tostring(key) .. ': is not allowed'
    end
  end
  return #errors == 0, errors
end

-- Native loading and compatibility translators share this source record.
-- Extension admission validates the complete tree before bootstrap detaches it;
-- family syntax and payload validation still belong to shared preparation.
local SOURCE_ACTION_FIELDS = {
  kind = true, family = true, diagnosticId = true, spec = true,
  source = true, guardOwner = true, priority = true, conflict = true,
  compositionOrder = true,
  children = true,
  uniqueSourceKey = true,
  allowEmptyCellSelection = true,
}
local SOURCE_FIELDS = {adapterId = true, file = true, variant = true, path = true}

local function sourceFields(value, allowed, path, errors)
  for key in pairs(value) do
    if not allowed[key] then addError(errors, fieldPath(path, key) .. ': field is not allowed') end
  end
end

local function sourceString(value, path, errors)
  if type(value) ~= 'string' or value == '' then
    addError(errors, path .. ': expected non-empty string')
  end
end

local validateSourceArray
local function validateSourceAction(action, path, adapterId, errors)
  if not isObject(action) then addError(errors, path .. ': expected source action object') return end
  sourceFields(action, SOURCE_ACTION_FIELDS, path, errors)
  if action.kind ~= 'mom-source-action' then addError(errors, path .. '.kind: expected mom-source-action') end
  sourceString(action.family, path .. '.family', errors)
  sourceString(action.diagnosticId, path .. '.diagnosticId', errors)
  if action.allowEmptyCellSelection ~= nil and type(action.allowEmptyCellSelection) ~= 'boolean' then
    addError(errors, path .. '.allowEmptyCellSelection: expected boolean')
  end
  if action.uniqueSourceKey ~= nil then sourceString(action.uniqueSourceKey, path .. '.uniqueSourceKey', errors) end
  if not isObject(action.source) then
    addError(errors, path .. '.source: expected object')
  else
    local source = action.source
    sourceFields(source, SOURCE_FIELDS, path .. '.source', errors)
    sourceString(source.adapterId, path .. '.source.adapterId', errors)
    if adapterId ~= nil and source.adapterId ~= adapterId then
      addError(errors, path .. '.source.adapterId: must match translator id ' .. tostring(adapterId))
    end
    sourceString(source.file, path .. '.source.file', errors)
    if source.variant ~= nil then sourceString(source.variant, path .. '.source.variant', errors) end
    if not isArray(source.path) then
      addError(errors, path .. '.source.path: expected array')
    else
      for i = 1, #source.path do
        local kind = type(source.path[i])
        if kind ~= 'string' and kind ~= 'number' then
          addError(errors, path .. '.source.path[' .. tostring(i) .. ']: expected string or number')
        end
      end
    end
  end
  if not isObject(action.spec) then
    addError(errors, path .. '.spec: expected action object')
  else
    local spec = action.spec
    local verb, verbError = detectVerb(spec)
    if not verb then addError(errors, path .. '.spec: ' .. tostring(verbError))
    elseif action.family ~= authored_contract.actionKindForVerb(verb) then
      addError(errors, path .. '.family: expected ' .. tostring(authored_contract.actionKindForVerb(verb)) .. ' for verb ' .. verb)
    end
    if spec.actions ~= nil then addError(errors, path .. '.spec.actions: source children belong in children') end
    if spec.chance ~= nil and (type(spec.chance) ~= 'number' or spec.chance < 0 or spec.chance > 1) then
      addError(errors, path .. '.spec.chance: expected number in [0, 1]')
    end
    if spec.previsit ~= nil and type(spec.previsit) ~= 'boolean' then
      addError(errors, path .. '.spec.previsit: expected boolean')
    end
  end
  if action.priority ~= nil and (type(action.priority) ~= 'number' or action.priority % 1 ~= 0) then
    addError(errors, path .. '.priority: expected integer')
  end
  local orderValid, orderError = composition_order.validate(action.compositionOrder, path .. '.compositionOrder')
  if not orderValid then addError(errors, orderError) end
  if action.conflict ~= nil and not isObject(action.conflict) then addError(errors, path .. '.conflict: expected object') end
  if action.guardOwner ~= nil and not isObject(action.guardOwner) then addError(errors, path .. '.guardOwner: expected object') end
  validateSourceArray(action.children, path .. '.children', adapterId, errors)
end

validateSourceArray = function(actions, path, adapterId, errors)
  if not isArray(actions) then addError(errors, path .. ': expected source action array') return end
  for i = 1, #actions do validateSourceAction(actions[i], path .. '[' .. tostring(i) .. ']', adapterId, errors) end
end

function M.validateSourceActions(actions, opts)
  opts = opts or {}
  local path = opts.path or 'sourceActions'
  local plain, plainErrors = plain_data.validate(actions, {path = path})
  if not plain then return nil, plainErrors end
  local errors = {}
  validateSourceArray(actions, path, opts.adapterId, errors)
  if type(actions) == 'table' and #actions == 0 and opts.allowEmpty ~= true then
    addError(errors, path .. ': expected at least one action')
  end
  if #errors > 0 then return nil, errors end
  return true, nil
end

return M
