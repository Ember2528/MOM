-- Every format converges here before execution placement. This stage reads
-- installed-plugin membership only; it never resolves records or live cells.
local M = {}
local tables = require('scripts.mom.common.tables')
local canonical = require('scripts.mom.contracts.canonical')
local authored = require('scripts.mom.compiler.authored_contract')
local normalization = require('scripts.mom.compiler.action_normalization')
local intent = require('scripts.mom.compiler.authored_intent')
local composition_order = require('scripts.mom.contracts.composition_order')
local ref_type = require('scripts.mom.contracts.ref_type')
local sampling = require('scripts.mom.domain.variation.stable')
local finite = require('scripts.mom.common.numbers').isFinite
local ADMISSION_FIELDS = {requires=true,requiresAny=true,requiresNot=true,chance=true,seed=true,key=true,salt=true}
local PLACEMENT_CHOICE_FIELDS = {choose=true,seed=true,key=true,salt=true}

local function condition(raw, active, mode, path)
  if raw == nil then return true end
  if type(raw) == 'string' then raw = {raw} end
  assert(tables.isArray(raw), path .. ': expected string array')
  local any = false
  for _, name in ipairs(raw) do
    assert(type(name) == 'string' and name ~= '', path .. ': expected non-empty content filename')
    local present = active[name:lower()] == true
    any = any or present
    if mode == 'all' and not present then return false end
    if mode == 'not' and present then return false end
  end
  return mode ~= 'any' or #raw == 0 or any
end
local function requirements(raw, active, path)
  return condition(raw.requires, active, 'all', path .. '.requires')
    and condition(raw.requiresAny, active, 'any', path .. '.requiresAny')
    and condition(raw.requiresNot, active, 'not', path .. '.requiresNot')
end
local function normalizeAction(action, active, isChild, isGuarded)
  assert(type(action) == 'table' and type(action.spec) == 'table', 'ordinary source action spec is required')
  assert(action.familyInput == nil, 'translators cannot provide prepared familyInput')
  local path = tostring(action.diagnosticId or '<action>')
  local guarded = isGuarded or action.guardOwner ~= nil
  local orderValid, orderError = composition_order.validate(
    action.compositionOrder, path .. '.compositionOrder')
  assert(orderValid, orderError)
  local verb, verbError = intent.verb(action.spec)
  assert(verb, path .. ': ' .. tostring(verbError))
  action.family = assert(authored.actionKindForVerb(verb), path .. ': unknown operation')
  local spec, normalizationError = normalization.spec(action.spec, path, {isChild = isChild})
  assert(spec, normalizationError)
  if verb == 'attach' and type(spec.attach) == 'table' then
    for index, row in ipairs(spec.attach) do
      if type(row) == 'table' and type(row[3]) == 'table' and row[3].choose ~= nil then
        assert(not guarded, path .. '.attach[' .. tostring(index)
          .. ']: appearance choice only supports unguarded static actions')
      end
    end
  end
  if spec.transferContents ~= nil then
    assert(verb == 'attach' and type(spec.transferContents) == 'boolean',
      path .. '.transferContents: expected an attachment boolean')
  end
  if not requirements(spec, active, path) then return nil end
  spec.requires, spec.requiresAny, spec.requiresNot = nil, nil, nil
  local admission = spec.admission
  if admission ~= nil then
    assert(tables.isObject(admission), path .. '.admission: expected object')
    for field in pairs(admission) do
      assert(ADMISSION_FIELDS[field],
        path .. '.admission.' .. tostring(field) .. ': is not allowed')
    end
    if not requirements(admission, active, path .. '.admission') then return nil end
    local chance = admission.chance == nil and 1 or admission.chance
    assert(finite(chance) and chance >= 0 and chance <= 1, path .. '.admission.chance: expected probability')
    local key = admission.key or spec.key or canonical.assertHash(spec)
    if sampling.unit(key, admission.seed, admission.salt or 'condition') >= chance then return nil end
    spec.admission = nil
  end
  if spec.key ~= nil then
    assert(verb == 'place' and type(spec.key) == 'string' and spec.key ~= '',
      path .. '.key: requires an absolute placement and a non-empty key')
    action.uniqueSourceKey = spec.key
  end
  if spec.targetTypes ~= nil then
    assert(verb == 'place' and tables.isArray(spec.targetTypes) and #spec.targetTypes > 0,
      path .. '.targetTypes: requires a non-empty placement type array')
    for _, name in ipairs(spec.targetTypes) do
      assert(ref_type.contains(name), path .. '.targetTypes: invalid type')
    end
  end
  if spec.onMissingTarget ~= nil then
    assert((verb == 'record' or verb == 'leveled') and spec.onMissingTarget == 'skip',
      path .. '.onMissingTarget: skip is supported only for definition actions')
  end
  if verb == 'place' and type(spec.place) == 'table' then
    for _, row in ipairs(spec.place) do
      if type(row[2]) == 'table' then
        local choice = row[2]
        for field in pairs(choice) do
          assert(PLACEMENT_CHOICE_FIELDS[field], path .. '.place choice: unknown field')
        end
        row[2] = sampling.pick(choice.choose,
          choice.key or spec.key or canonical.assertHash(spec), choice.seed, choice.salt or 'alternative')
      end
    end
  end
  action.spec = spec
  local children = {}
  for _, child in ipairs(action.children or {}) do
    local result = normalizeAction(child, active, true, guarded)
    if result then children[#children + 1] = result end
  end
  action.children = children
  return action
end
function M.normalize(attempts, options)
  local active = options and options.activeContent
  if active == nil then
    active = require('scripts.mom.common.content_files').activeSet(require('openmw.core').contentFiles)
  end
  local errors = {}
  for _, attempt in ipairs(attempts) do
    if attempt.status == 'resolved' then
      local normalized = {}
      for _, action in ipairs(attempt.actions or {}) do
        local ok, result = pcall(normalizeAction, action, active, false)
        if not ok then errors[#errors + 1] = tostring(attempt.path) .. ': ' .. tostring(result)
        elseif result then normalized[#normalized + 1] = result end
      end
      attempt.actions = normalized
    end
  end
  if #errors > 0 then return nil, errors end
  return attempts
end
return M
