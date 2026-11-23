local repoRoot = assert(arg[1], 'repository root argument is required')
local resultFile = assert(arg[2], 'result file argument is required')
local samples = tonumber(arg[3] or '1')
local warmups = tonumber(arg[4] or '1')
local memoryArgument = assert(arg[5], 'memory evidence argument is required')
assert(memoryArgument == '0' or memoryArgument == '1',
  'memory evidence argument must be 0 or 1')
local memoryEvidence = memoryArgument == '1'
local executableSha256 = assert(arg[6],
  'Lua executable SHA-256 argument is required')
assert(#executableSha256 == 64
    and executableSha256:find('[^0-9a-f]') == nil,
  'Lua executable SHA-256 argument is invalid')
local selectedIds = {}
for i = 7, #arg do selectedIds[#selectedIds + 1] = arg[i] end

package.path = table.concat({
  repoRoot .. '/mom/00 OpenMW/?.lua',
  repoRoot .. '/mom/99 mom_test_orchestrator/?.lua',
  package.path,
}, ';')

local cases = require('scripts.mom_test_orchestrator.performance.cases.algorithmic')
local protocol = require('scripts.mom_test_orchestrator.performance.protocol')
local runner = require('scripts.mom_test_orchestrator.performance.runner')
local unsafe_runtime = require('scripts.mom_test_orchestrator.performance.unsafe_runtime')

local runtime = unsafe_runtime.standalone({
  executableSha256 = executableSha256,
})
local session = runner.new({
  runtime = runtime,
  cases = cases,
  mode = 'standalone',
  selectedIds = #selectedIds > 0 and selectedIds or nil,
  samples = assert(samples, 'invalid sample count'),
  warmups = assert(warmups, 'invalid warmup count'),
  memoryEvidence = memoryEvidence,
})
local report = session:runAll()
protocol.write(runtime, resultFile, report)

local idWidth = 31
for i = 1, #report.results do
  idWidth = math.max(idWidth, #report.results[i].id)
end
local resultFormat = '%-' .. tostring(idWidth) .. 's'
for i = 1, #report.results do
  local result = report.results[i]
  local sample = result.samples[#result.samples]
  if sample then
    io.stdout:write(string.format(resultFormat .. ' %9.1f us/op [%s]\n',
      result.id,
      sample.elapsedSeconds * 1000000 / sample.operations,
      result.status))
  else
    io.stdout:write(string.format(
      resultFormat .. ' %s\n',
      result.id,
      result.status
    ))
  end
end
io.stdout:write('MOM raw performance result: ' .. resultFile .. '\n')
-- Process status describes whether the standalone lane published its complete
-- machine report. Workload failure/invalidity remains authoritative in that
-- report and is applied by the host summary, matching the embedded lane.
