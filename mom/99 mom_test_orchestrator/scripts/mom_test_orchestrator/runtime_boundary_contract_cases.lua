local M = {}
local openmw_api = require('scripts.mom.openmw.api')

local function expect(condition, message)
  if not condition then error(message or 'runtime boundary assertion failed', 2) end
end

local function expectOnlyKeys(value, allowed, label)
  for key in pairs(value or {}) do
    expect(allowed[key] == true, tostring(label) .. ' exposed unexpected key ' .. tostring(key))
  end
end

function M.runAll(interface)
  expect(openmw_api.isNamespace(interface), 'MOM public interface is unavailable')
  expect(interface.version == 0, 'MOM public interface version is not 0')
  for _, method in ipairs({'selfcheck', 'compileReport', 'logLevel'}) do
    expect(type(interface[method]) == 'function', 'MOM public interface is missing ' .. method)
  end

  local before = interface.selfcheck()
  expect(before and before.ok == true and before.status == 'running',
    'App is not running at the public boundary')
  expectOnlyKeys(before, {
    ok = true,
    status = true,
    frame = true,
    activeManifestHash = true,
    ledger = true,
    manifest = true,
    runtime = true,
    runtimeError = true,
    load = true,
    compile = true,
    lastError = true,
    limit = true,
    startup = true,
  }, 'selfcheck')
  expect(before.startup and before.startup.status == 'ready'
      and type(before.startup.sourceHash) == 'string'
      and #before.startup.message <= 2048
      and before.startup.targets == nil and before.startup.actions == nil,
    'public selfcheck omitted bounded LOAD status or leaked compiler input')
  expect(before.ledger and before.ledger.ok == true,
    'schema-0 ledger failed public selfcheck')
  expect(before.manifest and before.manifest.ok == true,
    'manifest failed public selfcheck')
  expect(before.runtime and before.runtime.manifestHash == before.activeManifestHash
      and before.runtime.blockers and type(before.runtime.blockers.count) == 'number'
      and #before.runtime.blockers.samples <= before.runtime.limit,
    'public selfcheck omitted bounded operational runtime status')

  local compile = interface.compileReport({log = false})
  local summary = compile and compile.summary or nil
  expect(compile and compile.status == 'running' and type(compile.activeManifestHash) == 'string',
    'compile report does not describe the active startup candidate')
  expectOnlyKeys(compile, {
    status = true,
    activeManifestHash = true,
    active = true,
    summary = true,
    lastError = true,
    diagnosticsTruncated = true,
    limit = true,
    startup = true,
  }, 'compile report')
  expect(compile.startup and compile.startup.sourceHash == before.startup.sourceHash,
    'public reports disagree about LOAD input')
  expect(summary and summary.manifest
      and summary.manifest.contentHash == compile.activeManifestHash,
    'compile report manifest identity is inconsistent')

  local quarantined = false
  for _, row in ipairs(summary.diagnostics.samples or {}) do
    if row.code == 'extension_require_failed'
        and tostring(row.sourcePath):find('broken_unused_fixture.lua', 1, true) then
      quarantined = true
    end
  end
  expect(quarantined, 'dynamic discovery did not report the unused broken extension')

  local after = interface.selfcheck()
  expect(after and after.ok == true and after.status == 'running',
    'support reads damaged the active runtime')
end

return M
