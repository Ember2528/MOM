-- Read-only appearance routing happens before claim arbitration. A selected
-- placement still uses the ordinary capture, mutation and recovery protocol.
local M = {}
local spatial = require('scripts.mom.domain.variation.spatial')
local matcher = require('scripts.mom.runtime.selection_matcher')
local predicate_index = require('scripts.mom.contracts.target_predicate_index')
local constantChoices = setmetatable({}, {__mode = 'k'})

local function constantChoice(profile)
  local selected = constantChoices[profile]
  if selected == nil then
    selected = spatial.constantChoice(profile)
    if selected == nil then selected = false end
    constantChoices[profile] = selected
  end
  return selected
end

local function lower(value)
  return value ~= nil and tostring(value):lower() or nil
end

local function spatialFacts(facts)
  local origin = facts.origin or {}
  return facts.currentCell or facts.cell or origin.cell,
    facts.position or facts.currentPosition or origin.position
end

local function addClimate(climates, seen, profile, cell, port, context)
  local id = spatial.region(profile, cell)
  if id == nil or id == '' or seen[id] then return true end
  seen[id] = true
  if type(port) ~= 'table' or type(port.readRegionClimate) ~= 'function' then return true end
  local ok, axes, reason = pcall(port.readRegionClimate, id, context)
  if not ok then return nil, 'regional climate read failed: ' .. tostring(axes) end
  if reason ~= nil then return nil, tostring(reason) end
  if axes ~= nil then climates[id] = axes end
  return true
end

local function selectRule(rule, profile, cell, position, climates, constant)
  local index = constant ~= false and constant or spatial.choose(profile, cell, position, climates)
  if index == 0 then return false, rule.keepStops end
  local target = rule.targets[index]
  if target == nil or target.unavailable then return false, true end
  return target, true
end

local function originCell(facts, port, context)
  local origin = facts.origin or {}
  if origin.cell ~= nil then return origin.cell end
  local current = facts.currentCell or facts.cell
  local id = lower(origin.cellId)
  if current and (id == nil or id == lower(current.key or current.id)
      or id == lower(current.idLower)) then return current end
  if id and type(port) == 'table' and type(port.resolveCell) == 'function' then
    local ok, raw, reason = pcall(port.resolveCell, id, context)
    if not ok then return nil, 'origin cell read failed: ' .. tostring(raw) end
    if raw == nil then return nil, reason or 'appearance origin cell is unavailable' end
    return matcher.normalizeCell(raw, 'appearance.origin.cell')
  end
  return nil, 'appearance source selection requires origin cell facts'
end

local function eligible(row, facts, port, context)
  local selection = row.action.selection or {}
  if selection.cell ~= nil then
    local cell, reason = originCell(facts, port, context)
    if cell == nil then return nil, reason end
    local matched, matchError = matcher.cellMatches(selection, cell)
    if matched ~= true then return matched, matchError end
  end
  for _, id in ipairs(selection.excludedIds or {}) do
    if lower(id) == lower(facts.recordId) then return false end
  end
  if selection.predicateIndex then return predicate_index.matches(selection.predicateIndex, facts) end
  return matcher.matchesPredicates(selection.predicates, facts)
end

-- Both discovery and initial capture resolve this same ordered route. Entry
-- rules also use this traversal for pure evaluation without action selection.
local function resolve(rows, facts, port, context, climates, profiles)
  local cell, position = spatialFacts(facts)
  climates = climates or {}
  local seen = {}
  for _, row in ipairs(rows) do
    local matched, matchError = true, nil
    if row.action ~= nil then matched, matchError = eligible(row, facts, port, context) end
    if matched == nil then return nil, matchError end
    if matched then
      local rule = row.rule or row
      local profile = row.profile or profiles[rule.profileIndex]
      local constant = constantChoice(profile)
      if constant == false then
        if cell == nil or position == nil then return nil, 'appearance choice requires cell and position facts' end
        local ok, reason = addClimate(climates, seen, profile, cell, port, context)
        if not ok then return nil, reason end
      end
      local target, stop = selectRule(rule, profile, cell, position, climates, constant)
      if stop then return target, nil, row end
    end
  end
  return false
end

-- Entry rules are already sorted during compilation. A record-specific KEEP
-- stops routing, while a mesh KEEP allows a later module to supply a choice.
function M.choose(entry, facts, climates, profiles)
  local target, reason, rule = resolve(entry.choices, facts, nil, nil, climates, profiles)
  if target == nil then return nil, reason end
  return target, rule
end

function M.chooseFromPort(entry, facts, port, context, profiles)
  local target, reason = resolve(entry.choices, facts, port, context, nil, profiles)
  return target, reason
end

local function routeKey(group, typeName, recordId)
  return group .. '\0' .. typeName .. '\0' .. lower(recordId)
end

local function before(left, right)
  if left.rule.sourceKind ~= right.rule.sourceKind then return left.rule.sourceKind == 'record_id' end
  if left.rule.orderKey ~= right.rule.orderKey then return left.rule.orderKey < right.rule.orderKey end
  if left.action.id ~= right.action.id then return left.action.id < right.action.id end
  return left.index < right.index
end

function M.prepareTargetFilters(actions)
  local routes, selected = {}, {}
  for _, action in ipairs(actions) do
    local program = action.program
    if program.choiceGroup ~= nil then
      assert(action.lifecycle == 'static', 'appearance choice only supports static actions')
      selected[#selected + 1] = action
      for _, entry in ipairs(program.objects) do
        local key = routeKey(program.choiceGroup, entry.inferredType, entry.sourceRecordId)
        local rows = routes[key] or {}
        routes[key] = rows
        for index, rule in ipairs(entry.choices) do
          constantChoice(program.profiles[rule.profileIndex])
          rows[#rows + 1] = {action = action, rule = rule, index = index,
            profile = program.profiles[rule.profileIndex]}
        end
      end
    end
  end
  for _, rows in pairs(routes) do table.sort(rows, before) end
  local filters = {}
  for _, action in ipairs(selected) do
    local actionId, group = action.id, action.program.choiceGroup
    filters[actionId] = function(facts, port, context)
      local rows = routes[routeKey(group, facts.typeName, facts.recordId)]
      if rows == nil then return false end
      local target, reason, row = resolve(rows, facts, port, context)
      if target == nil then return nil, reason end
      local selected = target ~= false and row.action.id == actionId
      -- Discovery consumes the boolean; capture consumes the same concrete
      -- target after rechecking the global winner with fresh physical facts.
      return selected, nil, selected and target or nil
    end
  end
  return filters
end

return M
