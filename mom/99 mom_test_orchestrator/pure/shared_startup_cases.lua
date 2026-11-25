local M = {}
local support = require('pure.test_support')
local expect = support.expect
local startup = require('scripts.mom.compiler.startup_compile')
local status = require('scripts.mom.compiler.load_status')
local canonical = require('scripts.mom.contracts.canonical')

local function withHost(callback)
  local vfs, markup, core = require('openmw.vfs'), require('openmw.markup'), require('openmw.core')
  local oldPaths, oldYaml, oldGMST, oldExists = vfs.pathsWithPrefix, markup.loadYaml, core.getGMST, vfs.fileExists
  local config = {version = 0, variants = {test = {actions = {{record = {type = 'Static', id = 'a',
    patch = {model = 'meshes/b.nif'}}}}}}}
  local counters = {reads = 0, discoveries = 0}
  vfs.pathsWithPrefix = function(prefix)
    if prefix == 'scripts/mom/actions' or prefix == 'scripts/mom/guards' or prefix == 'scripts/mom/compat' then
      counters.discoveries = counters.discoveries + 1
    end
    local once = false
    return function()
      if not once and prefix == 'shared-startup-fixture/' then once = true; return 'shared-startup-fixture/mixed.yaml' end
    end
  end
  markup.loadYaml = function(path)
    expect(path == 'shared-startup-fixture/mixed.yaml', 'unexpected source')
    counters.reads = counters.reads + 1
    return config
  end
  local records = {a = {id = 'a', model = 'meshes/a.nif'}}
  local options = {configDir = 'shared-startup-fixture', vfr = false,
    content = {statics = {records = records}}, modelExists = function(path) return true, path end}
  local function compile(phase)
    options.phase = phase
    return startup.compile(options)
  end
  local ok, err = pcall(callback, config, options, compile, counters, core, records)
  vfs.pathsWithPrefix, markup.loadYaml, core.getGMST = oldPaths, oldYaml, oldGMST
  vfs.fileExists = oldExists
  if not ok then error(err, 0) end
end

