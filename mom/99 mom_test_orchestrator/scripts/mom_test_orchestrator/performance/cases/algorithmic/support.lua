local arbiter_api = require('scripts.mom.runtime.arbiter')
local canonical = require('scripts.mom.contracts.canonical')
local compactor = require('scripts.mom.ledger.compactor')
local container_transfer = require('scripts.mom.actions.place_ref.container_transfer')
local coordinator_api = require('scripts.mom.runtime.coordinator')
local executor_api = require('scripts.mom.runtime.executor')
local guards_api = require('scripts.mom.runtime.guards')
local ledger_api = require('scripts.mom.ledger.ledger')
local local_broker_api = require('scripts.mom.runtime.local_broker')
local manifest_assembler = require('scripts.mom_test_orchestrator.manifest_fixture')

local function stateAction(index, value)
  local id = string.format('action_%03d', index)
  local ownerId = string.format('owner_%03d', index)
  return {
    id = id,
    family = 'perf_action',
    lifecycle = 'state',
    scope = 'ref',
    ownerId = ownerId,
    program = {value = value},
    selection = {
      exactIds = {'perf_target_' .. tostring(index)},
      candidateTypes = {Miscellaneous = true},
    },
    claims = {keys = {'ref.scale'}},
    priority = index,
    specificity = 1,
    order = index,
    chance = 1,
    reversible = true,
    childIds = {},
    sourceRef = 'performance:' .. id,
    previsit = false,
  }, {
    id = ownerId,
    guard = {op = 'always'},
    actionIds = {id},
    subscriptions = {id .. ':changed', 'performanceEvent'},
  }
end

local function stateManifest(count, value)
  local actionIds, actionsById, ownerIds, ownersById = {}, {}, {}, {}
  for i = 1, count do
    local act, own = stateAction(i, value)
    actionIds[i] = act.id
    actionsById[act.id] = act
    ownerIds[i] = own.id
    ownersById[own.id] = own
  end
  return {
    contentHash = 'mom64:perf-state-' .. tostring(count) .. '-' .. tostring(value),
    actionIds = actionIds,
    actionsById = actionsById,
    ownerIds = ownerIds,
    ownersById = ownersById,
    indexes = {staticByCell = {}, ownersByCell = {shared = ownerIds}, ownersByEvent = {}},
    extensions = {actions = {}, guards = {}, compat = {}},
  }
end

local function staticManifest()
  local act = {
    id = 'static_action',
    family = 'perf_action',
    lifecycle = 'static',
    scope = 'ref',
    program = {value = 1},
    selection = {
      exactIds = {'perf_static_target'},
      candidateTypes = {Static = true},
    },
    claims = {keys = {'ref.scale'}},
    priority = 0,
    specificity = 1,
    order = 1,
    chance = 1,
    reversible = false,
    childIds = {},
    sourceRef = 'performance:static',
    previsit = false,
  }
  return {
    contentHash = 'mom64:perf-static',
    actionIds = {act.id},
    actionsById = {[act.id] = act},
    ownerIds = {},
    ownersById = {},
    indexes = {staticByCell = {shared = {act.id}}, ownersByCell = {}, ownersByEvent = {}},
    extensions = {actions = {}, guards = {}, compat = {}},
  }
end

local function actionCatalog()
  local mod = {
    id = 'perf_action',
    execution = 'global',
    abiVersion = 0,
    behaviorVersion = 0,
    programVersion = 0,
    matchesTarget = function() return true end,
    capture = function(_program, target)
      return {value = target.value}
    end,
    apply = function(program, target)
      local changed = target.value ~= program.value
      target.value = program.value
      return {
        status = changed and 'applied' or 'noop',
        changedClaims = changed and {'ref.scale'} or {},
      }
    end,
    revert = function(token, target)
      local changed = target.value ~= token.value
      target.value = token.value
      return {
        status = changed and 'applied' or 'noop',
        changedClaims = changed and {'ref.scale'} or {},
      }
    end,
  }
  return {
    kind = 'mom-extension-catalog',
    actions = {ids = {'perf_action'}, byId = {perf_action = {id = 'perf_action', module = mod}}},
    guards = {ids = {}, byId = {}},
    compat = {ids = {}, byId = {}},
  }
end

