-- Exercise discovery, compilation and App activation together. Only OpenMW
-- inputs, extension fixtures and the app-facing engine session are supplied.
local M = {}

package.preload['openmw.core'] = package.preload['openmw.core'] or function()
  return {contentFiles = {list = {}}}
end
package.preload['openmw.vfs'] = package.preload['openmw.vfs'] or function()
  return {}
end
package.preload['openmw.markup'] = package.preload['openmw.markup'] or function()
  return {}
end
package.preload['openmw.world'] = package.preload['openmw.world'] or function()
  return {cells = {}}
end
package.preload['openmw.types'] = package.preload['openmw.types'] or function()
  return {}
end

local app_api = require('scripts.mom.app')
local compiler = require('scripts.mom.compiler.compile_sources')
local entrypoint = require('scripts.mom.entrypoint')
local error_message = require('scripts.mom.diagnostics.error_message')
local ledger_api = require('scripts.mom.ledger.ledger')
local startup_compile = require('scripts.mom.compiler.startup_compile')
local test_support = require('pure.test_support')
local expect = test_support.expect

local FAMILY = 'startup_lifetime_fixture'
local CONFIG_DIR = 'startup-lifetime-config'
local SOURCE_PATH = CONFIG_DIR .. '/invalid.yaml'

local function noop()
  return {status = 'noop', changedClaims = {}, outputs = {}}
end

local function withHost(callback)
  local vfs = require('openmw.vfs')
  local markup = require('openmw.markup')
  local previousPaths, previousExists = vfs.pathsWithPrefix, vfs.fileExists
  local previousYaml = markup.loadYaml
  local core = require('openmw.core')
  local previousGMST = core.getGMST
  local canonical = require('scripts.mom.contracts.canonical')
  local status = require('scripts.mom.compiler.load_status')
  local encoded = assert(status.encode({version = status.VERSION, status = 'ready',
    sourceHash = canonical.assertHash({version = 2, inputs = {}}),
    content = {status = 'noop', contentHash = canonical.assertHash({})}}))
  core.getGMST = function(key) if key == status.KEY then return encoded end end
  local host = {discovery = {}, sourceInvalid = false, failOpen = false, opens = 0}
  local action = {
    id = FAMILY,
    abiVersion = 0,
    behaviorVersion = 0,
    programVersion = 0,
    storageVersion = 0,
    prepareAction = function(input) return input end,
    compileAction = function() return {} end,
    validateProgram = function() return true end,
    apply = noop,
  }
  local modules = {
    ['scripts.mom.actions.' .. FAMILY] = action,
    ['scripts.mom.guards.' .. FAMILY] = {
      id = FAMILY,
      abiVersion = 0,
      behaviorVersion = 0,
      programVersion = 0,
      lowerTuple = function() return {} end,
      compileProgram = function() return {} end,
      evaluate = function() return true end,
    },
    ['scripts.mom.compat.' .. FAMILY .. '.translator'] = {
      id = FAMILY,
      abiVersion = 1,
      behaviorVersion = 0,
      matchesPath = function() return false end,
      translateSource = function() return {} end,
    },
  }
  local previousModules = {}
  for name, value in pairs(modules) do
    previousModules[name] = {
      loaded = package.loaded[name],
      preload = package.preload[name],
    }
    package.loaded[name] = nil
    package.preload[name] = function() return value end
  end
  local paths = {
    ['scripts/mom/actions'] = {'scripts/mom/actions/' .. FAMILY .. '.lua'},
    ['scripts/mom/guards'] = {'scripts/mom/guards/' .. FAMILY .. '.lua'},
    ['scripts/mom/compat'] = {
      'scripts/mom/compat/' .. FAMILY .. '/translator.lua',
    },
  }
  vfs.pathsWithPrefix = function(prefix)
    local values = paths[prefix]
    if values ~= nil then
      host.discovery[prefix] = (host.discovery[prefix] or 0) + 1
    elseif prefix == CONFIG_DIR .. '/' and host.sourceInvalid then
      values = {SOURCE_PATH}
    else
      values = {}
    end
    local index = 0
    return function()
      index = index + 1
      return values[index]
    end
  end
  vfs.fileExists = function(path) return path == SOURCE_PATH end
  markup.loadYaml = function(path)
    expect(path == SOURCE_PATH, 'startup loaded an unexpected fixture source')
    return {version = 99}
  end
  function host.compile()
    return startup_compile.compile({configDir = CONFIG_DIR})
  end
  function host.expectDiscoveries(count)
    for prefix in pairs(paths) do
      expect(host.discovery[prefix] == count,
        prefix .. ' discovery did not run once per compilation')
    end
  end
  function host.app(savedLedger)
    local function ready() return true end
    local function empty() return {} end
    local app = assert(app_api.new({engineSessionFactory = {
      open = function()
        host.opens = host.opens + 1
        if host.failOpen then return nil, {'fixture engine-open failure'} end
        return {
          world = {
            beginFrame = function() end,
            isValid = function() return false end,
            observedCells = empty,
            getObservedCell = function() return nil end,
            isCellFenced = function() return false end,
            cellRefs = function() return {}, nil end,
            resolveTarget = function() return nil end,
            resolveCell = function() return nil end,
          },
          guardCapabilities = {},
          beginFrame = function() end,
          syncObservedCells = function() return {}, {} end,
          pollGuardEvents = empty,
          previsitCells = empty,
          observeObject = function() return nil, false end,
          observeCell = function() return nil, false end,
          replaceQuestSnapshot = ready,
          updateQuestStage = ready,
          clear = ready,
        }
      end,
    }}))
    if savedLedger ~= nil then assert(app_api.load(app, savedLedger)) end
    return app
  end

  local ok, err = pcall(callback, host)
  vfs.pathsWithPrefix, vfs.fileExists = previousPaths, previousExists
  markup.loadYaml = previousYaml
  core.getGMST = previousGMST
  for name, previous in pairs(previousModules) do
    package.loaded[name] = previous.loaded
    package.preload[name] = previous.preload
  end
  if not ok then error(error_message.message(err), 0) end
