-- Compatibility facade over the action-driven LOAD planner (`load_planner.lua`).
local M = {}

local authored = require('scripts.mom.compiler.authored_contract')
local intent = require('scripts.mom.compiler.authored_intent')
local planner = require('scripts.mom.compiler.load_planner')
local tables = require('scripts.mom.common.tables')

local function hasDefinition(action)
  if type(action) ~= 'table' then return false end
  if action.record ~= nil or action.leveled ~= nil then return true end
  for _, child in ipairs(type(action.actions) == 'table' and action.actions or {}) do
    if hasDefinition(child) then return true end
  end
  return false
end

function M.classify(action, opts)
  opts = opts or {}
  if opts.guarded or opts.isChild then
    if hasDefinition(action) then
      return nil, 'record/list definitions cannot be guarded or be children'
    end
    return 'GLOBAL'
  end
  local kind, err = intent.verb(action)
  if not kind then return nil, err end
  local family = authored.actionKindForVerb(kind)
  local node = {
    family = family,
    spec = action,
    guardOwner = opts.guarded and true or nil,
    conflict = opts.conflict,
    children = opts.hasChildren and {{}} or {},
  }
  if kind == 'record' or kind == 'leveled' then
    local mod = kind == 'record'
      and require('scripts.mom.actions.record_content')
      or require('scripts.mom.actions.leveled_content')
    local desc, descErr = mod.analyzeLoad(node, opts)
    if not desc then return nil, descErr end
    return 'LOAD'
  end
  if opts.conflict ~= nil then return 'GLOBAL' end
  if opts.hasChildren or (action.actions ~= nil
      and not (tables.isArray(action.actions) and #action.actions == 0)) then
    for _, child in ipairs(type(action.actions) == 'table' and action.actions or {}) do
      if hasDefinition(child) then return nil, 'record/list definitions cannot be children' end
    end
    return 'GLOBAL'
  end
  if kind == 'attach' then
    local placeLoad = require('scripts.mom.actions.place_ref.load')
    local desc = placeLoad.analyzeLoad(node, opts)
    if desc then return desc.mode == 'split' and 'SPLIT' or 'LOAD' end
  end
  return 'GLOBAL'
end

M.semantic = planner.semantic
M.plan = planner.plan
M.applyDecisions = planner.applyDecisions
M.select = planner.select
M.phase = planner.phase
M.encodeDecisions = planner.encodeDecisions
M.decodeDecisions = planner.decodeDecisions

return M
