-- Unified static, state, and recursive child reconciliation engine with
-- per-cell static fences and bounded per-tick work budgets.
local M = {}

local arbiter = require('scripts.mom.runtime.arbiter')
local identity = require('scripts.mom.ledger.identity')
local openmw_api = require('scripts.mom.openmw.api')
local ref_position = require('scripts.mom.domain.ref.position')
local ref_selector = require('scripts.mom.contracts.ref_selector')
local selection_matcher = require('scripts.mom.runtime.selection_matcher')
local static_plan_identity = require('scripts.mom.contracts.static_plan_identity')
local strings = require('scripts.mom.common.strings')

local lower = strings.lowerString
local property = openmw_api.property

local DEFAULT_BUDGETS = {
  discoveryLimit = 512,
  mutationLimit = 64,
  pendingLimit = 32,
  cellLimit = 8,
}

local function buildActionMeta(manifest)
  local meta = {}
  for _, actionId in ipairs(manifest.actionIds or {}) do
    local action = manifest.actionsById[actionId]
    local sel = action.selection or {}
    local exactIds = nil
    local hasExact = false
    if type(sel.exactIds) == 'table' and #sel.exactIds > 0 then
      exactIds = {}
      for i = 1, #sel.exactIds do
        local k = lower(sel.exactIds[i])
        if k then exactIds[k] = true; hasExact = true end
      end
    end
    local exactIdsByType = nil
    if type(sel.exactIdQueries) == 'table' and #sel.exactIdQueries > 0 then
      exactIdsByType = {}
      exactIds = exactIds or {}
      for i = 1, #sel.exactIdQueries do
        local q = sel.exactIdQueries[i]
        local k = q and lower(q.recordId)
        if k then
          exactIds[k] = true
          hasExact = true
          if type(q.typeName) == 'string' and q.typeName ~= '' then
            local bucket = exactIdsByType[q.typeName]
            if bucket == nil then bucket = {}; exactIdsByType[q.typeName] = bucket end
            bucket[k] = true
          end
        end
      end
      if next(exactIdsByType) == nil then exactIdsByType = nil end
    end
    local excludedIds = nil
    if type(sel.excludedIds) == 'table' and #sel.excludedIds > 0 then
      excludedIds = {}
      for i = 1, #sel.excludedIds do
        local k = lower(sel.excludedIds[i])
        if k then excludedIds[k] = true end
      end
    end
    local directByRecord = nil
    if type(sel.directTargets) == 'table' and #(sel.directTargets.entries or {}) > 0 then
      directByRecord = {}
      for i = 1, #sel.directTargets.entries do
        local e = sel.directTargets.entries[i]
        local k = lower(e.recordId)
        if k then
          local list = directByRecord[k]
          if list == nil then list = {}; directByRecord[k] = list end
          list[#list + 1] = e
        end
      end
    end
    local types = sel.candidateTypes
    if type(types) ~= 'table' or #types == 0 then types = nil end
    meta[actionId] = {
      exactIds = hasExact and exactIds or nil,
      exactIdsByType = exactIdsByType,
      excludedIds = excludedIds,
      directByRecord = directByRecord,
      candidateTypes = types,
      predicates = sel.predicates,
      query = sel.query,
      queryCells = sel.queryCells,
      additionalCells = sel.additionalCells,
    }
  end
  return meta
end

local function buildFootprintStaticIndex(manifest)
  local overlay = {}
  local function visitRoute(route, actionId)
    if type(route) ~= 'table' then return end
    if route.kind == 'union' then
      for i = 1, #(route.routes or {}) do visitRoute(route.routes[i], actionId) end
      return
    end
    if route.kind ~= 'footprint' then return end
    for i = 1, #(route.exteriors or {}) do
      local ext = route.exteriors[i]
      if type(ext) == 'table' and type(ext.worldspaceKey) == 'string' then
        local ws = ext.worldspaceKey:lower()
        for j = 1, #(ext.packedCellKeys or {}) do
          local key = 'exterior:' .. ws .. ':' .. tostring(ext.packedCellKeys[j])
          local list = overlay[key]
          if list == nil then list = {}; overlay[key] = list end
          list[#list + 1] = actionId
        end
      end
    end
  end
  for _, actionId in ipairs(manifest.actionIds or {}) do
    local act = manifest.actionsById[actionId]
    if act ~= nil and act.lifecycle == 'static' and act.parentId == nil then
      visitRoute(act.selection and act.selection.cell and act.selection.cell.route or nil, actionId)
    end
  end
  return overlay
end

local function matchesDirectTargets(directByRecord, recordId, facts)
  if directByRecord == nil then return true end
  local entries = directByRecord[recordId]
  if entries == nil then return false end
  local originPos = facts.origin and facts.origin.position or facts.position
  for i = 1, #entries do
    local e = entries[i]
    if (e.typeName == nil or e.typeName == facts.typeName)
        and (e.sourcePosition == nil
          or (originPos ~= nil and ref_position.positionsEqual(e.sourcePosition, originPos))) then
      return true
    end
  end
  return false
end

local function claimsOverlap(a, b)
  if type(a) ~= 'table' or type(b) ~= 'table' then return false end
  for i = 1, #a do
    local key = a[i]
    if key ~= 'output.existence' then
      for j = 1, #b do
        if b[j] == key then return true end
      end
    end
  end
  return false
end

function M.new(opts)
  local manifest = assert(opts.manifest, 'reconciler requires manifest')
  local ledger = assert(opts.ledger, 'reconciler requires ledger')
  local session = assert(opts.session, 'reconciler requires session')
  local guards = assert(opts.guards, 'reconciler requires guards')
  local executor = assert(opts.executor, 'reconciler requires executor')
  local actionModules = assert(opts.actionModules, 'reconciler requires actionModules')
  local targetFilters = opts.targetFilters or {}

  local budgets = opts.budgets or DEFAULT_BUDGETS
  local discoveryRevisions = static_plan_identity.discoveryRevisions(manifest)
  local actionMeta = buildActionMeta(manifest)
  local footprintStaticOverlay = buildFootprintStaticIndex(manifest)

  local staticQueue = {}         -- cellKey -> true (cells needing static evaluation)
  local staticSettled = {}       -- cellKey -> true (per-cell static fence cleared)
  local staticPlanCache = {}     -- cellKey -> { actionIds, planHash }
  local doorOriginsCaptured = {} -- cellKey -> true (proactive Door starting-transform capture)
  local stateDirty = true        -- reconcile state on startup + whenever guards/cells/ops change
  local staticFailureCount = 0
  local blockersSample = {}

  -- Precompute transform-touching actions that may target Doors so we capture
  -- Door starting transforms on cell entry before external scripts or guards
  -- teleport them (OpenMW overwrites startingPosition/startingRotation on teleport).
  local doorTransformActions = {}
  for _, actionId in ipairs(manifest.actionIds or {}) do
    local act = manifest.actionsById[actionId]
    local keys = act and act.claims and act.claims.keys or {}
    local touchesTransform = false
    for i = 1, #keys do
      if keys[i] == 'ref.position' or keys[i] == 'ref.rotation' then
        touchesTransform = true
        break
      end
    end
    if touchesTransform then
      local meta = actionMeta[actionId]
      local allowsDoor = meta.candidateTypes == nil
      if not allowsDoor then
        for i = 1, #meta.candidateTypes do
          if meta.candidateTypes[i] == 'Door' then allowsDoor = true; break end
        end
      end
      if allowsDoor then
        doorTransformActions[#doorTransformActions + 1] = act
      end
    end
  end

  local function captureDoorOriginsInCell(entry)
    local key = entry.facts.key
    if #doorTransformActions == 0 or doorOriginsCaptured[key] then return end
    local matching = {}
    for i = 1, #doorTransformActions do
      local act = doorTransformActions[i]
      if selection_matcher.cellMatches(act.selection, entry.facts) == true then
        matching[#matching + 1] = act
      end
    end
    doorOriginsCaptured[key] = true
    if #matching == 0 then return end
    local doors = session.world.cellRefs(entry.handle, 'Door')
    if doors == nil or #doors == 0 then return end
    for di = 1, #doors do
      local door = doors[di]
      if session.world.isValid(door) then
        local rawRec = lower(property(door, 'recordId'))
        local relevant = false
        for ai = 1, #matching do
          local meta = actionMeta[matching[ai].id]
          if (meta.exactIds == nil or (rawRec ~= nil and meta.exactIds[rawRec]))
              and (meta.excludedIds == nil or rawRec == nil or not meta.excludedIds[rawRec]) then
            relevant = true
            break
          end
        end
        if relevant then
          local facts = session.world.describeRef(door, ledger)
          if facts ~= nil and facts.typeName == 'Door' then
            local existing = ledger:getRef(facts.id)
            if existing == nil or existing.origin == nil then
              local starting = session.refOps.readStarting(door, ledger, facts.id)
              local cellKey = starting and starting.cell and (starting.cell.key or starting.cell.id)
              if starting ~= nil and cellKey ~= nil and starting.position ~= nil and starting.rotation ~= nil then
                local origin = {
                  cellId = cellKey:lower(),
                  position = {x = starting.position.x, y = starting.position.y, z = starting.position.z},
                  rotation = {
                    yaw = starting.rotation.yaw or 0,
                    pitch = starting.rotation.pitch or 0,
                    roll = starting.rotation.roll or 0,
                  },
                }
                if existing == nil then
                  ledger:putRef({
                    kind = 'ref',
                    id = facts.id,
                    objectId = facts.objectId,
                    recordId = facts.recordId,
                    typeName = 'Door',
                    cellKey = origin.cellId,
                    origin = origin,
                  })
                else
                  existing.origin = origin
                  ledger:putRef(existing)
                end
              end
            end
          end
        end
      end
    end
  end

  local function cellMatchesSelection(selection, cellFacts)
    if selection_matcher.cellMatches(selection, cellFacts) ~= true then return false end
    for _, extra in ipairs(selection and selection.additionalCells or {}) do
      if selection_matcher.cellMatches({cell = extra}, cellFacts) ~= true then return false end
    end
    return true
  end

  local function staticActionsForCell(entry)
    local key = entry.facts.key
    local cached = staticPlanCache[key]
    if cached ~= nil then return cached.actionIds, cached.planHash end
    local byCell = manifest.indexes and manifest.indexes.staticByCell or {}
    local seen, ids = {}, {}
    local function addFrom(list)
      if list == nil then return end
      for j = 1, #list do
        local id = list[j]
        local act = manifest.actionsById[id]
        if act ~= nil and act.parentId == nil and not seen[id]
            and cellMatchesSelection(act.selection, entry.facts) then
          seen[id] = true
          ids[#ids + 1] = id
        end
      end
    end
    for i = 1, #(entry.routes or {}) do
      local route = entry.routes[i]
      addFrom(byCell[route])
      addFrom(footprintStaticOverlay[route])
    end
    table.sort(ids)
    local disc = {}
    for i = 1, #ids do
      local rev = discoveryRevisions[ids[i]]
      if rev ~= nil then disc[#disc + 1] = {ids[i], rev} end
    end
    local hash = static_plan_identity.assertHash(ids, nil, #disc > 0 and disc or nil)
    staticPlanCache[key] = {actionIds = ids, planHash = hash}
    return ids, hash
  end

  local function buildChoiceCtx(frame, actionId, targetId, target, facts, authoredRecordId)
    return {
      frame = frame,
      actionId = actionId,
      targetId = targetId,
      target = target,
      targetFacts = facts,
      authoredRecordId = authoredRecordId,
      ledger = ledger,
      world = session.world,
      refOps = session.refOps,
      inventoryOps = session.inventoryOps,
      placementOps = session.placementOps,
      choicePort = session.choicePort,
    }
  end

  local function evaluateRootRefMatch(action, meta, mod, targetFilter, ref, facts, cellEntry, frame)
    -- Prevent self-recursion and re-replacing MOM-generated mesh-variant outputs,
    -- while allowing standalone root actions (e.g. kill_actor) to target MOM-placed refs!
    if facts.isGenerated then
      local outId = ledger:getOutputIdByObjectId(facts.objectId)
      if outId ~= nil then
        local stored = ledger:getRef(outId)
        local prodOp = stored and stored.producerId and ledger:getOp(stored.producerId) or nil
        if prodOp ~= nil and prodOp.actionId == action.id then return false end
        if action.family == 'place_ref' and action.program and action.program.mode == 'relative' then
          return false
        end
      end
    end
    if meta.query ~= nil and not ref_selector.matchesReference(meta.query, facts.objectId) then
      return false
    end
    if meta.exactIdsByType ~= nil then
      local byType = meta.exactIdsByType[facts.typeName]
      if byType == nil or not byType[facts.recordId] then return false end
    elseif meta.exactIds ~= nil and not meta.exactIds[facts.recordId] then
      return false
    end
    if meta.excludedIds ~= nil and meta.excludedIds[facts.recordId] then return false end
    if not matchesDirectTargets(meta.directByRecord, facts.recordId, facts) then return false end
    if meta.predicates ~= nil and #meta.predicates > 0
        and selection_matcher.matchesPredicates(meta.predicates, facts) ~= true then
      return false
    end
    if meta.query ~= nil then
      local info = session.placementOps.sourceRecordInfo(facts.typeName, ref)
      if not ref_selector.matchesRecord(meta.query, facts.recordId, facts.typeName, info and info.mwscript or nil) then
        return false
      end
    end
    if targetFilter ~= nil
        and targetFilter(facts, session.choicePort, buildChoiceCtx(frame, action.id, facts.id, ref, facts)) ~= true then
      return false
    end
    if mod ~= nil and type(mod.matchesTarget) == 'function'
        and mod.matchesTarget(action.program, ref, facts, buildChoiceCtx(frame, action.id, facts.id, ref, facts)) ~= true then
      return false
    end
    return true
  end

  local function discoverRootTargetsInCell(action, cellEntry, frame, counter)
    local out = {}
    if action.scope == 'cell' then
      if cellMatchesSelection(action.selection, cellEntry.facts) then
        out[1] = {
          targetId = identity.cellId(cellEntry.facts.key),
          target = cellEntry.handle,
          facts = cellEntry.facts,
          cellKey = cellEntry.facts.key,
        }
      end
      return out, false
    end

    if not cellMatchesSelection(action.selection, cellEntry.facts) then
      return out, false
    end
    if session.world.isCellFenced(cellEntry.facts.key, frame) then
      return out, true -- fenced; retry next frame
    end

    local meta = actionMeta[action.id]
    local mod = actionModules[action.family]
    local targetFilter = targetFilters[action.id]
    local typesList = meta.candidateTypes or {false}
    local seenIds = {}

    for ti = 1, #typesList do
      local typeName = typesList[ti] or nil
      local refs = session.world.cellRefs(cellEntry.handle, typeName)
      if refs ~= nil then
        for ri = 1, #refs do
          counter.discovery = counter.discovery + 1
          local ref = refs[ri]
          if session.world.isValid(ref) then
            local passFast = true
            if meta.exactIds ~= nil or meta.excludedIds ~= nil then
              local rawRec = lower(property(ref, 'recordId'))
              if rawRec == nil then
                passFast = false
              elseif meta.exactIds ~= nil and not meta.exactIds[rawRec] then
                passFast = false
              elseif meta.excludedIds ~= nil and meta.excludedIds[rawRec] then
                passFast = false
              end
            end
            if passFast then
              local facts = session.world.describeRef(ref, ledger)
              if facts ~= nil and not seenIds[facts.id]
                  and evaluateRootRefMatch(action, meta, mod, targetFilter, ref, facts, cellEntry, frame) then
                seenIds[facts.id] = true
                out[#out + 1] = {
                  targetId = facts.id,
                  target = ref,
                  facts = facts,
                  cellKey = cellEntry.facts.key,
                }
              end
            end
          end
        end
      end
    end
    return out, false
  end

  local function matchesSingleRootRef(action, cellEntry, ref, frame)
    if action.scope == 'cell' then return nil end
    if not cellMatchesSelection(action.selection, cellEntry.facts) then return nil end
    local meta = actionMeta[action.id]
    local rawRec = lower(property(ref, 'recordId'))
    if rawRec == nil then return nil end
    if meta.exactIds ~= nil and not meta.exactIds[rawRec] then return nil end
    if meta.excludedIds ~= nil and meta.excludedIds[rawRec] then return nil end
    local facts = session.world.describeRef(ref, ledger)
    if facts == nil then return nil end
    if meta.candidateTypes ~= nil then
      local typeOk = false
      for i = 1, #meta.candidateTypes do
        if meta.candidateTypes[i] == facts.typeName then typeOk = true; break end
      end
      if not typeOk then return nil end
    end
    local mod = actionModules[action.family]
    local targetFilter = targetFilters[action.id]
    if not evaluateRootRefMatch(action, meta, mod, targetFilter, ref, facts, cellEntry, frame) then
      return nil
    end
    return {
      targetId = facts.id,
      target = ref,
      facts = facts,
      cellKey = cellEntry.facts.key,
    }
  end

  local function discoverChildTargets(childAction, parentOp, frame)
    local out = {}
    local meta = actionMeta[childAction.id]
    local mod = actionModules[childAction.family]
    local targetFilter = targetFilters[childAction.id]
    local outputs = parentOp.outputs or {}

    for i = 1, #outputs do
      local outputId = outputs[i]
      local stored = ledger:getRef(outputId)
      local ref = session.world.resolveTarget(outputId, ledger)
      if stored ~= nil and ref ~= nil and session.world.isValid(ref) then
        local facts = session.world.describeRef(ref, ledger)
        if facts ~= nil then
          local authoredRecId = lower(stored.recordId) or facts.recordId
          local checkFacts = facts
          if authoredRecId ~= facts.recordId then
            checkFacts = {}
            for k, v in pairs(facts) do checkFacts[k] = v end
            checkFacts.recordId = authoredRecId
          end
          local ok = true
          if childAction.selection and childAction.selection.cell ~= nil and checkFacts.currentCell ~= nil then
            ok = selection_matcher.cellMatches(childAction.selection, checkFacts.currentCell) == true
          end
          if ok and meta.candidateTypes ~= nil then
            local typeOk = false
            for t = 1, #meta.candidateTypes do
              if meta.candidateTypes[t] == checkFacts.typeName then typeOk = true; break end
            end
            ok = typeOk
          end
          if ok and meta.exactIds ~= nil and not meta.exactIds[authoredRecId] then ok = false end
          if ok and meta.excludedIds ~= nil and meta.excludedIds[authoredRecId] then ok = false end
          if ok and not matchesDirectTargets(meta.directByRecord, authoredRecId, checkFacts) then ok = false end
          if ok and meta.predicates ~= nil and #meta.predicates > 0 then
            ok = selection_matcher.matchesPredicates(meta.predicates, checkFacts) == true
          end
          local ctx = buildChoiceCtx(frame, childAction.id, outputId, ref, checkFacts, authoredRecId)
          if ok and targetFilter ~= nil then
            ok = targetFilter(checkFacts, session.choicePort, ctx) == true
          end
          if ok and mod ~= nil and type(mod.matchesTarget) == 'function' then
            ok = mod.matchesTarget(childAction.program, ref, checkFacts, ctx) == true
          end
          if ok then
            out[#out + 1] = {
              targetId = outputId,
              target = ref,
              facts = checkFacts,
              cellKey = (checkFacts.currentCell and checkFacts.currentCell.key) or parentOp.cellKey,
            }
          end
        end
      end
    end
    return out
  end

  local function collectDescendants(opId, out, depth)
    local children = ledger:opsForParent(opId)
    if children == nil then return end
    for childId in pairs(children) do
      local child = ledger:getOp(childId)
      if child ~= nil then
        collectDescendants(childId, out, depth + 1)
        out[#out + 1] = {op = child, depth = depth + 1, semanticId = child.semanticId}
      end
    end
  end

  local function findStaticTransitionSource(action, targetId)
    local ops = ledger:opsForTarget(targetId)
    if ops == nil then return nil, nil end
    local matches = {}
    local actionClaims = action.claims and action.claims.keys or {}
    for opId in pairs(ops) do
      local op = ledger:getOp(opId)
      if op ~= nil and op.lifecycle == 'static' and op.state == 'applied'
          and op.actionId ~= action.id and manifest.actionsById[op.actionId] == nil
          and op.family == action.family
          and claimsOverlap(op.claims, actionClaims) then
        matches[#matches + 1] = op
      end
    end
    if #matches == 0 then return nil, nil end
    if #matches > 1 then return nil, 'ambiguous' end
    return matches[1], nil
  end

  -- Recursively reconciles child actions of applied parent ops for either lifecycle.
  local function reconcileChildren(parentOps, lifecycle, frame, counter)
    local frontier = parentOps
    local depth = 1
    while #frontier > 0 and depth <= 16 do
      local candidates = {}
      local desiredSemantics = {}
      local existingBySemantic = {}

      for pi = 1, #frontier do
        local parentOp = frontier[pi]
        local parentAction = manifest.actionsById[parentOp.actionId]
        if parentAction ~= nil and #(parentAction.childIds or {}) > 0 and #(parentOp.outputs or {}) > 0 then
          for ci = 1, #parentAction.childIds do
            local childAction = manifest.actionsById[parentAction.childIds[ci]]
            if childAction ~= nil and childAction.lifecycle == lifecycle then
              local targets = discoverChildTargets(childAction, parentOp, frame)
              for ti = 1, #targets do
                local t = targets[ti]
                local semId = identity.semanticId(childAction.id, t.targetId, parentOp.id)
                desiredSemantics[semId] = true
                local existing = ledger:getOpBySemanticId(semId)
                if existing ~= nil then
                  existingBySemantic[semId] = {op = existing, action = childAction, target = t}
                else
                  local transitionSource = lifecycle == 'static'
                    and findStaticTransitionSource(childAction, t.targetId) or nil
                  candidates[#candidates + 1] = {
                    id = semId,
                    semanticId = semId,
                    action = childAction,
                    actionId = childAction.id,
                    targetId = t.targetId,
                    target = t.target,
                    facts = t.facts,
                    recordId = t.facts and t.facts.recordId or nil,
                    cellKey = t.cellKey,
                    parentOpId = parentOp.id,
                    depth = depth,
                    claims = childAction.claims and childAction.claims.keys or {},
                    conflict = childAction.claims and childAction.claims.conflict or nil,
                    priority = childAction.priority,
                    specificity = childAction.specificity,
                    order = childAction.order,
                    chance = childAction.chance,
                    replacesOpId = transitionSource and transitionSource.id or nil,
                    transitionSource = transitionSource,
                  }
                end
              end
            end
          end
        end
      end

      -- For state lifecycle, revert any existing child ops under `frontier` that are no longer desired.
      if lifecycle == 'state' then
        local toRevert = {}
        for pi = 1, #frontier do
          local children = ledger:opsForParent(frontier[pi].id)
          if children ~= nil then
            for childId in pairs(children) do
              local childOp = ledger:getOp(childId)
              if childOp ~= nil and childOp.lifecycle == 'state' and not desiredSemantics[childOp.semanticId] then
                collectDescendants(childId, toRevert, depth)
                toRevert[#toRevert + 1] = {op = childOp, depth = depth, semanticId = childOp.semanticId}
              end
            end
          end
        end
        local ordered = arbiter.orderCleanups(toRevert)
        for i = 1, #ordered do
          if counter.mutations >= budgets.mutationLimit then break end
          executor.revert(ordered[i].op, frame)
          counter.mutations = counter.mutations + 1
        end
      end

      local nextFrontier = {}
      -- Existing applied children remain eligible to drive grandchildren.
      for _, rec in pairs(existingBySemantic) do
        if rec.op.state == 'applied' then
          if lifecycle == 'static' and rec.op.reassertable then
            executor.reassert(rec.op, rec.action, rec.target.target, rec.target.facts, frame)
          end
          nextFrontier[#nextFrontier + 1] = rec.op
        end
      end

      if #candidates > 0 then
        local arb = arbiter.arbitrate(candidates, ledger:claimsForLifecycle(lifecycle))
        for i = 1, #arb.winners do
          if counter.mutations >= budgets.mutationLimit then break end
          local w = arb.winners[i]
          local res
          if w.transitionSource ~= nil then
            -- Revert any children of replaced static op first.
            local prevChildren = {}
            collectDescendants(w.transitionSource.id, prevChildren, depth)
            for ci = 1, #prevChildren do executor.revert(prevChildren[ci].op, frame) end
            res = executor.transition(w.transitionSource, w, w.target, w.facts, frame)
          else
            res = executor.apply(w, w.target, w.facts, frame)
          end
          counter.mutations = counter.mutations + 1
          if res.op ~= nil and res.op.state == 'applied' then
            nextFrontier[#nextFrontier + 1] = res.op
          elseif res.status == 'failed' and lifecycle == 'static' then
            staticFailureCount = staticFailureCount + 1
          end
        end
      end

      frontier = nextFrontier
      depth = depth + 1
    end
  end

  local function cellHasPendingOps(cellKey, lifecycle)
    local ops = ledger:opsForCell(cellKey)
    if ops == nil then return false end
    for opId in pairs(ops) do
      local op = ledger:getOp(opId)
      if op ~= nil and op.lifecycle == lifecycle
          and (op.state == 'pending' or op.state == 'reverting') then
        return true
      end
    end
    return false
  end

  local function reconcileStaticCell(cellKey, frame, counter)
    local entry = session.world.getObservedCell(cellKey)
    if entry == nil then
      staticQueue[cellKey] = nil
      return true
    end
    captureDoorOriginsInCell(entry)
    local actionIds, planHash = staticActionsForCell(entry)
    local existingScan = ledger:getStaticScan(cellKey)
    if existingScan ~= nil and existingScan.planHash == planHash and not cellHasPendingOps(cellKey, 'static') then
      -- Cell already scanned for this exact static plan; reassert any starting-transform ops once on entry.
      local ops = ledger:opsForCell(cellKey)
      if ops ~= nil then
        for opId in pairs(ops) do
          local op = ledger:getOp(opId)
          if op ~= nil and op.lifecycle == 'static' and op.state == 'applied' and op.reassertable then
            local act = manifest.actionsById[op.actionId]
            if act ~= nil then
              local ref = session.world.resolveTarget(op.targetId, ledger)
              if ref ~= nil then
                local facts = session.world.describeRef(ref, ledger)
                executor.reassert(op, act, ref, facts, frame)
              end
            end
          end
        end
      end
      staticQueue[cellKey] = nil
      staticSettled[cellKey] = true
      stateDirty = true
      return true
    end

    local candidates = {}
    local appliedParents = {}
    local fenced = false

    for i = 1, #actionIds do
      local action = manifest.actionsById[actionIds[i]]
      if action ~= nil then
        local targets, wasFenced = discoverRootTargetsInCell(action, entry, frame, counter)
        if wasFenced then fenced = true end
        for ti = 1, #targets do
          local t = targets[ti]
          local semId = identity.semanticId(action.id, t.targetId, nil)
          local existing = ledger:getOpBySemanticId(semId)
          if existing ~= nil then
            if existing.state == 'applied' then
              appliedParents[#appliedParents + 1] = existing
            end
          else
            local transitionSource, transErr = findStaticTransitionSource(action, t.targetId)
            if transErr == nil then
              candidates[#candidates + 1] = {
                id = semId,
                semanticId = semId,
                action = action,
                actionId = action.id,
                targetId = t.targetId,
                target = t.target,
                facts = t.facts,
                recordId = t.facts and t.facts.recordId or nil,
                cellKey = cellKey,
                parentOpId = nil,
                depth = 0,
                claims = action.claims and action.claims.keys or {},
                conflict = action.claims and action.claims.conflict or nil,
                priority = action.priority,
                specificity = action.specificity,
                order = action.order,
                chance = action.chance,
                replacesOpId = transitionSource and transitionSource.id or nil,
                transitionSource = transitionSource,
              }
            else
              staticFailureCount = staticFailureCount + 1
            end
          end
        end
      end
    end

    if fenced then return false end

    local hitBudget = false
    if #candidates > 0 then
      local arb = arbiter.arbitrate(candidates, ledger:claimsForLifecycle('static'))
      for i = 1, #arb.winners do
        if counter.mutations >= budgets.mutationLimit then
          hitBudget = true
          break
        end
        local w = arb.winners[i]
        local res
        if w.transitionSource ~= nil then
          local prevChildren = {}
          collectDescendants(w.transitionSource.id, prevChildren, 0)
          for ci = 1, #prevChildren do executor.revert(prevChildren[ci].op, frame) end
          res = executor.transition(w.transitionSource, w, w.target, w.facts, frame)
        else
          res = executor.apply(w, w.target, w.facts, frame)
        end
        counter.mutations = counter.mutations + 1
        if res.op ~= nil and res.op.state == 'applied' then
          appliedParents[#appliedParents + 1] = res.op
        elseif res.status == 'failed' then
          staticFailureCount = staticFailureCount + 1
        end
      end
    end

    if #appliedParents > 0 then
      reconcileChildren(appliedParents, 'static', frame, counter)
    end

    if not hitBudget and not cellHasPendingOps(cellKey, 'static') then
      ledger:setStaticScan(cellKey, {
        planHash = planHash,
        manifestHash = manifest.contentHash,
        completedFrame = frame,
      })
      staticQueue[cellKey] = nil
      staticSettled[cellKey] = true
      stateDirty = true
      return true
    end
    return false
  end

  local function reconcileState(frame, counter)
    local observed = session.world.observedCells()
    local settledCells = {}
    for key, entry in pairs(observed) do
      if staticSettled[key] == true or not staticQueue[key] then
        settledCells[#settledCells + 1] = entry
      end
    end
    table.sort(settledCells, function(a, b) return a.facts.key < b.facts.key end)

    -- 1. Build desired root state candidates across all ACTIVE owners and settled cells.
    local desiredCandidates = {}
    local desiredBySemantic = {}
    local anyFenced = false

    local function addStateCandidate(ownerId, action, t)
      local semId = identity.semanticId(action.id, t.targetId, nil)
      if not desiredBySemantic[semId] then
        local existing = ledger:getOpBySemanticId(semId)
        local cand = {
          id = semId,
          semanticId = semId,
          action = action,
          actionId = action.id,
          ownerId = ownerId,
          targetId = t.targetId,
          target = t.target,
          facts = t.facts,
          recordId = t.facts and t.facts.recordId or nil,
          cellKey = t.cellKey,
          parentOpId = nil,
          depth = 0,
          claims = action.claims and action.claims.keys or {},
          conflict = action.claims and action.claims.conflict or nil,
          priority = action.priority,
          specificity = action.specificity,
          order = action.order,
          chance = action.chance,
          existingOp = existing,
        }
        desiredBySemantic[semId] = cand
        desiredCandidates[#desiredCandidates + 1] = cand
      end
    end

    local function collectExactInteriorKeys(route, out, seen)
      if type(route) ~= 'table' then return end
      if route.kind == 'exact' then
        for i = 1, #(route.interiorKeys or {}) do
          local k = lower(route.interiorKeys[i])
          if k ~= nil and not seen[k] then
            seen[k] = true
            out[#out + 1] = k
          end
        end
      elseif route.kind == 'union' then
        for i = 1, #(route.routes or {}) do
          collectExactInteriorKeys(route.routes[i], out, seen)
        end
      end
    end

    local function hasObservedDescendantQueryCell(act, observedMap)
      for i = 1, #(act.childIds or {}) do
        local child = manifest.actionsById[act.childIds[i]]
        if child ~= nil then
          local qcs = child.selection and child.selection.queryCells
          if type(qcs) == 'table' then
            for qi = 1, #qcs do
              local qc = qcs[qi]
              local qk = qc and lower(qc.key or qc.id) or nil
              if qk ~= nil and observedMap[qk] then return true end
            end
          end
          if hasObservedDescendantQueryCell(child, observedMap) then return true end
        end
      end
      return false
    end

    for _, ownerId in ipairs(manifest.ownerIds or {}) do
      if guards.truth(ownerId) == 'active' then
        local owner = manifest.ownersById[ownerId]
        for ai = 1, #(owner.actionIds or {}) do
          local action = manifest.actionsById[owner.actionIds[ai]]
          if action ~= nil and action.parentId == nil then
            local seenCells = {}
            for ci = 1, #settledCells do
              seenCells[settledCells[ci].facts.key] = true
              local targets, wasFenced = discoverRootTargetsInCell(action, settledCells[ci], frame, counter)
              if wasFenced then anyFenced = true end
              for ti = 1, #targets do
                addStateCandidate(ownerId, action, targets[ti])
              end
            end
            -- Exact interior cell-scoped state actions resolve their target cell when
            -- previsit is requested or when a descendant relocates into an observed cell.
            if action.scope == 'cell' and action.selection and action.selection.cell
                and (action.previsit == true or hasObservedDescendantQueryCell(action, seenCells)) then
              local exactKeys = {}
              collectExactInteriorKeys(action.selection.cell.route, exactKeys, seenCells)
              for ki = 1, #exactKeys do
                local cellHandle = session.world.resolveCell(exactKeys[ki])
                local cellFacts = cellHandle ~= nil and session.world.describeCell(cellHandle) or nil
                if cellFacts ~= nil then
                  local entry = {handle = cellHandle, facts = cellFacts}
                  local targets, wasFenced = discoverRootTargetsInCell(action, entry, frame, counter)
                  if wasFenced then anyFenced = true end
                  for ti = 1, #targets do
                    addStateCandidate(ownerId, action, targets[ti])
                  end
                end
              end
            end
            -- If an action has a secondary queryCell (e.g. cross-cell relocate
            -- destination) currently observed and exact ref numbers in query.ref,
            -- resolve those exact refs even after the player already left the source cell.
            local meta = actionMeta[action.id]
            if meta and meta.query and meta.query.ref and meta.queryCells then
              local queryObserved = false
              for qi = 1, #meta.queryCells do
                local qc = meta.queryCells[qi]
                local qk = type(qc) == 'table' and (qc.interiorKey or qc.key or qc.id) or nil
                if qk ~= nil and observed[lower(qk) or ''] ~= nil then
                  queryObserved = true
                  break
                end
              end
              if queryObserved then
                local mod = actionModules[action.family]
                local targetFilter = targetFilters[action.id]
                local file = meta.query.ref.file
                for _, num in ipairs(meta.query.ref.numbers or {}) do
                  local refId = string.format('content:%06x:%s', num, file)
                  local ref = session.world.resolveTarget(refId, ledger)
                  if ref ~= nil and session.world.isValid(ref) then
                    local facts = session.world.describeRef(ref, ledger)
                    local originCell = facts and (facts.origin and facts.origin.cell or facts.currentCell) or nil
                    if facts ~= nil and originCell ~= nil
                        and cellMatchesSelection(action.selection, originCell)
                        and evaluateRootRefMatch(action, meta, mod, targetFilter, ref, facts, {facts = originCell}, frame) then
                      addStateCandidate(ownerId, action, {
                        targetId = facts.id,
                        target = ref,
                        facts = facts,
                        cellKey = originCell.key,
                      })
                    end
                  end
                end
              end
            end
          end
        end
      end
    end

    -- 1b. Retain currently-applied/pending root state ops whose guard is STILL active
    -- (e.g. a modify_ref op that relocated its target to another cell or disabled it).
    -- They still compete in arbitration if a higher-ranked candidate targets the same claims.
    local activeStateOps = ledger:opsForLifecycle('state')
    if activeStateOps ~= nil then
      for opId in pairs(activeStateOps) do
        local op = ledger:getOp(opId)
        if op ~= nil and op.parentOpId == nil
            and (op.state == 'applied' or op.state == 'pending')
            and not desiredBySemantic[op.semanticId] then
          local action = manifest.actionsById[op.actionId]
          if action ~= nil and op.ownerId ~= nil and manifest.ownersById[op.ownerId] ~= nil
              and guards.truth(op.ownerId) == 'active' then
            local cand = {
              id = op.semanticId,
              semanticId = op.semanticId,
              action = action,
              actionId = action.id,
              ownerId = op.ownerId,
              targetId = op.targetId,
              cellKey = op.cellKey,
              parentOpId = nil,
              depth = 0,
              claims = action.claims and action.claims.keys or {},
              conflict = action.claims and action.claims.conflict or nil,
              priority = action.priority,
              specificity = action.specificity,
              order = action.order,
              chance = action.chance,
              existingOp = op,
            }
            desiredBySemantic[op.semanticId] = cand
            desiredCandidates[#desiredCandidates + 1] = cand
          end
        end
      end
    end

    -- 2. Build occupied claims: unfinished static ops + unknown-owner state ops.
    -- Completed current static ops deliberately do NOT block state layering!
    local occupied = {}
    for opId, op in pairs(ledger.doc.ops) do
      local hold = false
      if op.lifecycle == 'static' then
        if op.state == 'pending' or op.state == 'reverting' then
          hold = true
        end
      elseif op.lifecycle == 'state' then
        if op.state == 'applied' or op.state == 'pending' or op.state == 'reverting' then
          local ownerExists = op.ownerId ~= nil and manifest.ownersById[op.ownerId] ~= nil
          if ownerExists and guards.truth(op.ownerId) == 'unknown' then
            hold = true
          end
        end
      end
      if hold then
        local byClaim = occupied[op.targetId]
        for j = 1, #(op.claims or {}) do
          local key = op.claims[j]
          if key ~= 'output.existence' then
            if byClaim == nil then byClaim = {}; occupied[op.targetId] = byClaim end
            byClaim[key] = opId
          end
        end
      end
    end

    local arb = arbiter.arbitrate(desiredCandidates, occupied)
    local winningSemantics = {}
    for i = 1, #arb.winners do
      winningSemantics[arb.winners[i].semanticId] = arb.winners[i]
    end
    blockersSample = {}
    for i = 1, math.min(#arb.blocked, 16) do
      blockersSample[i] = arb.blocked[i].candidate.semanticId
    end

    -- 3. Revert stale, inactive, or superseded root state ops (deepest children first!).
    local cleanupMap = {}
    local cleanupList = {}
    local function markRevert(op, depth)
      if cleanupMap[op.id] then return end
      cleanupMap[op.id] = true
      collectDescendants(op.id, cleanupList, depth)
      cleanupList[#cleanupList + 1] = {op = op, depth = depth, semanticId = op.semanticId}
    end

    local stateOps = ledger:opsForLifecycle('state')
    if stateOps ~= nil then
      for opId in pairs(stateOps) do
        local op = ledger:getOp(opId)
        if op ~= nil and op.parentOpId == nil and (op.state == 'applied' or op.state == 'pending') then
          local actionInManifest = manifest.actionsById[op.actionId] ~= nil
          local ownerInManifest = op.ownerId ~= nil and manifest.ownersById[op.ownerId] ~= nil
          if not actionInManifest or not ownerInManifest then
            -- Stale op from previous manifest (e.g. startup_plan_change_restart).
            markRevert(op, 0)
          else
            local truth = guards.truth(op.ownerId)
            if truth == 'inactive' then
              markRevert(op, 0)
            elseif truth == 'active' and winningSemantics[op.semanticId] == nil then
              -- Only revert if the op's cell is currently observed (don't revert ops in unloaded cells!).
              if op.cellKey == nil or session.world.getObservedCell(op.cellKey) ~= nil then
                markRevert(op, 0)
              end
            end
          end
        end
      end
    end

    local orderedCleanups = arbiter.orderCleanups(cleanupList)
    local hitBudget = false
    for i = 1, #orderedCleanups do
      if counter.mutations >= budgets.mutationLimit then
        hitBudget = true
        break
      end
      local entry = orderedCleanups[i]
      if ledger:getOp(entry.op.id) ~= nil then
        -- Wait if any descendant still exists (e.g. pending revert).
        local stillHasChildren = ledger:opsForParent(entry.op.id) ~= nil
        if not stillHasChildren then
          executor.revert(entry.op, frame)
          counter.mutations = counter.mutations + 1
        end
      end
    end

    -- 4. Apply winning desired root state ops that are not yet applied!
    local appliedParents = {}
    for i = 1, #arb.winners do
      local w = arb.winners[i]
      local existing = ledger:getOpBySemanticId(w.semanticId)
      if existing ~= nil then
        if existing.state == 'applied' then
          appliedParents[#appliedParents + 1] = existing
        end
      else
        -- Ensure state claims are genuinely free right now (in case a loser is still pending revert).
        local blockedNow = false
        for j = 1, #(w.claims or {}) do
          if ledger:claimOwner('state', w.targetId, w.claims[j]) ~= nil then
            blockedNow = true
            break
          end
        end
        if not blockedNow then
          if counter.mutations >= budgets.mutationLimit then
            hitBudget = true
            break
          end
          local res = executor.apply(w, w.target, w.facts, frame)
          counter.mutations = counter.mutations + 1
          if res.op ~= nil and res.op.state == 'applied' then
            appliedParents[#appliedParents + 1] = res.op
          end
        end
      end
    end

    -- 5. Recursively reconcile child state ops on all applied root state parents!
    if #appliedParents > 0 then
      reconcileChildren(appliedParents, 'state', frame, counter)
    end

    if not hitBudget and not anyFenced then
      stateDirty = false
    end
  end

  local pendingActiveObjects = {}

  local function reconcileActiveObjects(frame, counter)
    if #pendingActiveObjects == 0 then return end
    local batch = pendingActiveObjects
    pendingActiveObjects = {}
    local candidates = {}
    local appliedParents = {}
    for bi = 1, #batch do
      local item = batch[bi]
      local ref = item.ref
      local cellKey = item.cellKey
      if session.world.isValid(ref) then
        local entry = session.world.getObservedCell(cellKey)
        if entry ~= nil and staticSettled[cellKey] == true then
          local actionIds = staticActionsForCell(entry)
          for i = 1, #actionIds do
            local action = manifest.actionsById[actionIds[i]]
            if action ~= nil then
              local t = matchesSingleRootRef(action, entry, ref, frame)
              if t ~= nil then
                local semId = identity.semanticId(action.id, t.targetId, nil)
                local existing = ledger:getOpBySemanticId(semId)
                if existing ~= nil then
                  if existing.state == 'applied' then
                    if existing.reassertable then
                      executor.reassert(existing, action, t.target, t.facts, frame)
                    end
                    appliedParents[#appliedParents + 1] = existing
                  end
                else
                  local transitionSource, transErr = findStaticTransitionSource(action, t.targetId)
                  if transErr == nil then
                    candidates[#candidates + 1] = {
                      id = semId,
                      semanticId = semId,
                      action = action,
                      actionId = action.id,
                      targetId = t.targetId,
                      target = t.target,
                      facts = t.facts,
                      recordId = t.facts and t.facts.recordId or nil,
                      cellKey = cellKey,
                      parentOpId = nil,
                      depth = 0,
                      claims = action.claims and action.claims.keys or {},
                      conflict = action.claims and action.claims.conflict or nil,
                      priority = action.priority,
                      specificity = action.specificity,
                      order = action.order,
                      chance = action.chance,
                      replacesOpId = transitionSource and transitionSource.id or nil,
                      transitionSource = transitionSource,
                    }
                  end
                end
              end
            end
          end
        end
      end
    end
    if #candidates > 0 then
      local arb = arbiter.arbitrate(candidates, ledger:claimsForLifecycle('static'))
      for i = 1, #arb.winners do
        if counter.mutations >= budgets.mutationLimit then break end
        local w = arb.winners[i]
        local res = w.transitionSource ~= nil
          and executor.transition(w.transitionSource, w, w.target, w.facts, frame)
          or executor.apply(w, w.target, w.facts, frame)
        counter.mutations = counter.mutations + 1
        if res.op ~= nil and res.op.state == 'applied' then
          appliedParents[#appliedParents + 1] = res.op
        end
      end
    end
    if #appliedParents > 0 then
      reconcileChildren(appliedParents, 'static', frame, counter)
    end
  end

  local rec = {}

  function rec.enqueueCell(cellKey)
    if type(cellKey) ~= 'string' or cellKey == '' then return end
    staticQueue[cellKey] = true
    stateDirty = true
  end

  function rec.observeActiveObject(object, cellKey)
    if object == nil or type(cellKey) ~= 'string' or cellKey == '' then return end
    pendingActiveObjects[#pendingActiveObjects + 1] = {ref = object, cellKey = cellKey}
    stateDirty = true
  end

  function rec.markStateDirty()
    stateDirty = true
  end

  function rec.step(frame)
    local counter = {discovery = 0, mutations = 0, pending = 0}

    -- 1. Advance due pending/reverting operations.
    local duePending = {}
    for opId, nextFrame in pairs(ledger:pendingOps()) do
      if nextFrame <= frame then duePending[#duePending + 1] = opId end
    end
    table.sort(duePending)
    for i = 1, #duePending do
      if counter.pending >= budgets.pendingLimit then break end
      local op = ledger:getOp(duePending[i])
      if op ~= nil then
        local status = executor.advancePending(op, frame)
        counter.pending = counter.pending + 1
        if status == 'applied' or status == 'reverted' or status == 'noop' then
          stateDirty = true
          if op.lifecycle == 'static' and op.cellKey ~= nil then
            staticQueue[op.cellKey] = true
          end
        end
      end
    end

    -- 2. Reconcile queued static cells (per-cell fence!).
    local cells = {}
    for key in pairs(staticQueue) do cells[#cells + 1] = key end
    table.sort(cells)
    local cellsDone = 0
    for i = 1, #cells do
      if cellsDone >= budgets.cellLimit or counter.mutations >= budgets.mutationLimit then break end
      reconcileStaticCell(cells[i], frame, counter)
      cellsDone = cellsDone + 1
    end

    -- 2b. Reconcile newly-activated foreign objects in already-settled cells.
    if #pendingActiveObjects > 0 and counter.mutations < budgets.mutationLimit then
      reconcileActiveObjects(frame, counter)
    end

    -- 3. Reconcile state ops if dirty.
    if stateDirty and counter.mutations < budgets.mutationLimit then
      reconcileState(frame, counter)
    end

    return counter
  end

  local localBroker = opts.localBroker

  function rec.status(options)
    local queuedStatic = 0
    for _ in pairs(staticQueue) do queuedStatic = queuedStatic + 1 end
    local staticOpsCount, stateOpsCount = 0, 0
    for _ in pairs(ledger:opsForLifecycle('static') or {}) do staticOpsCount = staticOpsCount + 1 end
    for _ in pairs(ledger:opsForLifecycle('state') or {}) do stateOpsCount = stateOpsCount + 1 end
    local scansComplete = 0
    for _ in pairs(ledger.doc.staticScans or {}) do scansComplete = scansComplete + 1 end
    local pendingCount = ledger:pendingCount()
    local inFlight = localBroker and localBroker.inFlightCount() or 0

    local opFilter = type(options) == 'table' and type(options.operation) == 'table' and options.operation or nil
    local opWorkCount, opWorkSamples = 0, {}
    local statusSet = nil
    if opFilter ~= nil and type(opFilter.statuses) == 'table' then
      statusSet = {}
      for i = 1, #opFilter.statuses do statusSet[opFilter.statuses[i]] = true end
    end
    local wantRecordId = opFilter and lower(opFilter.targetRecordId) or nil
    local opIds = {}
    for opId in pairs(ledger.doc.ops) do opIds[#opIds + 1] = opId end
    table.sort(opIds)
    for i = 1, #opIds do
      local op = ledger.doc.ops[opIds[i]]
      local ok = true
      if opFilter ~= nil then
        if opFilter.family ~= nil and op.family ~= opFilter.family then ok = false end
        if ok and statusSet ~= nil and not statusSet[op.state] then ok = false end
        if ok and opFilter.targetKind ~= nil then
          local isCell = op.targetId:sub(1, 5) == 'cell:'
          local isOutput = op.targetId:sub(1, 7) == 'output:'
          if opFilter.targetKind == 'cell' and not isCell then ok = false
          elseif opFilter.targetKind == 'output' and not isOutput then ok = false
          elseif opFilter.targetKind == 'ref' and isCell then ok = false
          end
        end
        if ok and wantRecordId ~= nil then
          local recId = lower(op.targetRecordId)
          if recId == nil then
            local storedRef = ledger:getRef(op.targetId)
            recId = storedRef and lower(storedRef.recordId) or nil
          end
          if recId == nil and op.targetId:sub(1, 5) ~= 'cell:' then
            local live = session.world.resolveTarget(op.targetId, ledger)
            local facts = live and session.world.describeRef(live, ledger) or nil
            recId = facts and lower(facts.recordId) or nil
          end
          if recId ~= wantRecordId then ok = false end
        end
      end
      if ok then
        opWorkCount = opWorkCount + 1
        if #opWorkSamples < 32 then
          opWorkSamples[#opWorkSamples + 1] = {
            producerId = op.producerId,
            semanticId = op.semanticId,
            ownerId = op.ownerId,
            actionId = op.actionId,
            family = op.family,
            lifecycle = op.lifecycle,
            durability = op.durability,
            status = op.state,
            phase = op.pending and op.pending.phase or nil,
            nextFrame = op.pending and op.pending.nextFrame or nil,
          }
        end
      end
    end

    return {
      manifestHash = manifest.contentHash,
      limit = 32,
      blockers = {
        count = #blockersSample,
        samples = blockersSample,
      },
      operationWork = {
        count = opWorkCount,
        samples = opWorkSamples,
      },
      counts = {
        liveOperations = ledger:opCount(),
        pendingOperations = pendingCount,
        scheduledOperations = pendingCount,
        activeCommands = inFlight,
        awaitingCompletions = inFlight,
        operationTombstones = 0,
        operationLifecycles = {
          static = staticOpsCount,
          state = stateOpsCount,
        },
        staticFailures = staticFailureCount,
        staticScans = {
          complete = scansComplete,
        },
      },
      queues = {
        staticCells = queuedStatic,
        staticIntent = {
          waiting = false,
          waitingCount = 0,
        },
        state = {
          queued = stateDirty and 1 or 0,
          pendingOwners = 0,
        },
      },
    }
  end

  return rec
end

return M
