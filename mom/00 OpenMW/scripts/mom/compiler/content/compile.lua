-- Action-driven LOAD backend: invokes each selected action module's own
-- `compileLoad(action, loadCtx)` and hands the resulting nodes to planner.lua.
local M = {}
local planner = require('scripts.mom.compiler.content.planner')
local schema = require('scripts.mom.compiler.content.schema')
local model_path = require('scripts.mom.contracts.model_path')
local composition = require('scripts.mom.contracts.composition_order')

local BUILTIN_FALLBACK = {
  record_content = 'scripts.mom.actions.record_content',
  leveled_content = 'scripts.mom.actions.leveled_content',
  place_ref = 'scripts.mom.actions.place_ref',
}
local fallbackCache = {}

local function actionModule(family, registry)
  local entry = registry and registry.byId and registry.byId[family] or nil
  if entry and type(entry.module) == 'table' then return entry.module end
  if fallbackCache[family] ~= nil then return fallbackCache[family] or nil end
  local moduleName = BUILTIN_FALLBACK[family]
  if moduleName then
    local mod = require(moduleName)
    fallbackCache[family] = mod
    return mod
  end
  fallbackCache[family] = false
  return nil
end

local read = schema.lookup

local function resolver(content, metrics)
  local indexes = {}
  local function meshIndex(typeName)
    if indexes[typeName] then return indexes[typeName] end
    local records, err = schema.store(content, typeName)
    if not records then return nil, err end
    local out, seen = {}, {}
    local function append(record, key)
      local rawId, idError = read(record, 'id')
      if idError then error(idError, 0) end
      local id = schema.id(rawId or (type(key) == 'string' and key))
      if not id then error('source record ID is unavailable', 0) end
      if seen[id] then return end
      seen[id] = true
      local rawModel, modelError = read(record, 'model')
      if modelError or type(rawModel) ~= 'string' then
        error(modelError or 'source model is unavailable', 0)
      end
      local model = rawModel ~= '' and model_path.normalize(rawModel)
      if model then
        local bucket = out[model] or {}
        bucket[#bucket + 1] = {type = typeName, id = id, record = record}
        out[model] = bucket
      end
    end
    local ok, failure = pcall(function()
      if #records > 0 then
        for i = 1, #records do append(records[i], i) end
      else
        for key, record in pairs(records) do append(record, key) end
      end
    end)
    if not ok then return nil, tostring(failure) end
    for _, rows in pairs(out) do table.sort(rows, function(a, b) return a.id < b.id end) end
    indexes[typeName] = out
    metrics.recordCatalogScans[typeName] = (metrics.recordCatalogScans[typeName] or 0) + 1
    return out
  end

  return function(parsed, types, lookupOpts)
    lookupOpts = lookupOpts or {}
    metrics.recordQueries = metrics.recordQueries + 1
    local names, targets = {}, {}
    for name in pairs(types) do names[#names + 1] = name end
    table.sort(names)
    if #names == 0 then return nil, 'source type restrictions have an empty intersection' end
    for _, name in ipairs(names) do
      if parsed.sourceKeyKind == 'model_path' then
        local index, err = meshIndex(name)
        if not index then
          if not lookupOpts.allowEmpty then return nil, err end
        else
          for _, value in ipairs(index[parsed.sourceValue] or {}) do
            targets[#targets + 1] = value
          end
        end
      else
        local records, err = schema.store(content, name)
        if not records then
          if not lookupOpts.allowEmpty then return nil, err end
        else
          local value, failure = read(records, parsed.sourceValue)
          if failure then return nil, failure end
          if value ~= nil then
            targets[#targets + 1] = {type = name, id = parsed.sourceValue, record = value}
          end
        end
      end
    end
    if #targets == 0 then
      if lookupOpts.allowEmpty then return targets end
      return nil, 'source matches no LOAD records'
    end
    if parsed.sourceKeyKind == 'record_id' and #targets ~= 1 then
      return nil, 'source record type is ambiguous'
    end
    return targets
  end
end

local function compile(aggregated, options)
  options = options or {}
  if type(aggregated) ~= 'table' or not schema.array(aggregated.sourceAttempts) then
    return nil, {'LOAD backend requires selected sourceAttempts'}
  end
  local nodes, errors, skipped = {}, {}, {}
  local metrics = {recordCatalogScans = {}, recordQueries = 0, modelActions = 0, skippedCount = 0}
  local content = options.content or {}
  local registry = options.actionRegistry
  local lookup = resolver(content, metrics)
  local function skipTarget(path, failure)
    metrics.skippedCount = metrics.skippedCount + 1
    if #skipped < 8 then
      skipped[#skipped + 1] = {
        severity = 'warn',
        code = 'optional_target_unavailable',
        message = path .. ': ' .. failure,
      }
    end
  end
  local actions = {}
  for _, attempt in ipairs(aggregated.sourceAttempts) do
    local path = tostring(attempt.sourcePath or attempt.path or '<source>')
    if attempt.status ~= 'resolved' then
      errors[#errors + 1] = path .. ': '
        .. tostring(attempt.error and attempt.error.message or 'source preparation failed')
    else
      for _, action in ipairs(attempt.actions or {}) do
        local valid, failure = composition.validate(action.compositionOrder, path .. '.compositionOrder')
        if not valid then
          errors[#errors + 1] = failure
        else
          actions[#actions + 1] = {
            action = action,
            source = path,
            compositionOrder = action.compositionOrder,
            priority = action.priority,
            order = #actions + 1,
          }
        end
      end
    end
  end
  if #errors > 0 then return nil, errors end
  table.sort(actions, composition.less)
  local orderCounter = 0
  local function nextOrder()
    orderCounter = orderCounter + 1
    return orderCounter
  end
  for _, entry in ipairs(actions) do
    local action, path = entry.action, entry.source
    local source = path .. ':' .. tostring(action.diagnosticId or (#nodes + 1))
    local mod = actionModule(action.family, registry)
    if mod == nil or type(mod.compileLoad) ~= 'function' then
      errors[#errors + 1] = source .. ': unexpected family in selected LOAD declarations'
    else
      if mod.execution ~= 'load' then
        metrics.modelActions = metrics.modelActions + 1
      end
      local resolved, failure = mod.compileLoad(action, {
        content = content,
        source = source,
        lookup = lookup,
        skipTarget = skipTarget,
        nextOrder = nextOrder,
        decision = action.loadDecision,
      })
      if not resolved then
        errors[#errors + 1] = failure
      else
        for _, node in ipairs(resolved) do
          nodes[#nodes + 1] = node
        end
      end
    end
  end
  if #errors > 0 then return nil, errors end
  local plan, invalid = planner.compile(nodes, options)
  if not plan then return nil, invalid end
  plan.metrics.recordCatalogScans = metrics.recordCatalogScans
  plan.metrics.recordQueries = metrics.recordQueries
  plan.metrics.modelActions = metrics.modelActions
  plan.metrics.skippedCount = metrics.skippedCount
  for _, diagnostic in ipairs(skipped) do plan.diagnostics[#plan.diagnostics + 1] = diagnostic end
  return plan
end

function M.compile(aggregated, options)
  local ok, plan, errors = pcall(compile, aggregated, options)
  if not ok then return nil, {'LOAD compilation failed: ' .. tostring(plan)} end
  return plan, errors
end

return M
