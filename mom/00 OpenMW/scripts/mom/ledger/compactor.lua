-- Simple reachability mark-and-sweep GC run on save.
-- Retains all live operations, referenced refs/outputs, door origins for live
-- operations, current-manifest static scans, and active variant records.
local M = {}

local function markRef(keepRefs, refId)
  if type(refId) == 'string' and refId ~= '' then
    keepRefs[refId] = true
  end
end

function M.compact(ledger)
  local doc = ledger.doc
  local keepRefs = {}
  local keepVariants = {}

  for _, op in pairs(doc.ops) do
    markRef(keepRefs, op.targetId)
    if type(op.outputs) == 'table' then
      for i = 1, #op.outputs do
        local outId = op.outputs[i]
        markRef(keepRefs, outId)
        local ref = doc.refs[outId]
        if type(ref) == 'table' and type(ref.variantKey) == 'string' then
          keepVariants[ref.variantKey] = true
        end
      end
    end
  end

  -- Preserve Door starting origins for any ref that still has a recorded origin
  -- or is referenced by a live op.
  local removedRefs = 0
  for refId, ref in pairs(doc.refs) do
    local retain = keepRefs[refId] == true
      or (type(ref) == 'table' and ref.kind == 'ref' and ref.origin ~= nil)
    if not retain then
      ledger:deleteRef(refId)
      removedRefs = removedRefs + 1
    end
  end

  -- Keep staticScans only for the active manifestHash (if known) or non-empty plans.
  local removedScans = 0
  if doc.manifestHash ~= nil then
    for cellKey, scan in pairs(doc.staticScans) do
      if type(scan) ~= 'table' or (scan.manifestHash ~= nil and scan.manifestHash ~= doc.manifestHash) then
        doc.staticScans[cellKey] = nil
        removedScans = removedScans + 1
      end
    end
  end

  -- Variants stay cached across saves so world.createRecord is not duplicated
  -- when guards re-activate; bound only if dead/orphaned records pile up.
  local variantCount = 0
  for _ in pairs(doc.variants) do variantCount = variantCount + 1 end
  local removedVariants = 0
  if variantCount > 2048 then
    local keys = {}
    for key in pairs(doc.variants) do
      if not keepVariants[key] then keys[#keys + 1] = key end
    end
    table.sort(keys)
    local drop = math.min(#keys, variantCount - 1024)
    for i = 1, drop do
      doc.variants[keys[i]] = nil
      removedVariants = removedVariants + 1
    end
  end

  return {
    removedRefs = removedRefs,
    removedScans = removedScans,
    removedVariants = removedVariants,
  }
end

return M
