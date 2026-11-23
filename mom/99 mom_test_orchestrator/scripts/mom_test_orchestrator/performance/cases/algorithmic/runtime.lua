local support = require('scripts.mom_test_orchestrator.performance.cases.algorithmic.support')
local arbiter_api = support.arbiter_api
local coordinator_api = support.coordinator_api
local guards_api = support.guards_api
local stateManifest = support.stateManifest
local newRuntime = support.newRuntime
local mockSession = support.mockSession
local makeCell = support.makeCell
local coldCompileConfig = support.coldCompileConfig

local function registerColdCompile(define, id, actionCount)
  define(id, {
    category = 'compiler',
    operations = 1,
    minimumSampleSeconds = 0.001,
    gcPolicy = 'inclusive',
    semantics = 'cold_start',
    modes = {embedded = true},
    detail = {actions = actionCount, catalog = 'fresh_discovery', pipeline = 'compile_once'},
  }, function(measure)
    local compiler = require('scripts.mom.compiler.compile_sources')
    local extension_catalog = require('scripts.mom.compiler.discover_extensions')
    local config = coldCompileConfig(actionCount)
    return measure(function()
      local catalog = extension_catalog.discover()
      local result = compiler.compile(config, catalog)
      assert(result and result.manifest and #result.manifest.actionIds == actionCount,
        'cold compiler benchmark emitted the wrong action count')
      return result.manifest.contentHash
    end)
  end)
end

local function authoredPlaceConfig(tupleCount)
  local tuples = {}
  for i = 1, tupleCount do
    tuples[i] = {
      'Balmora',
      'light_de_lantern_01',
      {i, i * 2, i * 3},
      {yaw = i % 360, pitch = 0, roll = 0},
    }
  end
  return {
    version = 0,
    variants = {performance = {actions = {{place = tuples}}}},
  }
end

local function registerAuthoredPlaceCompile(define, id, tupleCount)
  define(id, {
    category = 'compiler',
    operations = 1,
    minimumSampleSeconds = 0.001,
    gcPolicy = 'inclusive',
    semantics = 'cold_start',
    modes = {embedded = true},
    detail = {authoredActions = 1, authoredPlaceTuples = tupleCount},
  }, function(measure)
    local compiler = require('scripts.mom.compiler.compile_sources')
    local extension_catalog = require('scripts.mom.compiler.discover_extensions')
    local variant_resolver = require('scripts.mom.compiler.variant_resolver')
    local sourcePath = 'performance/authored_place_tuples.yaml'
    local config = authoredPlaceConfig(tupleCount)
    return measure(function()
      local resolved = assert(variant_resolver.resolve(config, {
        activeContent = {}, sourcePath = sourcePath, adapterId = 'native',
      }))
      local catalog = extension_catalog.discover()
      local result = compiler.compile({
        sourceAttempts = {{
          adapterId = 'native', path = sourcePath, sourcePath = sourcePath,
          kind = 'native', native = true, compat = false, explicit = true,
          status = 'resolved', actions = resolved.actions,
        }},
      }, catalog)
      local manifest = assert(result and result.manifest)
      local action = manifest.actionsById[manifest.actionIds[1]]
      assert(#manifest.actionIds == 1 and #(action.program.objects or {}) == tupleCount,
        'authored placement benchmark emitted the wrong object count')
      return manifest.contentHash
    end)
  end)
end

