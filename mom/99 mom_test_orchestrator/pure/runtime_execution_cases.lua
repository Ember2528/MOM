-- Unit & stress tests for runtime execution: executor, container_transfer, reconciler, app.
local M = {}

local app_api = require('scripts.mom.app')
local container_transfer = require('scripts.mom.actions.place_ref.container_transfer')
local coordinator_api = require('scripts.mom.runtime.coordinator')
local executor_api = require('scripts.mom.runtime.executor')
local ledger_api = require('scripts.mom.ledger.ledger')
local local_broker_api = require('scripts.mom.runtime.local_broker')
local test_support = require('pure.test_support')
local expect = test_support.expect

local function synchronousContainerTransferApplyAndRevert()
  local source = {enabled = true, lock = {locked = true, lockLevel = 25}, items = {gold = 37}}
  local output = {enabled = false, lock = {locked = false, lockLevel = 0}, items = {default_junk = 2}}
  local ctx = {
    world = {isValid = function(r) return r ~= nil end},
    refOps = {
      setEnabled = function(ref, val) ref.enabled = val; return true end,
      readLock = function(ref) return {locked = ref.lock.locked, lockLevel = ref.lock.lockLevel} end,
      writeLock = function(ref, lock) ref.lock = {locked = lock.locked, lockLevel = lock.lockLevel}; return true end,
    },
    inventoryOps = {
      getInventory = function(ref) return ref, 'Container', nil end,
      ensureResolved = function() return true, nil end,
      clearInventory = function(inv) inv.items = {}; return true, nil end,
      moveAllItems = function(from, to)
        local moved = false
        for k, v in pairs(from.items) do
          to.items[k] = (to.items[k] or 0) + v
          moved = true
        end
        from.items = {}
        return true, nil, moved
      end,
    },
  }
  local applied = assert(container_transfer.apply(source, output, ctx))
  expect(source.enabled == false and output.enabled == true
      and source.items.gold == nil and output.items.gold == 37
      and output.items.default_junk == nil and output.lock.lockLevel == 25,
    'synchronous container_transfer.apply did not clear defaults, move items, copy lock, and swap visibility')

  -- Simulate native respawn refill inside hidden source + player taking 10 gold from output.
  source.items.respawn_herb = 3
  output.items.gold = 27
  local reverted = assert(container_transfer.revert(source, output, {lock = applied.lock, sourceRespawning = true}, true, ctx))
  expect(reverted.movedItems == true and source.enabled == true and output.enabled == false
      and source.items.respawn_herb == nil and source.items.gold == 27
      and output.items.gold == nil and source.lock.lockLevel == 25,
    'synchronous container_transfer.revert did not discard hidden refill and return current output items')
end

local function executorPermanentRetirementAndPendingResumption()
  local ledger = ledger_api.new()
  local broker = local_broker_api.new()
  local live = {id = '@0x55', value = 'initial', enabled = true}
  local stepCalls = 0
  local mod = {
    capture = function() return {prev = live.value, recoveryCells = {'balmora, guild of mages'}} end,
    apply = function(_, target)
      target.value = 'pending'
      return {
        status = 'pending',
        changedClaims = {'ref.position'},
        pending = {phase = 'confirm', nextFrame = 2},
      }
    end,
    advance = function(_, target)
      stepCalls = stepCalls + 1
      target.value = 'final'
      return {status = 'applied', changedClaims = {'ref.position'}}
    end,
  }
  local session = {
    world = {
      resolveTarget = function(id) return id == 'output:parent' and live or nil end,
      describeRef = function() return {id = 'output:parent', recordId = 'lamp'} end,
      isValid = function(r) return r == live end,
    },
  }
  ledger:putRef({kind = 'output', id = 'output:parent', objectId = '@0x55', cellKey = 'balmora, eight plates'})
  local exec = executor_api.new({
    ledger = ledger, session = session, localBroker = broker,
    actionModules = {test_mod = mod}, manifest = {actionsById = {}},
  })
  local cand = {
    semanticId = 'sem:perm',
    targetId = 'output:parent',
    cellKey = 'balmora, eight plates',
    action = {
      id = 'act:perm', family = 'test_mod', lifecycle = 'state', ownerId = 'o1',
      reversible = false, claims = {keys = {'ref.position'}}, program = {},
    },
  }
  local res = exec.apply(cand, live, nil, 1)
  expect(res.status == 'pending' and ledger:pendingCount() == 1,
    'executor did not record pending op')
  local adv = exec.advancePending(res.op, 2)
  expect(adv == 'applied' and stepCalls == 1 and live.value == 'final' and ledger:pendingCount() == 0,
    'executor did not finalize pending op via advancePending')

  -- Retiring permanent op preserves recoveryCells on ledger.refs without calling revert!
  local rev = exec.revert(ledger:getOp(res.op.id), 3)
  local storedRef = ledger:getRef('output:parent')
  expect(rev.status == 'applied' and ledger:opCount() == 0 and live.value == 'final'
      and storedRef.recoveryCells[1] == 'balmora, guild of mages',
    'permanent op retirement failed to preserve recoveryCells on target ref')
end