end

local function observeCatalog(candidate)
  expect(candidate.status == 'accepted', 'startup fixture was not accepted')
  local catalog = candidate.extensionCatalog
  for _, registry in ipairs({'actions', 'guards', 'compat'}) do
    expect(catalog[registry].byId[FAMILY] ~= nil,
      'startup did not discover its ' .. registry .. ' extension')
  end
  return setmetatable({
    catalog = catalog,
    actions = catalog.actions,
    guards = catalog.guards,
    compat = catalog.compat,
  }, {__mode = 'v'})
end

local function expectReleased(observed)
  collectgarbage('collect')
  collectgarbage('collect')
  expect(next(observed) == nil,
    'finished startup retained its raw catalog or extension registries')
end

local function savedLedgerV1()
  local l = ledger_api.new()
  l:putRef({
    kind = 'ref',
    id = 'content:000001:morrowind.esm',
    cellKey = 'balmora',
    origin = {cellId = 'balmora', position = {x = 1, y = 2, z = 3}},
  })
  return l:save()
end

local function expectRunning(app)
  assert(app_api.tick(app))
  local report = assert(app_api.selfcheck(app))
  expect(report.status == 'running' and report.ledger.ok == true,
    'runtime lost usable authority after catalog release')
  expect(assert(app_api.compileReport(app)).activeManifestHash ~= nil,
    'catalog release removed the active compile report')
  return assert(app_api.save(app))
end

local function activationReleasesCatalogAndPreservesLedger()
  withHost(function(host)
    local candidate = host.compile()
    local observed = observeCatalog(candidate)
    local app = host.app(savedLedgerV1())
    expect(candidate.manifest.extensions.actions[FAMILY] == nil,
      'historical family unexpectedly belongs to the current manifest')
    assert(app_api.bootstrap(app, candidate))
    candidate = nil
    expectReleased(observed)
    host.expectDiscoveries(1)
    local saved = expectRunning(app)
    expect(saved.schemaVersion == 1
        and saved.refs['content:000001:morrowind.esm'] ~= nil,
      'catalog release lost preserved v1 ledger ref data')
  end)
end

local function newCompilationsOwnIndependentCatalogs()
  withHost(function(host)
    local first = host.compile()
    local observed = observeCatalog(first)
    local second = host.compile()
    expect(first.extensionCatalog ~= second.extensionCatalog
        and first.manifest.contentHash == second.manifest.contentHash,
      'new compilation reused catalog ownership or changed manifest meaning')
    host.expectDiscoveries(2)
    first = nil
    expectReleased(observed)
    assert(app_api.bootstrap(host.app(), second))
  end)