return function(define)
  registerColdCompile(define, 'cold_source_compile', 64)
  registerColdCompile(define, 'cold_source_compile_256', 256)
  registerAuthoredPlaceCompile(define, 'cold_authored_place_compile_1024_tuples', 1024)
  registerAuthoredPlaceCompile(define, 'cold_authored_place_compile_4096_tuples', 4096)

  define('cold_runtime_bootstrap_256', {
    version = 3,
    category = 'runtime',
    operations = 1,
    minimumSampleSeconds = 0.0005,
    gcPolicy = 'inclusive',
    semantics = 'cold_start',
    modes = {standalone = true, embedded = true},
    detail = {actions = 256, owners = 256},
  }, function(measure)
    local manifest = stateManifest(256, 1)
    return measure(function()
      local rt = newRuntime(manifest)
      assert(#rt.manifest.actionIds == 256)
      return rt.manifest.contentHash
    end)
  end)

  define('idle_tick', {
    version = 2,
    category = 'runtime',
    operations = 1000,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {owners = 128},
  }, function(measure)
    local rt = newRuntime(stateManifest(128, 1))
    coordinator_api.tick(rt, {frame = 1})
    local frame = 1
    return measure(function()
      for _ = 1, 1000 do
        frame = frame + 1
        coordinator_api.tick(rt, {frame = frame})
      end
      return 'frame=' .. tostring(frame)
    end)
  end)

  define('single_dirty_owner', {
    version = 4,
    category = 'runtime',
    operations = 50,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {totalOwners = 128, dirtyOwners = 1},
  }, function(measure)
    local manifest = stateManifest(128, 1)
    local refs, byId = {}, {}
    for i = 1, 128 do
      local ref = {
        id = string.format('content:%06x:morrowind.esm', i),
        recordId = 'perf_target_' .. tostring(i),
        typeName = 'Miscellaneous',
        cellKey = 'perf_cell',
        value = 0,
      }
      refs[i] = ref
      byId[ref.id] = ref
    end
    local session = mockSession({
      observed = {perf_cell = makeCell('perf_cell', refs)},
      byId = byId,
    })
    local rt = newRuntime(manifest, nil, session)
    coordinator_api.tick(rt, {frame = 1})
    local dirtyOwnerId = manifest.ownerIds[64]
    local frame = 1
    return measure(function()
      for _ = 1, 50 do
        rt.guards.markDirty(dirtyOwnerId)
        frame = frame + 1
        coordinator_api.tick(rt, {frame = frame})
      end
      return 'frame=' .. tostring(frame)
    end)
  end)

  define('event_fanout', {
    version = 2,
    category = 'runtime',
    operations = 25,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {ownersPerEvent = 128},
  }, function(measure)
    local session = mockSession()
    local rt = newRuntime(stateManifest(128, 1), nil, session)
    coordinator_api.tick(rt, {frame = 1})
    local frame = 1
    return measure(function()
      for _ = 1, 25 do
        session.pushEvent('performanceEvent')
        frame = frame + 1
        coordinator_api.tick(rt, {frame = frame})
      end
      return 'frame=' .. tostring(frame)
    end)
  end)

  define('guard_fragment_evaluation', {
    version = 3,
    category = 'runtime',
    operations = 10000,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {fragments = 1},
  }, function(measure)
    local manifest = {
      ownerIds = {'owner_perf'},
      ownersById = {
        owner_perf = {
          id = 'owner_perf',
          guard = {
            op = 'all',
            fragments = {{family = 'perf_guard', program = {expected = 1}}},
          },
          actionIds = {},
          subscriptions = {'perf_event'},
        },
      },
    }
    local registry = {
      byId = {
        perf_guard = {
          module = {
            evaluate = function(program, caps)
              return {state = (program.expected == 1 and caps.active) and 'active' or 'inactive'}
            end,
          },
        },
      },
    }
    local guards = assert(guards_api.new(manifest, registry))
    local caps = {active = true}
    return measure(function()
      local active = 0
      for i = 1, 10000 do
        guards.markDirty('owner_perf')
        guards.evaluateDue(i, caps)
        if guards.truth('owner_perf') == 'active' then active = active + 1 end
      end
      assert(active == 10000)
      return 'active=' .. tostring(active)
    end)
  end)

  define('state_large_claim_component', {
    version = 4,
    category = 'runtime',
    operations = 512,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    modes = {standalone = true},
    detail = {competingCandidates = 512},
  }, function(measure)
    local candidates = {}
    for i = 1, 512 do
      candidates[i] = {
        id = string.format('cand:%04d', i),
        semanticId = string.format('sem:%04d', i),
        actionId = string.format('act:%04d', i),
        targetId = 'content:000001:morrowind.esm',
        priority = i % 17,
        specificity = i % 5,
        depth = 0,
        order = i,
        claims = {'ref.scale'},
      }
    end
    return measure(function()
      local res = arbiter_api.arbitrate(candidates, {})
      assert(#res.winners == 1 and #res.blocked == 511)
      return res.winners[1].id
    end)
  end)
end