local function appLifecycleAndSelfcheck()
  local app = assert(app_api.new({
    engineSessionFactory = {
      open = function()
        return {
          world = {
            beginFrame = function() end,
            isValid = function() return false end,
            observedCells = function() return {} end,
            getObservedCell = function() return nil end,
            isCellFenced = function() return false end,
            cellRefs = function() return {}, nil end,
            resolveTarget = function() return nil end,
            resolveCell = function() return nil end,
          },
          guardCapabilities = {},
          beginFrame = function() end,
          syncObservedCells = function() return {}, {} end,
          pollGuardEvents = function() return {} end,
          previsitCells = function() return {} end,
          clear = function() end,
        }
      end,
    },
  }))
  assert(app_api.load(app, {schemaVersion = 0})) -- legacy v0 cleanly resets to v1!
  local manifest_assembler = require('scripts.mom_test_orchestrator.manifest_fixture')
  local manifest = assert(manifest_assembler.assemble({
    actions = {},
    owners = {},
    extensions = {actions = {}, guards = {}, compat = {}},
  }))
  local okBoot, bootErr = app_api.bootstrap(app, {
    status = 'accepted',
    manifest = manifest,
    extensionCatalog = {kind = 'mom-extension-catalog', actions = {byId = {}}, guards = {byId = {}}, compat = {byId = {}}},
    diagnostics = {summary = {total = 0}},
  })
  expect(okBoot ~= nil, 'app bootstrap failed: ' .. tostring(bootErr and bootErr.message or bootErr))
  assert(app_api.tick(app))
  local sc = assert(app_api.selfcheck(app))
  expect(sc.ok == true and sc.status == 'running' and sc.ledger.ok == true
      and sc.runtime.counts.liveOperations == 0
      and sc.runtime.queues.state.pendingOwners == 0,
    'app selfcheck did not report clean running v1 status')
  local saved = assert(app_api.save(app))
  expect(saved.schemaVersion == 1 and saved.manifestHash == manifest.contentHash,
    'app save did not emit schemaVersion 1 ledger')
end

local function stressReconcile200TargetsInCell()
  local targets, byId = {}, {}
  local cellFacts = {
    id = 'Balmora', idLower = 'balmora', key = 'balmora', interiorKey = 'balmora',
    name = 'Balmora', nameLower = 'balmora', displayNameLower = 'balmora',
    isExterior = false, worldspaceKey = 'sys::default',
  }
  for i = 1, 200 do
    local tid = string.format('content:%06x:morrowind.esm', i)
    local ref = {id = tid, recordId = 'lamp_01', enabled = true}
    targets[i] = ref
    byId[tid] = ref
  end
  local observed = {
    balmora = {handle = cellFacts, facts = cellFacts, routes = {'shared', 'interior:balmora'}},
  }
  local session = {
    world = {
      beginFrame = function() end,
      isValid = function(r) return r ~= nil end,
      observedCells = function() return observed end,
      getObservedCell = function(k) return observed[k] end,
      isCellFenced = function() return false end,
      cellRefs = function() return targets, nil end,
      describeRef = function(ref)
        return {
          id = ref.id, objectId = ref.id, recordId = ref.recordId, typeName = 'Static',
          position = {x = 0, y = 0, z = 0}, currentCell = cellFacts, cell = cellFacts,
          origin = {cellId = 'balmora', cell = cellFacts, position = {x = 0, y = 0, z = 0}},
        }, nil
      end,
      resolveTarget = function(id) return byId[id] end,
      resolveCell = function() return cellFacts end,
    },
    guardCapabilities = {},
    beginFrame = function() end,
    syncObservedCells = function() return {}, {} end,
    pollGuardEvents = function() return {} end,
    clear = function() end,
  }
  local mod = {
    matchesTarget = function() return true end,
    capture = function(_, ref) return {enabled = ref.enabled} end,
    apply = function(_, ref)
      ref.enabled = false
      return {status = 'applied', changedClaims = {'ref.enabled'}, outputs = {}}
    end,
    revert = function(tok, ref)
      ref.enabled = tok.enabled
      return {status = 'applied', changedClaims = {'ref.enabled'}, outputs = {}}
    end,
  }
  local action = {
    id = 'action:modify_ref:stress',
    family = 'modify_ref',
    lifecycle = 'static',
    scope = 'ref',
    reversible = true,
    priority = 0, specificity = 0, order = 1, chance = 1,
    claims = {keys = {'ref.enabled'}},
    selection = {exactIds = {'lamp_01'}, candidateTypes = {Static = true}},
    program = {},
    childIds = {},
  }
  local manifest = {
    contentHash = 'mom64:stress200',
    actionIds = {action.id},
    actionsById = {[action.id] = action},
    ownerIds = {}, ownersById = {},
    indexes = {staticByCell = {['interior:balmora'] = {action.id}}, ownersByCell = {}, ownersByEvent = {}},
    extensions = {actions = {}, guards = {}, compat = {}},
  }
  local bundle = assert(coordinator_api.prepareActivation({
    manifest = manifest,
    extensionCatalog = {actions = {byId = {modify_ref = {module = mod}}}, guards = {byId = {}}},
  }))
  local ledger = ledger_api.new()
  local rt = assert(coordinator_api.new({
    activationBundle = bundle, ledger = ledger, session = session,
  }))
  rt.reconciler.enqueueCell('balmora')
  for frame = 1, 20 do
    assert(coordinator_api.tick(rt, {frame = frame}))
    if rt.reconciler.status().queues.staticCells == 0 then break end
  end
  expect(ledger:opCount() == 200 and rt.reconciler.status().queues.staticCells == 0,
    '200-target static reconciliation did not apply all 200 refs and settle')
  for i = 1, 200 do
    expect(targets[i].enabled == false, 'target was not disabled during static reconciliation')
  end
end

function M.run()
  return test_support.runCases('runtime execution', {
    {'synchronous container transfer apply and revert', synchronousContainerTransferApplyAndRevert},
    {'executor pending resumption and permanent retirement', executorPermanentRetirementAndPendingResumption},
    {'app lifecycle legacy reset and selfcheck', appLifecycleAndSelfcheck},
    {'stress 200-target cell reconciliation', stressReconcile200TargetsInCell, {stress = true}},
  })
end

return M
