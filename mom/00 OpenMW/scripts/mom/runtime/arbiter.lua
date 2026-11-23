-- Synchronous greedy claim arbiter and deterministic execution orderer.
-- Replaces the 1,361-line cooperative intent graph and merge-sort state machine.
local M = {}

local strings = require('scripts.mom.common.strings')

local sampleStringRaw = strings.sampleStringRaw

-- Exact total rank order for claim conflict resolution:
-- higher priority > higher specificity > lexicographical actionId > id.
function M.higherRank(left, right)
  if left.priority ~= right.priority then
    return left.priority > right.priority
  end
  if left.specificity ~= right.specificity then
    return left.specificity > right.specificity
  end
  if left.actionId ~= right.actionId then
    return left.actionId < right.actionId
  end
  return left.id < right.id
end

-- Deterministic apply order: shallowest depth first, then authored order.
function M.beforeApply(left, right)
  if left.depth ~= right.depth then return left.depth < right.depth end
  if left.order ~= right.order then return left.order < right.order end
  if left.actionId ~= right.actionId then return left.actionId < right.actionId end
  if left.targetId ~= right.targetId then return left.targetId < right.targetId end
  return left.semanticId < right.semanticId
end

-- Deterministic cleanup/revert order: deepest descendants first.
function M.beforeCleanup(left, right)
  if left.depth ~= right.depth then return left.depth > right.depth end
  return left.semanticId < right.semanticId
end

local function passesChance(candidate)
  local chance = candidate.chance
  if chance == nil or chance >= 1 then return true end
  if chance <= 0 then return false end
  return sampleStringRaw(candidate.semanticId or candidate.id) / 4294967296 < chance
end

local function conflictScopeKeys(candidate)
  local conflict = candidate.conflict
  if type(conflict) ~= 'table' or type(conflict.group) ~= 'string' or conflict.group == '' then
    return nil
  end
  local scope
  if conflict.groupBy == 'record_id' and type(candidate.recordId) == 'string' then
    scope = 'conflict-rec:' .. conflict.group .. ':' .. candidate.recordId:lower()
  else
    scope = 'conflict:' .. conflict.group
  end
  return scope
end

-- Arbitrates `candidates` against `occupiedClaims` (`targetId -> { [claim] = opId }`).
-- Returns `{ winners = {...}, blocked = {...}, skippedChance = {...} }`.
function M.arbitrate(candidates, occupiedClaims)
  occupiedClaims = occupiedClaims or {}
  local eligible = {}
  local skippedChance = {}
  for i = 1, #(candidates or {}) do
    local c = candidates[i]
    if passesChance(c) then
      eligible[#eligible + 1] = c
    else
      skippedChance[#skippedChance + 1] = c
    end
  end

  table.sort(eligible, M.higherRank)

  local wonByTarget = {}     -- targetId -> { [claimKey] = candidate.id }
  local wonByConflict = {}   -- scopeKey -> candidate.id
  local winners = {}
  local blocked = {}

  for i = 1, #eligible do
    local c = eligible[i]
    local targetId = c.targetId
    local claims = c.claims or {}
    local occ = occupiedClaims[targetId]
    local won = wonByTarget[targetId]
    local replaces = c.replacesOpId
    local blocker = nil

    for j = 1, #claims do
      local key = claims[j]
      if key ~= 'output.existence' then
        local occOwner = occ and occ[key] or nil
        if occOwner ~= nil and occOwner ~= replaces then
          blocker = occOwner
          break
        end
        local wonOwner = won and won[key] or nil
        if wonOwner ~= nil then
          blocker = wonOwner
          break
        end
      end
    end

    local conflictScope = nil
    if blocker == nil then
      conflictScope = conflictScopeKeys(c)
      if conflictScope ~= nil and wonByConflict[conflictScope] ~= nil then
        blocker = wonByConflict[conflictScope]
      end
    end

    if blocker == nil then
      for j = 1, #claims do
        local key = claims[j]
        if key ~= 'output.existence' then
          if won == nil then
            won = {}
            wonByTarget[targetId] = won
          end
          won[key] = c.id
        end
      end
      if conflictScope ~= nil then wonByConflict[conflictScope] = c.id end
      winners[#winners + 1] = c
    else
      blocked[#blocked + 1] = {candidate = c, blocker = blocker}
    end
  end

  table.sort(winners, M.beforeApply)
  return {
    winners = winners,
    blocked = blocked,
    skippedChance = skippedChance,
  }
end

function M.orderCleanups(entries)
  local out = {}
  for i = 1, #(entries or {}) do out[i] = entries[i] end
  table.sort(out, M.beforeCleanup)
  return out
end

return M