local function makeCell(key, refs)
  local facts = {
    id = key, idLower = key:lower(), key = key:lower(), interiorKey = key:lower(),
    name = key, nameLower = key:lower(), displayNameLower = key:lower(),
    isExterior = false, worldspaceKey = 'sys::default',
  }
  return {
    handle = facts,
    facts = facts,
    routes = {'shared', 'interior:' .. key:lower()},
    refs = refs or {},
  }
end

local function mockSession(opts)
  opts = opts or {}
  local observed = opts.observed or {}
  local byId = opts.byId or {}
  local pendingEvents = {}
  local pendingEntered = {}
  local onCellRefs = opts.onCellRefs

  local session = {
    world = {
      beginFrame = function() end,
      isValid = function(ref) return ref ~= nil and ref.valid ~= false end,
      observedCells = function() return observed end,
      getObservedCell = function(k) return observed[k] end,
      isCellFenced = function() return false end,
      cellRefs = function(cellHandle, query)
        if onCellRefs then onCellRefs(cellHandle, query) end
        local entry = observed[cellHandle.key]
        return entry and entry.refs or {}, nil
      end,
      describeRef = function(ref)
        local entry = observed[ref.cellKey]
        local cf = entry and entry.facts or makeCell(ref.cellKey or 'perf_cell').facts
        return {
          id = ref.id,
          objectId = ref.id,
          recordId = ref.recordId,
          typeName = ref.typeName or 'Miscellaneous',
          position = ref.position or {x = 0, y = 0, z = 0},
          currentCell = cf,
          cell = cf,
          origin = {cellId = cf.key, cell = cf, position = ref.position or {x = 0, y = 0, z = 0}},
        }, nil
      end,
      resolveTarget = function(id) return byId[id] end,
      resolveCell = function(key)
        local entry = observed[tostring(key):lower()]
        return entry and entry.handle or nil
      end,
    },
    guardCapabilities = opts.guardCapabilities or {},
    beginFrame = function() end,
    syncObservedCells = function()
      local out = pendingEntered
      pendingEntered = {}
      return out, {}
    end,
    pollGuardEvents = function()
      local out = pendingEvents
      pendingEvents = {}
      return out
    end,
    previsitCells = function() return {} end,
    clear = function() end,
  }

  function session.pushEvent(name)
    pendingEvents[#pendingEvents + 1] = name
  end
  function session.pushCell(entry)
    observed[entry.facts.key] = entry
    pendingEntered[#pendingEntered + 1] = entry
  end

  return session
end

local function newRuntime(manifest, ledger, session)
  local catalog = actionCatalog()
  local bundle = assert(coordinator_api.prepareActivation({
    manifest = manifest,
    extensionCatalog = catalog,
  }))
  return assert(coordinator_api.new({
    activationBundle = bundle,
    ledger = ledger or ledger_api.new(),
    session = session or mockSession(),
    currentFrame = 0,
  }))
end

local function coldCompileConfig(actionCount)
  local source_ir = require('scripts.mom.compiler.source_ir')
  local sourcePath = 'performance/cold_source_compile.yaml'
  local actions = {}
  for i = 1, actionCount do
    actions[i] = source_ir.sourceAction({
      select = {
        cell = 'Balmora, Eight Plates',
        recordId = 'misc_de_pot_green_01',
      },
      modify = {
        scale = {to = 0.5 + i / 1000},
      },
    }, {
      family = 'modify_ref',
      diagnosticId = 'performance.actions[' .. tostring(i) .. ']',
      source = {
        adapterId = 'native',
        file = sourcePath,
        variant = 'default',
        path = {'actions', i},
      },
    })
  end
  return {
    sourceAttempts = {{
      adapterId = 'native',
      path = sourcePath,
      sourcePath = sourcePath,
      kind = 'native',
      native = true,
      compat = false,
      explicit = true,
      status = 'resolved',
      actions = actions,
    }},
  }
end

return {
  arbiter_api = arbiter_api,
  canonical = canonical,
  compactor = compactor,
  container_transfer = container_transfer,
  coordinator_api = coordinator_api,
  executor_api = executor_api,
  guards_api = guards_api,
  ledger_api = ledger_api,
  local_broker_api = local_broker_api,
  manifest_assembler = manifest_assembler,
  stateAction = stateAction,
  stateManifest = stateManifest,
  staticManifest = staticManifest,
  actionCatalog = actionCatalog,
  makeCell = makeCell,
  mockSession = mockSession,
  newRuntime = newRuntime,
  coldCompileConfig = coldCompileConfig,
}
