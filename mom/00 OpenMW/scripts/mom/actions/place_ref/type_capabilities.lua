-- Pure source-type contract for relative place_ref replacement.
local M = {}

local ref_type_contract = require('scripts.mom.contracts.ref_type')
local ref_position = require('scripts.mom.domain.ref.position')

local POLICIES = {
  Static = {
    kind = 'base-record-only',
  },
  Activator = {
    kind = 'base-record-only',
    requiresScriptless = true,
  },
  Container = {
    kind = 'transferable',
    transferKind = 'container',
    requiresScriptless = true,
    requiredClaims = {'ref.inventory', 'ref.lock'},
  },
  Light = {
    kind = 'unsupported',
    reason = 'Light is item-bearing and place_ref has no item-data transfer',
  },
  Door = {
    kind = 'unsupported',
    reason = 'Door destination and runtime state cannot be reconstructed safely',
  },
  NPC = {
    kind = 'unsupported',
    reason = 'actors cannot be cloned by place_ref',
  },
  Creature = {
    -- Mesh variants copy the base record into a fresh actor instance. They
    -- do not transfer inventory, AI, or script state from the original actor.
    kind = 'creature-model',
  },
}

local function copyPolicy(policy, typeName)
  local out = {typeName = typeName}
  for key, value in pairs(policy) do
    if type(value) == 'table' then
      local values = {}
      for i = 1, #value do values[i] = value[i] end
      out[key] = values
    else
      out[key] = value
    end
  end
  return out
end

local function unsupported(typeName)
  local reason = ref_type_contract.contains(typeName)
    and (tostring(typeName) .. ' has per-ref item or runtime state without a transfer contract')
    or ('unknown source type ' .. tostring(typeName))
  return {typeName = typeName, kind = 'unsupported', reason = reason}
end

function M.classify(typeName)
  local policy = POLICIES[typeName]
  if policy == nil then return unsupported(typeName) end
  return copyPolicy(policy, typeName)
end

function M.selectorTypes()
  local out = {}
  local names = ref_type_contract.names()
  for i = 1, #names do out[names[i]] = true end
  return out
end

local function replacementTargetType(entry, sourceType)
  if entry.targetKind == 'model_path' then return sourceType end
  if type(entry.targetType) ~= 'string' or entry.targetType == '' then
    return nil, 'replacement target type is unavailable'
  end
  return entry.targetType, nil
end

-- Enforce this policy both during compilation and at the physical adapter
-- boundary. Filters are not proof that two output rows cannot hit one actor.
-- Distinct starting-position keys, however, select disjoint physical sources.
function M.validateCreatureSources(program)
  if type(program) ~= 'table' then return nil, 'place_ref program is invalid' end
  if program.mode ~= 'relative' then return true, nil end
  if type(program.objects) ~= 'table' then
    return nil, 'place_ref object program is invalid'
  end
  local sources = {}
  for _, entry in ipairs(program.objects or {}) do
    if type(entry) == 'table' and entry.inferredType == 'Creature' then
      if program.disableOriginal ~= true then
        return nil, 'place_ref Creature mesh replacement requires disableOriginal'
      end
      if entry.choices ~= nil or entry.targetKind ~= 'model_path' then
        return nil, 'place_ref Creature sources support only a single mesh replacement target'
      end
      local source = entry.sourceRecordId
      if type(source) ~= 'string' or source == '' then
        return nil, 'place_ref Creature source record is unavailable'
      end
      source = source:lower()
      local positionKey
      if entry.sourcePosition ~= nil then
        positionKey = ref_position.keyForPosition(entry.sourcePosition)
        if positionKey == nil then
          return nil, 'place_ref Creature source position is invalid'
        end
      end
      if program.inheritedAnchor == true then
        -- Inherited fast-path rows all receive the same physical anchor;
        -- authored selector-looking fields do not make them disjoint.
        source, positionKey = 'inherited', nil
      end
      local seen = sources[source]
      if seen ~= nil then
        if positionKey == nil or seen.broadcast or seen.positions[positionKey] then
          return nil, 'place_ref Creature source may produce only one mesh replacement output'
        end
      else
        seen = {positions = {}}
        sources[source] = seen
      end
      if positionKey == nil then seen.broadcast = true
      else seen.positions[positionKey] = true end
    end
  end
  return true, nil
end

function M.claimsForProgram(program)
  local claims = {['output.existence'] = true}
  if type(program) ~= 'table' or (program.mode ~= 'absolute' and program.mode ~= 'relative') then
    return nil, 'place_ref program mode is invalid'
  end
  if program.mode == 'absolute' then return {'output.existence'}, nil end
  local creatureValid, creatureError = M.validateCreatureSources(program)
  if not creatureValid then return nil, creatureError end
  if program.disableOriginal == true then claims['ref.enabled'] = true end

  local containerSources = {}
  for i = 1, #(program.objects or {}) do
    local entry = program.objects[i]
    local sourceType = type(entry) == 'table' and entry.inferredType or nil
    if type(sourceType) ~= 'string' or sourceType == '' then
      return nil, 'place_ref relative source type envelope is unavailable'
    end
    local policy = M.classify(sourceType)
    if policy.kind == 'unsupported' then
      return nil, 'place_ref source type ' .. sourceType .. ' is unsupported: ' .. policy.reason
    end
    if policy.kind == 'transferable' then
      if program.disableOriginal ~= true then
        return nil, 'place_ref ' .. sourceType .. ' transfer requires disableOriginal'
      end
      local targets = entry.choices ~= nil and {} or {entry}
      if entry.choices ~= nil then
        for _, choice in ipairs(entry.choices) do
          for _, target in ipairs(choice.targets or {}) do targets[#targets + 1] = target end
        end
      end
      for _, target in ipairs(targets) do
        if target.unavailable ~= true then
          local targetType, targetError = replacementTargetType(target, sourceType)
          if targetType == nil then return nil, targetError end
          if targetType ~= sourceType then
            return nil, 'place_ref ' .. sourceType .. ' transfer requires a ' .. sourceType .. ' output'
          end
        end
      end
      local sourceKey = tostring(entry.sourceRecordId or '')
      if sourceKey == '' then return nil, 'place_ref transferable source record is unavailable' end
      if containerSources[sourceKey] then
        return nil, 'place_ref container source may produce only one transfer output'
      end
      containerSources[sourceKey] = true
      for j = 1, #(policy.requiredClaims or {}) do claims[policy.requiredClaims[j]] = true end
    end
  end

  local out = {}
  for claim in pairs(claims) do out[#out + 1] = claim end
  table.sort(out)
  return out, nil
end

return M
