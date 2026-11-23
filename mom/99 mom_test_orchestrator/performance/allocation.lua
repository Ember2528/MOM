local repoRoot = assert(arg[1], 'repository root argument is required')
local resultFile = assert(arg[2], 'result file argument is required')
local executableSha256 = assert(arg[3],
  'Lua executable SHA-256 argument is required')
local workloadId = assert(arg[4],
  'allocation workload id is required')
assert(arg[5] == nil,
  'allocation probe requires exactly one workload')
assert(#executableSha256 == 64
    and executableSha256:find('[^0-9a-f]') == nil,
  'Lua executable SHA-256 argument is invalid')

package.path = table.concat({
  repoRoot .. '/mom/00 OpenMW/?.lua',
  repoRoot .. '/mom/99 mom_test_orchestrator/?.lua',
  package.path,
}, ';')

local allocation_probe = require(
  'scripts.mom_test_orchestrator.performance.allocation_probe'
)
local cases = require(
  'scripts.mom_test_orchestrator.performance.cases.algorithmic'
)
local protocol = require(
  'scripts.mom_test_orchestrator.performance.protocol'
)
local unsafe_runtime = require(
  'scripts.mom_test_orchestrator.performance.unsafe_runtime'
)

local runtime = unsafe_runtime.standalone({
  executableSha256 = executableSha256,
})
local report = allocation_probe.run({
  runtime = runtime,
  cases = cases,
  id = workloadId,
})
protocol.write(runtime, resultFile, report)

io.stdout:write(
  string.format(
    'MOM allocation probe %-31s [%s]\n',
    workloadId,
    report.status
  )
)
io.stdout:write('MOM allocation result: ' .. resultFile .. '\n')
