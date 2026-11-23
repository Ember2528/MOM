local I = require('openmw.interfaces')
local world = require('openmw.world')
local definitions = require('scripts.mom_test_orchestrator.performance.integration_definitions')

local function mom()
  local interface = I and I.MOM or nil
  assert(interface ~= nil, 'MOM public interface is unavailable')
  return interface
end

local execute = {}

execute.integration_loaded_cell_scan = function(measure)
  local player = assert(world.players and world.players[1], 'player is unavailable')
  local cell = assert(player.cell, 'player cell is unavailable')
  local cellId = tostring(cell.id)
  return measure(function()
    local total = 0
    for _ = 1, 25 do total = total + #assert(cell:getAll()) end
    assert(total > 0, 'loaded player cell unexpectedly contained no objects')
    return 'cell=' .. cellId .. ';nonempty=true'
  end)
end

execute.integration_selfcheck = function(measure)
  local interface = mom()
  return measure(function()
    local report
    for _ = 1, 5 do report = assert(interface.selfcheck()) end
    assert(report.ok == true and report.status == 'running',
      'public selfcheck did not report a healthy runtime')
    return 'manifest=' .. tostring(report.runtime.manifestHash)
  end)
end

execute.integration_compile_report = function(measure)
  local interface = mom()
  return measure(function()
    local report
    for _ = 1, 20 do report = assert(interface.compileReport({log = false})) end
    assert(report.status == 'running' and type(report.activeManifestHash) == 'string',
      'compile report did not describe the active candidate')
    return 'manifest=' .. report.activeManifestHash
  end)
end

for i = 1, #definitions do
  local definition = definitions[i]
  definition.execute = assert(execute[definition.id],
    'integration workload implementation missing: ' .. definition.id)
end

function definitions.ready()
  local player = world.players and world.players[1] or nil
  if player == nil or player.cell == nil then return false end
  local interface = I and I.MOM or nil
  if interface == nil or type(interface.selfcheck) ~= 'function' then return false end
  local ok, report = pcall(interface.selfcheck)
  return ok and type(report) == 'table' and report.ok == true and report.status == 'running'
end

return definitions
