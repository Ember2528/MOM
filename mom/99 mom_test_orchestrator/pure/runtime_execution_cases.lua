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
  local sessionOpens = 0
  local app = assert(app_api.new({
    engineSessionFactory = {
      open = function()
        sessionOpens = sessionOpens + 1
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
  expect(okBoot ~= nil and okBoot.dormant == true and sessionOpens == 0,
    'empty manifest did not activate dormant fast path without opening engine session: '
      .. tostring(bootErr and bootErr.message or bootErr))
  assert(app_api.tick(app))
  local sc = assert(app_api.selfcheck(app))
  expect(sc.ok == true and sc.status == 'running' and sc.ledger.ok == true
      and sc.runtime.dormant == true
      and sc.runtime.counts.liveOperations == 0
      and sc.runtime.queues.state.pendingOwners == 0,
    'dormant app selfcheck did not report clean running v1 status')
  local saved = assert(app_api.save(app))
  expect(saved.schemaVersion == 1 and saved.manifestHash == manifest.contentHash,
    'app save did not emit schemaVersion 1 ledger')
end

local function deferredRevertBackoffAndCellWake()
  local ledger = ledger_api.new()
  local broker = local_broker_api.new()
  local targetLoaded = false
  local live = {id = 'content:000001:morrowind.esm', reverted = false}
  local mod = {
    abiVersion = 0, behaviorVersion = 0, programVersion = 0, revertTokenVersion = 0,
    revert = function(_, ref)
      ref.reverted = true
      return {status = 'applied', changedClaims = {'ref.enabled'}}
    end,
  }
  local session = {
    world = {
      resolveTarget = function() return targetLoaded and live or nil end,
      describeRef = function() return {id = live.id, recordId = 'lamp_01'} end,
      isValid = function(r) return r == live end,
    },
  }
  local op = ledger:putOp({
    id = 'op:1', semanticId = 'sem:1', family = 'test_mod', actionId = 'act:1',
    lifecycle = 'state', durability = 'reversible', state = 'applied',
    targetId = live.id, claims = {'ref.enabled'}, token = {enabled = true},
  })
  local exec = executor_api.new({
    ledger = ledger, session = session, localBroker = broker,
    actionModules = {test_mod = mod}, manifest = {actionsById = {}},
  })
  local r1 = exec.revert(op, 10)
  expect(r1.status == 'pending' and ledger:getOp('op:1').pending.nextFrame == 11,
    'initial deferred revert did not schedule frame + 1')
  exec.advancePending(ledger:getOp('op:1'), 11)
  expect(ledger:getOp('op:1').pending.nextFrame == 16 and ledger:getOp('op:1').pending.delay == 5,
    'deferred revert did not back off to 5 frames')
  exec.advancePending(ledger:getOp('op:1'), 16)
  expect(ledger:getOp('op:1').pending.delay == 15, 'deferred revert did not back off to 15 frames')
  exec.advancePending(ledger:getOp('op:1'), 31)
  expect(ledger:getOp('op:1').pending.delay == 60, 'deferred revert did not back off to 60 frames')
  exec.advancePending(ledger:getOp('op:1'), 91)
  expect(ledger:getOp('op:1').pending.delay == 120, 'deferred revert did not cap backoff at 120 frames')

  targetLoaded = true
  expect(ledger:wakePendingReverts() == 1 and ledger:pendingOps()['op:1'] == 0,
    'cell wake did not reset backed-off revert to immediate due frame')
  local done = exec.advancePending(ledger:getOp('op:1'), 92)
  expect(done == 'applied' and live.reverted == true and ledger:opCount() == 0,
    'woken deferred revert did not complete immediately once target loaded')
end

local function midApplyRollbackAcrossActions()
  -- 1. place_ref rolls back already-spawned slot when a later slot fails.
  local place_rt = require('scripts.mom.actions.place_ref.runtime')
  local ledger = ledger_api.new()
  local removed, spawnedCount = 0, 0
  local pRes = place_rt.apply({}, nil, {
    mode = 'absolute',
    slots = {
      {outputId = 'output:s1', targetKind = 'record_id', targetValue = 'ok_rec', authoredRecordId = 'ok_rec', typeName = 'Static', cell = {key = 'balmora'}, slot = 'a:1'},
      {outputId = 'output:s2', targetKind = 'record_id', targetValue = 'bad_rec', authoredRecordId = 'bad_rec', typeName = 'Static', cell = {key = 'balmora'}, slot = 'a:2'},
    },
  }, {
    frame = 1, opId = 'op:1', targetId = 'cell:balmora', ledger = ledger,
    world = {
      registerLiveOutput = function() end,
      unregisterLiveOutput = function() end,
    },
    placementOps = {
      createObject = function(recId)
        if recId == 'bad_rec' then return nil, 'spawn failed' end
        spawnedCount = spawnedCount + 1
        return {ref = {id = '@0x1'}, objectId = '@0x1'}, nil
      end,
      removeObject = function() removed = removed + 1; return true, nil end,
    },
  })
  expect(pRes.status == 'failed' and spawnedCount == 1 and removed == 1
      and ledger:getRef('output:s1') == nil,
    'place_ref did not roll back previously spawned output on later slot failure')

  -- 2. modify_ref rolls back scale mutation if subsequent teleport fails.
  local modify_rt = require('scripts.mom.actions.modify_ref.runtime')
  local liveRef = {scale = 1.0, enabled = true, cell = {key = 'balmora'}, position = {x = 0, y = 0, z = 0}, rotation = {yaw = 0, pitch = 0, roll = 0}}
  local mRes = modify_rt.apply({}, liveRef, {
    patch = {scale = {mode = 'to', value = 2.0}, position = {mode = 'to', x = 50, y = 0, z = 0}},
    baseline = {scale = 1.0},
    starting = {cell = {key = 'balmora'}, position = {x = 0, y = 0, z = 0}, rotation = {yaw = 0, pitch = 0, roll = 0}},
  }, {
    frame = 1, targetId = 'content:000001:morrowind.esm', ledger = ledger,
    refOps = {
      read = function() return {scale = liveRef.scale, enabled = true, cell = liveRef.cell, position = liveRef.position, rotation = liveRef.rotation}, nil end,
      readStarting = function() return {cell = liveRef.cell, position = liveRef.position, rotation = liveRef.rotation}, nil end,
      setScale = function(_, v) liveRef.scale = v; return true, nil end,
      teleport = function() return nil, 'fatal teleport error' end,
    },
  })
  expect(mRes.status == 'failed' and liveRef.scale == 1.0,
    'modify_ref did not roll back scale after non-transient teleport failure')

  -- 3. modify_inventory rolls back earlier added items if a later item op fails.
  local inv_rt = require('scripts.mom.actions.modify_inventory.runtime')
  local bag = {}
  local iRes = inv_rt.apply({}, {}, {
    ops = {
      {op = 'add', sourceRecordId = 'gold_001', count = 10},
      {op = 'add', sourceRecordId = 'bad_item', count = 1},
    },
  }, {
    frame = 1, opId = 'op:inv',
    inventoryOps = {
      getInventory = function() return bag, false, nil end,
      ensureResolved = function() return true, nil, false end,
      addItems = function(_, recId, count)
        if recId == 'bad_item' then return nil, 'cannot create bad_item' end
        bag[recId] = (bag[recId] or 0) + count
        return {recordId = recId, count = count, data = {}, variantKey = 'vk'}, nil
      end,
      removeItems = function(_, recId, count)
        bag[recId] = (bag[recId] or 0) - count
        if bag[recId] <= 0 then bag[recId] = nil end
        return {{recordId = recId, count = count}}, nil
      end,
    },
  })
  expect(iRes.status == 'failed' and bag.gold_001 == nil,
    'modify_inventory did not roll back previously added items on mid-apply failure')

  -- 4. container_transfer rejects restocking source BEFORE clearing output defaults.
  local clearedOutput = false
  local ctRes, ctErr = container_transfer.apply({enabled = true}, {enabled = false}, {
    refOps = {
      readLock = function() return {locked = false, lockLevel = 0}, nil end,
      setEnabled = function() return true, nil end,
    },
    inventoryOps = {
      getInventory = function(r) return r, 'Container', nil end,
      ensureResolved = function() return true, nil end,
      listItems = function() return {{restocking = true}}, nil end,
      clearInventory = function() clearedOutput = true; return true, nil end,
    },
  })
  expect(ctRes == nil and tostring(ctErr):find('restocking', 1, true) ~= nil and clearedOutput == false,
    'container_transfer cleared output defaults before rejecting restocking source')
end

local function savedOpVersionAndValidateStoredStateGate()
  local manifest = {
    contentHash = 'mom64:ver',
    actionIds = {}, actionsById = {}, ownerIds = {}, ownersById = {},
    indexes = {staticByCell = {}, ownersByCell = {}, ownersByEvent = {}},
    extensions = {actions = {}, guards = {}, compat = {}},
  }
  local function catalogWith(mod)
    return {kind = 'mom-extension-catalog', actions = {byId = {custom = {module = mod}}}, guards = {byId = {}}}
  end
  local l = ledger_api.new()
  l:putOp({
    id = 'op:1', semanticId = 'sem:1', family = 'custom', actionId = 'act:1',
    familyAbiVersion = 1, revertTokenVersion = 2,
    lifecycle = 'state', durability = 'reversible', state = 'applied',
    targetId = 'content:000001:morrowind.esm', claims = {'ref.enabled'}, token = {ok = true},
  })

  local b1, e1 = coordinator_api.prepareActivation({
    manifest = manifest, ledger = l,
    extensionCatalog = catalogWith({abiVersion = 0, revertTokenVersion = 2}),
  })
  expect(b1 == nil and tostring(e1[1]):find('ABI version mismatch', 1, true) ~= nil,
    'prepareActivation did not reject saved op ABI version mismatch')

  local b2, e2 = coordinator_api.prepareActivation({
    manifest = manifest, ledger = l,
    extensionCatalog = catalogWith({abiVersion = 1, revertTokenVersion = 3}),
  })
  expect(b2 == nil and tostring(e2[1]):find('revertTokenVersion mismatch', 1, true) ~= nil,
    'prepareActivation did not reject saved op revertTokenVersion mismatch')

  local b3, e3 = coordinator_api.prepareActivation({
    manifest = manifest, ledger = l,
    extensionCatalog = catalogWith({
      abiVersion = 1, revertTokenVersion = 2,
      validateStoredState = function() return false, 'corrupt token' end,
    }),
  })
  expect(b3 == nil and tostring(e3[1]):find('corrupt token', 1, true) ~= nil,
    'prepareActivation did not enforce validateStoredState on saved op token')

  local b4 = coordinator_api.prepareActivation({
    manifest = manifest, ledger = l,
    extensionCatalog = catalogWith({
      abiVersion = 1, revertTokenVersion = 2,
      validateStoredState = function(_, tok) return tok and tok.ok == true end,
    }),
  })
  expect(b4 ~= nil, 'prepareActivation rejected compatible saved op')
end

local function scopedDirtyOwnerAndExternalGuardIsolation()
  local guards_api = require('scripts.mom.runtime.guards')
  -- 1. External guard program mutation isolation + weather region filtering.
  local gManifest = {
    ownerIds = {'o_ext', 'o_w'},
    ownersById = {
      o_ext = {
        id = 'o_ext',
        guard = {op = 'all', fragments = {{family = 'ext.toggle', program = {expected = 1}}}},
        actionIds = {}, subscriptions = {'external:ext:changed'},
      },
      o_w = {
        id = 'o_w',
        guard = {op = 'all', fragments = {{family = 'weather', program = {region = 'bitter coast region'}}}},
        actionIds = {}, subscriptions = {'weatherChanged:bitter coast region'},
      },
    },
  }
  local g = assert(guards_api.new(gManifest, {
    byId = {
      ['ext.toggle'] = {
        module = {
          providerInterface = 'ExtProvider',
          evaluate = function(prog)
            local ok = prog.expected == 1
            prog.expected = 999 -- buggy mutation must not leak to next eval!
            return {state = ok and 'active' or 'inactive'}
          end,
        },
      },
      weather = {module = {evaluate = function() return {state = 'active'} end}},
    },
  }))
  expect(type(g.watchedWeatherRegions) == 'table'
      and g.watchedWeatherRegions['bitter coast region'] == true
      and g.watchedWeatherRegions['ascadian isles region'] == nil,
    'guards did not narrow watchedWeatherRegions to subscribed regions')
  g.evaluateDue(1, {})
  expect(g.truth('o_ext') == 'active', 'first external guard eval failed')
  g.markDirty('o_ext')
  g.evaluateDue(2, {})
  expect(g.truth('o_ext') == 'active', 'external guard program mutation leaked across evaluations')

  -- 2. Scoped dirty-owner reconciliation: toggling 1 of 16 owners scans only that 1 owner!
  local cellFacts = {
    id = 'Balmora', idLower = 'balmora', key = 'balmora', interiorKey = 'balmora',
    name = 'Balmora', nameLower = 'balmora', displayNameLower = 'balmora',
    isExterior = false, worldspaceKey = 'sys::default',
  }
  local refs, byId = {}, {}
  local actionIds, actionsById, ownerIds, ownersById = {}, {}, {}, {}
  local activeFlags = {}
  for i = 1, 16 do
    local tid = string.format('content:%06x:morrowind.esm', i)
    local rec = 'rec_' .. tostring(i)
    local ref = {id = tid, recordId = rec, enabled = true}
    refs[i] = ref
    byId[tid] = ref
    local aid, oid = 'act:' .. tostring(i), 'own:' .. tostring(i)
    activeFlags[oid] = true
    actionIds[i] = aid
    ownerIds[i] = oid
    actionsById[aid] = {
      id = aid, family = 'test_mod', lifecycle = 'state', scope = 'ref', ownerId = oid,
      reversible = true, priority = i, specificity = 1, order = i, chance = 1,
      claims = {keys = {'ref.enabled'}}, selection = {exactIds = {rec}, candidateTypes = {Static = true}},
      program = {}, childIds = {},
    }
    ownersById[oid] = {
      id = oid, actionIds = {aid}, subscriptions = {'evt:' .. oid},
      guard = {op = 'all', fragments = {{family = 'flag', program = {owner = oid}}}},
    }
  end
  local matchCalls = 0
  local mod = {
    matchesTarget = function() matchCalls = matchCalls + 1; return true end,
    capture = function(_, r) return {enabled = r.enabled} end,
    apply = function(_, r) r.enabled = false; return {status = 'applied', changedClaims = {'ref.enabled'}} end,
    revert = function(tok, r) r.enabled = tok.enabled; return {status = 'applied', changedClaims = {'ref.enabled'}} end,
  }
  local observed = {balmora = {handle = cellFacts, facts = cellFacts, routes = {'shared', 'interior:balmora'}}}
  local session = {
    world = {
      beginFrame = function() end, isValid = function(r) return r ~= nil end,
      observedCells = function() return observed end, getObservedCell = function(k) return observed[k] end,
      isCellFenced = function() return false end, cellRefs = function() return refs, nil end,
      describeRef = function(ref)
        return {id = ref.id, objectId = ref.id, recordId = ref.recordId, typeName = 'Static',
          position = {x = 0, y = 0, z = 0}, currentCell = cellFacts, cell = cellFacts,
          origin = {cellId = 'balmora', cell = cellFacts, position = {x = 0, y = 0, z = 0}}}, nil
      end,
      resolveTarget = function(id) return byId[id] end, resolveCell = function() return cellFacts end,
    },
    guardCapabilities = {},
    beginFrame = function() end, syncObservedCells = function() return {}, {} end,
    pollGuardEvents = function() return {} end, clear = function() end,
  }
  local manifest = {
    contentHash = 'mom64:scoped', actionIds = actionIds, actionsById = actionsById,
    ownerIds = ownerIds, ownersById = ownersById,
    indexes = {staticByCell = {}, ownersByCell = {}, ownersByEvent = {}},
    extensions = {actions = {}, guards = {}, compat = {}},
  }
  local bundle = assert(coordinator_api.prepareActivation({
    manifest = manifest,
    extensionCatalog = {
      actions = {byId = {test_mod = {module = mod}}},
      guards = {byId = {flag = {module = {evaluate = function(p) return {state = activeFlags[p.owner] and 'active' or 'inactive'} end}}}},
    },
  }))
  local rt = assert(coordinator_api.new({activationBundle = bundle, ledger = ledger_api.new(), session = session}))
  coordinator_api.tick(rt, {frame = 1})
  expect(rt.ledger:opCount() == 16, 'initial tick did not apply all 16 owners')

  -- Deactivate ONLY owner #8; discovery should NOT run on deactivation.
  matchCalls = 0
  activeFlags['own:8'] = false
  coordinator_api.enqueueEvent(rt, 'evt:own:8')
  coordinator_api.tick(rt, {frame = 2})
  expect(refs[8].enabled == true and matchCalls == 0,
    'deactivating 1 owner unnecessarily ran discovery (matchCalls=' .. tostring(matchCalls) .. ')')
  -- Settle the cell-level post-revert check on frame 3 so frame 4 is a pure dirty-owner wakeup.
  coordinator_api.tick(rt, {frame = 3})

  matchCalls = 0
  activeFlags['own:8'] = true
  coordinator_api.enqueueEvent(rt, 'evt:own:8')
  coordinator_api.tick(rt, {frame = 4})
  expect(refs[8].enabled == false and matchCalls == 1,
    're-activating 1 owner scanned beyond its dirty scope (matchCalls=' .. tostring(matchCalls) .. ')')
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
    {'app lifecycle dormant fast path legacy reset and selfcheck', appLifecycleAndSelfcheck},
    {'deferred revert exponential backoff and cell-entry wake', deferredRevertBackoffAndCellWake},
    {'mid-apply rollback across action families', midApplyRollbackAcrossActions},
    {'saved op extension version and validateStoredState gate', savedOpVersionAndValidateStoredStateGate},
    {'scoped dirty-owner reconciliation and external guard isolation', scopedDirtyOwnerAndExternalGuardIsolation},
    {'stress 200-target cell reconciliation', stressReconcile200TargetsInCell, {stress = true}},
  })
end

return M