end

local function rejectedCompilationCanStartFresh()
  withHost(function(host)
    local app = host.app(savedLedgerV1())
    host.sourceInvalid = true
    local rejected = host.compile()
    expect(rejected.status == 'rejected' and rejected.extensionCatalog == nil,
      'source rejection retained a startup catalog')
    local installed = app_api.bootstrap(app, rejected)
    expect(installed == nil and host.opens == 0 and app.runtime == nil,
      'rejected compilation opened an engine session')
    expect(app.loadedLedger.doc.refs['content:000001:morrowind.esm'] ~= nil,
      'rejected compilation changed the loaded ledger')
    host.sourceInvalid = false
    local accepted = host.compile()
    local observed = observeCatalog(accepted)
    assert(app_api.bootstrap(app, accepted))
    accepted = nil
    expectReleased(observed)
    host.expectDiscoveries(2)
    local report = assert(app_api.compileReport(app))
    expect(report.lastRejected.status == 'rejected'
        and report.lastRejected.summary.sources.failed == 1,
      'successful compilation erased the prior rejection diagnostics')
    expectRunning(app)
  end)
end

local function engineFailurePreservesBorrowedCandidate()
  withHost(function(host)
    local candidate = host.compile()
    local observed = observeCatalog(candidate)
    local app = host.app(savedLedgerV1())
    host.failOpen = true
    expect(app_api.bootstrap(app, candidate) == nil and app.runtime == nil,
      'engine failure installed a runtime')
    expect(app.loadedLedger.doc.refs['content:000001:morrowind.esm'] ~= nil,
      'engine failure lost loaded ledger ownership')
    host.failOpen = false
    assert(app_api.bootstrap(app, candidate))
    host.expectDiscoveries(1)
    expect(host.opens == 2, 'same-candidate retry did not reopen the engine')
    candidate = nil
    expectReleased(observed)
    expectRunning(app)
  end)
end

local function engineFailureAllowsNewCompilation()
  withHost(function(host)
    local candidate = host.compile()
    local observed = observeCatalog(candidate)
    local app = host.app(savedLedgerV1())
    host.failOpen = true
    expect(app_api.bootstrap(app, candidate) == nil,
      'engine failure unexpectedly activated the candidate')
    candidate = nil
    expectReleased(observed)
    host.failOpen = false
    local fresh = host.compile()
    assert(app_api.bootstrap(app, fresh))
    host.expectDiscoveries(2)
    expectRunning(app)
  end)
end

local function compilerRequiresExplicitCatalog()
  withHost(function(host)
    local result = compiler.compile({sourceAttempts = {}})
    expect(result.status == 'rejected'
        and result.fatal.code == 'extension_catalog_invalid'
        and next(host.discovery) == nil,
      'compiler discovered an implicit catalog instead of rejecting its absence')
  end)
end

local function entryCallbacksOwnIndependentCompilations()
  withHost(function(host)
    local app = host.app()
    local script = assert(entrypoint.new({
      app = app,
      sourceOptions = {configDir = CONFIG_DIR},
    }))
    expect(script.engineHandlers.onInit() == true,
      'production startup callback did not initialize the App')
    local hash = app.activeManifestHash
    local saved = assert(script.engineHandlers.onSave())
    expect(script.engineHandlers.onLoad(saved) == true,
      'production load callback did not reactivate the App')
    expect(app.activeManifestHash == hash,
      'save/load rediscovery changed the current manifest')
    host.expectDiscoveries(2)
    expectRunning(app)
  end)
end

function M.run()
  return test_support.runCases('startup catalog', {
    {'activation releases catalog and preserves v1 ledger',
      activationReleasesCatalogAndPreservesLedger},
    {'new compilations own independent catalogs', newCompilationsOwnIndependentCatalogs},
    {'rejection permits fresh compilation', rejectedCompilationCanStartFresh},
    {'engine failure preserves borrowed candidate', engineFailurePreservesBorrowedCandidate},
    {'engine failure permits fresh compilation', engineFailureAllowsNewCompilation},
    {'compiler requires an explicit catalog', compilerRequiresExplicitCatalog},
    {'init and load compile independently', entryCallbacksOwnIndependentCompilations},
  })
end

return M
