local openmw_api = require('scripts.mom.openmw.api')

local M = {}

local test_support = require('pure.test_support')
local expect = test_support.expect

local function dependencyContract()
  local injected = {}
  local value, err = openmw_api.dependency({world = injected}, 'world', 'missing.world')
  expect(value == injected and err == nil, 'injected OpenMW dependency was not preserved')

  value, err = openmw_api.dependency({}, 'world', 'mom.missing_openmw_dependency')
  expect(value == nil and type(err) == 'string',
    'missing OpenMW dependency did not preserve require diagnostics')
end

local function protectedReadContract()
  local first, second, third = openmw_api.call(function(value)
    return value, 'second', 'third'
  end, 'first')
  expect(first == 'first' and second == 'second' and third == 'third',
    'protected OpenMW call did not preserve return values')

  local value, err = openmw_api.call(function() error('call failed', 0) end)
  expect(value == nil and tostring(err):find('call failed', 1, true),
    'protected OpenMW call did not preserve thrown diagnostics')

  value, err = openmw_api.property(setmetatable({}, {
    __index = function() error('property failed', 0) end,
  }), 'value')
  expect(value == nil and tostring(err):find('property failed', 1, true),
    'protected OpenMW property read did not preserve diagnostics')
end

local function labeledReadContract()
  local value, err = openmw_api.readCall(function() return false, 'ignored' end, 'read')
  expect(value == false and err == nil, 'false OpenMW read was treated as failure')

  value, err = openmw_api.readCall(function() return nil, 'unknown' end, 'read')
  expect(value == nil and err == 'unknown', 'OpenMW read failure reason was lost')

  value, err = openmw_api.readCall(nil, 'Actor.read')
  expect(value == nil and err == 'Actor.read is unavailable',
    'missing OpenMW read did not use its capability label')
end

local function mutationContract()
  local ok, err = openmw_api.invoke(function() end, 'Object.write')
  expect(ok == true and err == nil, 'nil OpenMW mutation result was not accepted')

  ok, err = openmw_api.invoke(function() return false end, 'Object.write')
  expect(ok == nil and err == 'Object.write failed',
    'false OpenMW mutation result was not rejected')

  ok, err = openmw_api.invoke(function() return nil, 'denied' end, 'Object.write')
  expect(ok == nil and err == 'denied', 'OpenMW mutation failure reason was lost')
end

local CASES = {
  {'dependency contract', dependencyContract},
  {'protected read contract', protectedReadContract},
  {'labeled read contract', labeledReadContract},
  {'mutation contract', mutationContract},
}

function M.run()
  return test_support.runCases('OpenMW API support', CASES)
end

return M
