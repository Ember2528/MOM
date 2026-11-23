local repoRoot = assert(arg[1], 'repository root argument is required')

package.path = table.concat({
  repoRoot .. '/mom/00 OpenMW/?.lua',
  repoRoot .. '/mom/99 mom_test_orchestrator/?.lua',
  package.path,
}, ';')

local test_support = require('pure.test_support')
assert(arg[2] == nil or arg[2] == '--stress' or arg[2] == '--stress-only',
  'usage: run_pure_tests.sh [--stress|--stress-only]')
assert(arg[3] == nil, 'usage: run_pure_tests.sh [--stress|--stress-only]')
test_support.stressOnly = arg[2] == '--stress-only'
test_support.stress = arg[2] == '--stress' or test_support.stressOnly

local suites = require('pure.suite_catalog')

local total = 0
for i = 1, #suites do
  total = total + suites[i].run()
end

assert(not test_support.stressOnly or total > 0, 'stress-only suite selected no cases')
print(string.format('MOM pure contract tests passed: %d case(s)', total))
