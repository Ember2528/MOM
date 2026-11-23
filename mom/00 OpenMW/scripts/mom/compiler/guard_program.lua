-- Compiles lowered guard specs into versioned plain-data programs.
-- The runtime evaluates these programs.
local M = {}

local guard_plugin_api = require('scripts.mom.contracts.guard_plugin')
local plain_data = require('scripts.mom.contracts.plain_data')

local GUARD_ENV = {
  guardEvent = guard_plugin_api.guardEvent,
}

local function sortedUniqueStrings(values, path)
  local seen = {}
  local out = {}
  for i = 1, #(values or {}) do
    local value = values[i]
    if type(value) ~= 'string' or value == '' then
      return nil, {path .. '[' .. tostring(i) .. ']: expected non-empty string'}
    end
    if not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end
  table.sort(out)
  return out, nil
end

function M.compile(guardSpecs, guardId, registry)
  local path = 'guard:' .. tostring(guardId) .. '.when'
  if type(guardSpecs) ~= 'table' then return nil, nil, {path .. ': expected array'} end
  if #guardSpecs == 0 then return nil, nil, {path .. ': expected at least one guard'} end

  local fragments = {}
  local subscriptions = {}
  for i = 1, #guardSpecs do
    local spec = guardSpecs[i]
    local family = type(spec) == 'table' and spec.type or nil
    local entry = family and registry and registry.byId and registry.byId[family] or nil
    if not entry then
      return nil, nil, {path .. '[' .. tostring(i) .. ']: unknown guard family ' .. tostring(family)}
    end
    local compileProgram = entry.module and entry.module.compileProgram or nil
    if type(compileProgram) ~= 'function' then
      return nil, nil, {path .. '[' .. tostring(i) .. ']: guard family is missing compileProgram()'}
    end
    local sourceProgram, sourceErrors = plain_data.detach(spec, {
      path = path .. '[' .. tostring(i) .. ']',
    })
    if not sourceProgram then return nil, nil, sourceErrors end
    local okCompile, compiled = pcall(compileProgram, sourceProgram, GUARD_ENV)
    if not okCompile then
      return nil, nil, {path .. '[' .. tostring(i) .. ']: guard compile failed: ' .. tostring(compiled)}
    end
    if type(compiled) ~= 'table' or type(compiled.program) ~= 'table' then
      return nil, nil, {path .. '[' .. tostring(i) .. ']: compileProgram() must return a program table'}
    end
    local program, programErrors = plain_data.detach(compiled.program, {
      path = path .. '[' .. tostring(i) .. '].program',
    })
    if not program then return nil, nil, programErrors end
    fragments[#fragments + 1] = {
      family = family,
      abiVersion = entry.abiVersion,
      behaviorVersion = entry.behaviorVersion,
      programVersion = entry.programVersion,
      program = program,
    }
    for j = 1, #(compiled.subscriptions or {}) do
      subscriptions[#subscriptions + 1] = compiled.subscriptions[j]
    end
  end

  local normalizedSubscriptions, subscriptionErrors = sortedUniqueStrings(
    subscriptions,
    'guard:' .. tostring(guardId) .. '.subscriptions'
  )
  if not normalizedSubscriptions then return nil, nil, subscriptionErrors end
  local guard = {op = 'all', fragments = fragments}
  local ok, errors = plain_data.validate(guard, {path = 'guard:' .. tostring(guardId)})
  if not ok then return nil, nil, errors end
  return guard, normalizedSubscriptions, nil
end

return M
