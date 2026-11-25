-- Lower internal spatial choices to typed place_ref programs.
local M = {}
local authored_path = require('scripts.mom.compiler.authored_path')
local target_lowering = require('scripts.mom.compiler.target_lowering')
local direct_targets = require('scripts.mom.compiler.direct_targets')
local source_ir = require('scripts.mom.compiler.source_ir')
local selector_skip_report = require('scripts.mom.compiler.selector_skip_report')
local model_path = require('scripts.mom.contracts.model_path')
local model_lookup = require('scripts.mom.openmw.model_path')
local spatial = require('scripts.mom.domain.variation.spatial')
local plain_data = require('scripts.mom.contracts.plain_data')
local canonical = require('scripts.mom.contracts.canonical')
local ref_type = require('scripts.mom.contracts.ref_type')
local type_capabilities = require('scripts.mom.actions.place_ref.type_capabilities')
local tables = require('scripts.mom.common.tables')
local sortedKeys = tables.sortedKeys
local ALLOWED_TYPES = {Static = true, Activator = true, Container = true}
local SPLIT_GLOBAL_TYPES = require('scripts.mom.actions.place_ref.load').GLOBAL_RUNTIME_TYPES
local function intersectAllowed(types, mask)
  local out = {}
  for name, enabled in pairs(types or {}) do
    if enabled and mask[name] then out[name] = true end
  end
  return out
end
local RULE_FIELDS = {sourceKey = true, sourceKind = true, sourceTypes = true,
  targets = true, profile = true, keepStops = true, ignoreRecords = true, orderKey = true, priority = true}
local TARGET_FIELDS = {targetKind = true, targetValue = true}
local isInteger = require('scripts.mom.common.numbers').isInteger
local function validOptionalPriority(value)
  return value == nil or (isInteger(value) and value >= -2147483648 and value <= 2147483647)