function M.run()
  return support.runCases('shared startup compiler', {
    {'LOAD isolates GLOBAL backend errors and rejects broken guards atomically', function()
      withHost(function(config, _, compile, counters, _, records)
        config.variants.test.actions[2] = {modify = {{'*', 'a', {scale = 'bad'}}}}
        local candidate = compile('LOAD')
        expect(candidate.status == 'accepted', candidate.fatal and candidate.fatal.message)
        expect(#candidate.plan.writes == 1 and counters.reads == 1 and counters.discoveries == 2
          and records.a.model == 'meshes/a.nif', 'LOAD crossed its compilation boundary or mutated')
        config.variants.test.guards = {{when = {{'missing.guard', false}}, actions = {{kill = {}}}}}
        local rejected = compile('LOAD')
        expect(rejected.status == 'rejected' and rejected.fatal.code == 'guard_semantics_invalid'
          and records.a.model == 'meshes/a.nif', 'broken guard was not rejected atomically in LOAD')
      end)
    end},
    {'GLOBAL ignores invalid LOAD fields and never queries content', function()
      withHost(function(config, options, compile)
        config.variants.test.actions[1].record.patch.model = 42
        options.content = setmetatable({}, {__index = function() error('GLOBAL touched content') end})
        local candidate = compile('GLOBAL')
        expect(candidate.status == 'accepted' and #candidate.manifest.actionIds == 0,
          candidate.fatal and candidate.fatal.message or 'LOAD declaration reached runtime compiler')
        expect(compile('LOAD').status == 'rejected', 'assigned LOAD error was redirected')
      end)
    end},
    {'independent passes agree on LOAD fingerprint across changed catalogs', function()
      withHost(function(_, _, compile, counters, _, records)
        local load = compile('LOAD')
        records.a.model = 'meshes/b.nif'
        local global = compile('GLOBAL')
        expect(load.status == 'accepted' and global.status == 'accepted'
          and load.loadFingerprint == global.loadFingerprint and #global.manifest.actionIds == 0
          and counters.reads == 2, 'compilation reused source or reclassified after catalog changes')
      end)
    end},
    {'GLOBAL sibling changes do not invalidate LOAD input', function()
      withHost(function(config, _, compile)
        local before = compile('LOAD').loadFingerprint
        table.insert(config.variants.test.actions, 1, {modify = {}})
        local after = compile('LOAD')
        expect(after.status == 'accepted' and after.loadFingerprint == before, 'GLOBAL sibling changed LOAD fingerprint')
        config.variants.test.actions[2].record.patch.model = 'meshes/c.nif'
        expect(compile('LOAD').loadFingerprint ~= before, 'LOAD change was not fingerprinted')
      end)
    end},
    {'installed facade rejects missing status and changed LOAD input', function()
      withHost(function(config, options, compile, counters, core)
        core.getGMST = function() return nil end
        expect(startup.installed(options).status == 'rejected' and counters.reads == 0,
          'missing completion did not block startup')
        local candidate = compile('LOAD')
        local encoded = assert(status.encode({version = status.VERSION, status = 'ready',
          sourceHash = candidate.loadFingerprint, decisions = candidate.loadDecisions,
          content = {status = 'noop', contentHash = canonical.assertHash({})}}))
        core.getGMST = function(key) if key == status.KEY then return encoded end end
        expect(startup.installed(options).status == 'accepted', 'valid completion rejected')
        config.variants.test.actions[1].record.patch.model = 'meshes/changed.nif'
        local changed = startup.installed(options)
        expect(changed.status == 'rejected' and changed.fatal.code == 'load_input_changed', 'changed content activated')
      end)
    end},
    {'production LOAD defaults to cached VFS model validation', function()
      withHost(function(config, options, compile, _, _, records)
        options.modelExists = nil
        records.b = {id = 'b', model = 'meshes/a.nif'}
        config.variants.test.actions[2] = {record = {type = 'Static', id = 'b', patch = {model = 'meshes/b.nif'}}}
        local probes = 0
        require('openmw.vfs').fileExists = function() probes = probes + 1; return false end
        local first = compile('LOAD')
        expect(first.status == 'rejected' and first.fatal.message:find('unavailable', 1, true)
          and probes == 1, 'missing asset was not rejected or repeated inside one invocation')
        expect(compile('LOAD').status == 'rejected' and probes == 2, 'asset cache leaked between compilations')
      end)
    end},
    {'both invocations honor explicitly supplied native source directories', function()
      withHost(function(config, options, compile)
        local vfs, markup = require('openmw.vfs'), require('openmw.markup')
        local oldPaths, oldYaml = vfs.pathsWithPrefix, markup.loadYaml
        local extra = config.variants.test.actions[1]
        config.variants.test.actions = {}
        options.configDirs = {'shared-extra-native'}
        vfs.pathsWithPrefix = function(prefix)
          if prefix ~= 'shared-extra-native/' then return oldPaths(prefix) end
          local once = false
          return function() if not once then once = true; return 'shared-extra-native/content.yaml' end end
        end
        markup.loadYaml = function(path)
          if path == 'shared-extra-native/content.yaml' then return {version = 0, variants = {extra = {actions = {extra}}}} end
          return oldYaml(path)
        end
        local load, global = compile('LOAD'), compile('GLOBAL')
        expect(load.status == 'accepted' and global.status == 'accepted' and #load.plan.writes == 1
          and load.sourceMetrics.nativeSources == 2 and global.sourceMetrics.nativeSources == 2
          and load.loadFingerprint == global.loadFingerprint, 'phase invocations discovered different native sources')
      end)
    end},
    {'compatErrorPolicy=skip quarantines broken compat files across both LOAD and GLOBAL', function()
      withHost(function(_, options, compile)
        local vfs, markup = require('openmw.vfs'), require('openmw.markup')
        local oldPaths, oldYaml = vfs.pathsWithPrefix, markup.loadYaml
        local badVfrPath = 'scripts/variationframework/placements/data/bad.yaml'
        options.vfr = true
        options.compatErrorPolicy = 'skip'
        vfs.pathsWithPrefix = function(prefix)
          if prefix == 'scripts/mom/compat' then
            local once = false
            return function()
              if not once then once = true; return 'scripts/mom/compat/vfr/translator.lua' end
            end
          end
          if prefix == 'scripts/variationframework/placements/data/' then
            local once = false
            return function()
              if not once then once = true; return badVfrPath end
            end
          end
          return oldPaths(prefix)
        end
        markup.loadYaml = function(path)
          if path == badVfrPath then
            return {placements = {{id = 'spawn.bad', spawn = true, record = 'rat', interior = 'Balmora', position = {0, 0, 0}}}}
          end
          return oldYaml(path)
        end
        local load, global = compile('LOAD'), compile('GLOBAL')
        expect(load.status == 'accepted' and global.status == 'accepted'
          and #load.plan.writes == 1 and load.loadFingerprint == global.loadFingerprint,
          'compatErrorPolicy=skip did not keep LOAD and GLOBAL aligned while skipping broken compat file')
        options.compatErrorPolicy = 'reject'
        local rejectedLoad = compile('LOAD')
        expect(rejectedLoad.status == 'rejected',
          'default/reject compatErrorPolicy did not reject broken compat file')
      end)
    end},
  })
end
return M
