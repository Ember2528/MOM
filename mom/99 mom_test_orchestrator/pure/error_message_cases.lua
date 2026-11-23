local M = {}

local error_message = require('scripts.mom.diagnostics.error_message')
local test_support = require('pure.test_support')
local expect = test_support.expect

local function scalarAndFallback()
  expect(error_message.message('plain failure') == 'plain failure',
    'scalar error message changed')
  expect(error_message.message(nil, 'boundary failed') == 'boundary failed',
    'nil error did not use its boundary fallback')
  expect(error_message.message({}, 'boundary failed') == 'boundary failed',
    'empty structured error did not use its boundary fallback')
end

local function arrayAndStructuredErrors()
  expect(
    error_message.message({
      'store_edit_changes_invalid',
      'editor did not return change metadata',
    }) == 'store_edit_changes_invalid: editor did not return change metadata',
    'array-shaped error lost ordered detail'
  )
  local message = error_message.message({
    code = 'outer_failure',
    path = 'runtime.tick',
    message = 'tick failed',
    errors = {{
      code = 'store_failure',
      message = 'commit was rejected',
    }},
  })
  expect(message == 'outer_failure at runtime.tick: tick failed: '
      .. 'store_failure: commit was rejected',
    'nested structured error lost code, path, or message detail')
end

local function nestedArrayObjectsNeverRenderAddresses()
  local message = error_message.message({
    code = 'aggregate',
    details = {message = 'nested detail'},
    error = {reason = 'nested cause'},
    errors = {
      {kind = 'first', reason = 'one'},
      {code = 'second', errors = {'two', 'three'}},
    },
  })
  expect(message == 'aggregate: first: one: second: two: three: '
      .. 'nested cause: nested detail'
      and message:find('table:', 1, true) == nil,
    'structured nested errors lost detail or exposed a Lua table address')
end

local CASES = {
  {'scalar and fallback', scalarAndFallback},
  {'array and structured errors', arrayAndStructuredErrors},
  {'nested arrays avoid table addresses', nestedArrayObjectsNeverRenderAddresses},
}

function M.run()
  return test_support.runCases('pure error message', CASES)
end

return M