end
local function array(value, nonEmpty)
  return tables.isArray(value) and (not nonEmpty or #value > 0)
end
local nonEmpty = require('scripts.mom.common.strings').isNonEmpty
local function knownFields(value, fields)
  if type(value) ~= 'table' then return false end
  for key in pairs(value) do if not fields[key] then return false end end
  return true
end
local function failure(path, message)
  return nil, {path .. ': ' .. message}
end
function M.prepare(input, queries, ctx)
  local actionId = authored_path.resolveActionId(type(input) == 'table' and input or {}, ctx, 'place_ref')
  local path = authored_path.authoredActionPath(ctx, actionId) .. '.choice'
  if type(input) ~= 'table' or input.verb ~= 'attach' or input.payloadKind ~= 'choice'
      or not knownFields(input.payload, {rules = true}) or not array(input.payload.rules, true) then
    return failure(path, 'expected non-empty internal choice rules')
  end
  if not knownFields(input.options, {disableOriginal = true, transferContents = true}) or input.options.disableOriginal ~= true then
    return failure(path, 'choice replacement requires disableOriginal')
  end
  if input.options.transferContents ~= nil and type(input.options.transferContents) ~= 'boolean' then
    return failure(path, 'transferContents must be boolean')
  end
  if input.select ~= nil and type(input.select) ~= 'table' then
    return failure(path, 'choice selection must be an object')
  end
  if input.select and (input.select.type ~= nil or input.select.recordId ~= nil) then
    return failure(path, 'choice selection only supports cell constraints')
  end
  queries = queries or {}
  queries.recordIds, queries.meshPathTypes = queries.recordIds or {}, queries.meshPathTypes or {}
  local prepared = {}
  for i, rule in ipairs(input.payload.rules) do
    local rulePath = path .. '.rules[' .. i .. ']'
    if not knownFields(rule, RULE_FIELDS) or not nonEmpty(rule.sourceKey)
        or (rule.sourceKind ~= 'record_id' and rule.sourceKind ~= 'model_path')
        or not nonEmpty(rule.orderKey) or type(rule.keepStops) ~= 'boolean'
        or not validOptionalPriority(rule.priority)
        or not array(rule.targets, true) or type(rule.sourceTypes) ~= 'table'
        or next(rule.sourceTypes) == nil or type(rule.ignoreRecords) ~= 'table' then
      return failure(rulePath, 'invalid source, types, ordering, or replacement targets')
    end
    for typeName, allowed in pairs(rule.sourceTypes) do
      if not ALLOWED_TYPES[typeName] or allowed ~= true then
        return failure(rulePath .. '.sourceTypes', 'unsupported replacement source type')
      end
    end
    for id, ignored in pairs(rule.ignoreRecords) do
      if not nonEmpty(id) or ignored ~= true then
        return failure(rulePath .. '.ignoreRecords', 'expected record-id set')
      end
    end
    local source = rule.sourceKind == 'model_path' and model_path.normalize(rule.sourceKey)
      or rule.sourceKey:lower()
    if source == nil then return failure(rulePath .. '.sourceKey', 'invalid model path') end
    local parsed = {sourceKeyKind = rule.sourceKind, sourceValue = source, rawKey = rule.sourceKey}
    local queryTypes = (ctx and ctx.loadDecision == 'split')
      and intersectAllowed(rule.sourceTypes, SPLIT_GLOBAL_TYPES)
      or rule.sourceTypes
    if next(queryTypes) ~= nil then
      target_lowering.collectParsedSelectorQuery(parsed, queries, {meshTypes = queryTypes})
    end
    local targets = {}
    for j, target in ipairs(rule.targets) do
      if not knownFields(target, TARGET_FIELDS) or not nonEmpty(target.targetValue)
          or (target.targetKind ~= 'record_id' and target.targetKind ~= 'model_path') then
        return failure(rulePath .. '.targets[' .. j .. ']', 'invalid replacement target')
      end
      local value = target.targetKind == 'model_path' and model_path.normalize(target.targetValue)
        or target.targetValue:lower()
      if value == nil then return failure(rulePath .. '.targets[' .. j .. ']', 'invalid target model path') end
      targets[j] = {targetKind = target.targetKind, targetValue = value}
      if target.targetKind == 'record_id' then queries.recordIds[value] = true end
    end
    local profile = rule.profile
    -- Common normalization owns compilation; this boundary checks its output.
    local profileValid, profileError = spatial.validate(profile, #targets)
    if not profileValid then return failure(rulePath .. '.profile', tostring(profileError)) end
    prepared[i] = {parsed = parsed, sourceTypes = rule.sourceTypes, targets = targets,
      profile = profile, keepStops = rule.keepStops, ignoreRecords = rule.ignoreRecords,
      priority = rule.priority, orderKey = rule.orderKey}
  end
  input.payload = {rules = prepared}
  return input, nil
end
local function targetType(recordCtx, id)
  local exists, reason = recordCtx.recordExists(id)
  if not exists then return nil, tostring(reason or 'invalid record id') end
  local typeName, err = recordCtx.resolveLiveRefType(id)
  if type(typeName) ~= 'string' or typeName == '' then
    return nil, typeName == false and 'ambiguous record type' or tostring(err or 'record is not placeable')
  end
  return typeName
end
local function resolvedTargets(rule, recordCtx, ctx, path, report)
  local targets = {}
  for i, target in ipairs(rule.targets) do
    local resolved = {targetKind = target.targetKind, targetValue = target.targetValue}
    local reason
    if target.targetKind == 'model_path' then
      local exists, _, err = (ctx.modelExists or model_lookup.modelExists)(target.targetValue)
      if not exists or err then reason = err and ('model lookup failed in VFS: ' .. tostring(err)) or 'model missing in VFS' end
    else
      resolved.targetType, reason = targetType(recordCtx, target.targetValue)
    end
    if reason then
      resolved.unavailable = true
      selector_skip_report.record(report, path .. '.targets[' .. i .. ']', target.targetValue,
        'replacement target', reason)
    end
    targets[i] = resolved
  end
  return targets
end
local function profileIndex(pool, profile, key)
  local indexes = pool.byKey[key]
  for _, index in ipairs(indexes or {}) do
    if plain_data.equalValidated(pool.values[index], profile) then return index end
  end
  local index = #pool.values + 1
  pool.values[index] = plain_data.cloneValidated(profile)
  if indexes == nil then indexes = {}; pool.byKey[key] = indexes end
  indexes[#indexes + 1] = index
  return index
end
function M.compile(spec, ctx)
  ctx = ctx or {}
  local actionId = authored_path.resolveActionId(spec, ctx, 'place_ref')
  local path = authored_path.authoredActionPath(ctx, actionId) .. '.choice'
  local recordCtx = target_lowering.requireRecordContext(ctx)
  local report = selector_skip_report.new({family = 'place_ref', actionId = actionId,
    verb = 'choice', diagnosticCollector = ctx.diagnosticCollector, sourcePath = ctx.sourcePath,
    code = 'place_selector_unresolved'})
  local byType, pools = {}, {}
  local isSplit = ctx.loadDecision == 'split'
  for i, rule in ipairs(spec.payload.rules) do
    local rulePath = path .. '.rules[' .. i .. ']'
    local effectiveTypes = isSplit and intersectAllowed(rule.sourceTypes, SPLIT_GLOBAL_TYPES) or rule.sourceTypes
    local inferred = next(effectiveTypes) ~= nil and target_lowering.resolveSelectorTypesOrSkip(rule.parsed, {
      recordCtx = recordCtx, path = rulePath .. '.source', allowedTypes = effectiveTypes,
      typeLabel = 'declared replacement source types',
      skipReport = not isSplit and report or nil,
      selectorLabel = 'source selector',
    }) or nil
    if inferred then
      local targets = resolvedTargets(rule, recordCtx, ctx, rulePath, report)
      local profileKey = canonical.assertHashValidated(rule.profile)
      local ruleProfileIndexes = {}
      local sourceIds = rule.parsed.sourceKeyKind == 'model_path'
        and recordCtx.resolveMeshTypes(rule.parsed.sourceValue) or nil
      for _, typeName in ipairs(sortedKeys(inferred)) do
        local ids = sourceIds and sourceIds[typeName] or {rule.parsed.sourceValue}
        for _, sourceId in ipairs(ids or {}) do
          sourceId = tostring(sourceId):lower()
          if not rule.ignoreRecords[sourceId] then
            local actualType = recordCtx.resolveLiveRefType(sourceId)
            if actualType == typeName then
              if typeName == 'Container' and spec.options.transferContents == false then
                return failure(rulePath, 'Container replacement requires preserving inventory; transferContents=false is unsupported')
              end
              local bucket = byType[typeName] or {}
              byType[typeName] = bucket
              pools[typeName] = pools[typeName] or {values = {}, byKey = {}}
              if ruleProfileIndexes[typeName] == nil then
                ruleProfileIndexes[typeName] = profileIndex(pools[typeName], rule.profile, profileKey)
              end
              local entry = bucket[sourceId]
              if entry == nil then
                entry = {sourceKeyKind = 'record_id', sourceRecordId = sourceId,
                  inferredType = typeName, position = {x = 0, y = 0, z = 0},
                  slot = 'r:' .. sourceId .. ':1', choices = {}}
                bucket[sourceId] = entry
              end
              entry.choices[#entry.choices + 1] = {
                targets = assert(plain_data.detach(targets)),
                profileIndex = ruleProfileIndexes[typeName],
                keepStops = rule.keepStops, orderKey = rule.orderKey, sourceKind = rule.parsed.sourceKeyKind,
                priority = rule.priority}
            else
              selector_skip_report.record(report, rulePath .. '.source', sourceId,
                'source selector', 'ambiguous or changed record type')
            end
          end
        end
      end
    end
  end
  selector_skip_report.flush(report)
  local outputs = {}
  for _, typeName in ipairs(sortedKeys(byType)) do
    local entries = {}
    for _, id in ipairs(sortedKeys(byType[typeName])) do
      local entry = byType[typeName][id]
      table.sort(entry.choices, function(a, b)
        local ap, bp = a.priority or 0, b.priority or 0
        if ap ~= bp then return ap > bp end
        if a.sourceKind ~= b.sourceKind then return a.sourceKind == 'record_id' end
        return a.orderKey < b.orderKey
      end)
      entries[#entries + 1] = entry
    end
    local program = {mode = 'relative', disableOriginal = true, choiceGroup = 'appearance',
      profiles = pools[typeName].values, objects = entries}
    local claims, claimError = type_capabilities.claimsForProgram(program)
    if claims == nil then return failure(path, claimError) end
    local compiled = source_ir.compiledSpec(spec)
    compiled.id = #outputs == 0 and actionId or (actionId .. ':' .. typeName:lower())
    compiled.program = program
    outputs[#outputs + 1] = source_ir.familyProgram(compiled, {claims = {keys = claims}, reversible = true,
      candidateTypes = {[typeName] = true},
      resolvedSelection = target_lowering.resolvedSelection(entries, spec.select or {}, recordCtx),
      directTargets = direct_targets.build(entries, {recordCtx = recordCtx})})
  end
  if #outputs == 0 and not isSplit then
    selector_skip_report.emitNoTargets(report, {path = path, code = 'choice_no_sources_resolved',
      reason = 'no replacement choice source selector resolved'})
  end
  return outputs, nil
end
local CHOICE_FIELDS = {targets = true, profileIndex = true, keepStops = true, orderKey = true, sourceKind = true, priority = true}
local RESOLVED_TARGET_FIELDS = {targetKind = true, targetValue = true, targetType = true, unavailable = true}
local function validateChoices(choices, variantCounts, usedProfiles)
  if not array(choices, true) then return nil, 'choices: expected non-empty dense array' end
  for i, choice in ipairs(choices) do
    local path = 'choices[' .. i .. ']'
    if not knownFields(choice, CHOICE_FIELDS) or not array(choice.targets, true)
        or type(choice.keepStops) ~= 'boolean' or not nonEmpty(choice.orderKey)
        or not validOptionalPriority(choice.priority)
        or (choice.sourceKind ~= 'model_path' and choice.sourceKind ~= 'record_id') then
      return nil, path .. ': invalid rule fields, source kind, or targets'
    end
    local index = choice.profileIndex
    if type(index) ~= 'number' or index % 1 ~= 0 or variantCounts[index] == nil then
      return nil, path .. '.profileIndex: expected an installed profile index'
    end
    if #choice.targets ~= variantCounts[index] then
      return nil, path .. '.profileIndex: profile weight count does not match replacement targets'
    end
    usedProfiles[index] = true
    for j, target in ipairs(choice.targets) do
      if not knownFields(target, RESOLVED_TARGET_FIELDS) or not nonEmpty(target.targetValue)
          or (target.targetKind ~= 'model_path' and target.targetKind ~= 'record_id')
          or (target.unavailable ~= nil and type(target.unavailable) ~= 'boolean') then
        return nil, path .. '.targets[' .. j .. ']: invalid target'
      end
      if target.targetKind == 'model_path' then
        if model_path.normalize(target.targetValue) ~= target.targetValue or target.targetType ~= nil then
          return nil, path .. '.targets[' .. j .. ']: invalid canonical model target'
        end
      elseif target.unavailable ~= true and not ref_type.contains(target.targetType) then
        return nil, path .. '.targets[' .. j .. ']: available record requires a resolved target type'
      elseif target.targetType ~= nil and not ref_type.contains(target.targetType) then
        return nil, path .. '.targets[' .. j .. ']: invalid resolved target type'
      end
    end
  end
  return true, nil
end
local CHOICE_PROGRAM_FIELDS = {mode = true, objects = true, disableOriginal = true,
  choiceGroup = true, profiles = true}
local ENTRY_FIELDS = {sourceKeyKind = true, sourceRecordId = true, inferredType = true,
  position = true, slot = true, choices = true}
function M.checkProgram(program)
  local plain, errors = plain_data.validate(program)
  if not plain then return nil, table.concat(errors or {}, ' | ') end
  if not knownFields(program, CHOICE_PROGRAM_FIELDS) or program.mode ~= 'relative'
      or program.disableOriginal ~= true or program.choiceGroup ~= 'appearance'
      or not array(program.objects, true) or not array(program.profiles, true) then
    return nil, 'expected relative appearance choices with disableOriginal, profiles and non-empty objects'
  end
  local variantCounts, usedProfiles = {}, {}
  for i, profile in ipairs(program.profiles) do
    local valid, reason = spatial.validate(profile)
    if not valid then return nil, 'profiles[' .. i .. ']: ' .. tostring(reason) end
    variantCounts[i] = #profile.default - 1
  end
  local seen = {}
  for i, entry in ipairs(program.objects) do
    local path = 'objects[' .. i .. ']'
    if not knownFields(entry, ENTRY_FIELDS) or entry.sourceKeyKind ~= 'record_id'
        or not nonEmpty(entry.sourceRecordId) or not ALLOWED_TYPES[entry.inferredType]
        or entry.slot ~= 'r:' .. entry.sourceRecordId .. ':1'
        or not knownFields(entry.position, {x = true, y = true, z = true})
        or entry.position.x ~= 0 or entry.position.y ~= 0 or entry.position.z ~= 0 then
      return nil, path .. ': invalid exact source, type, position, or slot'
    end
    local id = entry.sourceRecordId:lower()
    if seen[id] then return nil, path .. ': duplicate source record' end
    seen[id] = true
    local valid, err = validateChoices(entry.choices, variantCounts, usedProfiles)
    if not valid then return nil, path .. '.' .. err end
  end
  for index in ipairs(program.profiles) do
    if not usedProfiles[index] then return nil, 'profiles[' .. index .. ']: profile is not referenced' end
  end
  local claims, claimError = type_capabilities.claimsForProgram(program)
  if claims == nil then return nil, claimError end
  return true, nil
end
function M.validateProgram(program, errors, actionId, H)
  local valid, err = M.checkProgram(program)
  if not valid then H.appendError(errors, actionId, tostring(err)) end
end
return M
