-- Action-driven compile-time LOAD / GLOBAL planner.
-- Each action module declares its own LOAD eligibility (`analyzeLoad`) and
-- pre-edit read footprint (`readFootprint`). When `opts.content` is available
-- (in LOAD), interference is resolved against the exact pre-edit record catalog
-- and encoded as a compact 2-bit-per-candidate decision receipt for GLOBAL.
local M = {}

local authored = require('scripts.mom.compiler.authored_contract')
local content_types = require('scripts.mom.contracts.content_types')
local intent = require('scripts.mom.compiler.authored_intent')
local schema = require('scripts.mom.compiler.content.schema')
local model_path = require('scripts.mom.contracts.model_path')
local selectors = require('scripts.mom.contracts.ref_selector')

local LOAD_MODEL_TYPES = {}
local LOAD_MODEL_TYPE_LIST = {}
for name, spec in pairs(content_types) do
  if spec.fields and spec.fields.model then
    LOAD_MODEL_TYPES[name] = true
    LOAD_MODEL_TYPE_LIST[#LOAD_MODEL_TYPE_LIST + 1] = name
  end
end
table.sort(LOAD_MODEL_TYPE_LIST)

-- Lazy built-in fallback used only when a standalone caller omits a registry.
local BUILTIN_FALLBACK_MODULES = {
  record_content = 'scripts.mom.actions.record_content',
  leveled_content = 'scripts.mom.actions.leveled_content',
  place_ref = 'scripts.mom.actions.place_ref',
  modify_ref = 'scripts.mom.actions.modify_ref',
  modify_inventory = 'scripts.mom.actions.modify_inventory',
  kill_actor = 'scripts.mom.actions.kill_actor',
}
local fallbackCache = {}

local function actionModule(family, registry)
  local entry = registry and registry.byId and registry.byId[family] or nil
  if entry and type(entry.module) == 'table' then return entry.module end
  if fallbackCache[family] ~= nil then return fallbackCache[family] or nil end
  local moduleName = BUILTIN_FALLBACK_MODULES[family]
  if moduleName then
    local mod = require(moduleName)
    fallbackCache[family] = mod
    return mod
  end
  fallbackCache[family] = false
  return nil
end

local function nodeFamily(node)
  if type(node) ~= 'table' then return nil end
  if type(node.family) == 'string' and node.family ~= '' then return node.family end
  if type(node.spec) == 'table' then
    local verb = intent.verb(node.spec)
    if verb then return authored.actionKindForVerb(verb) end
  end
  return nil
end

local function hasNestedLoadOnly(node, registry)
  for _, child in ipairs(node.children or {}) do
    local mod = actionModule(nodeFamily(child), registry)
    if mod and mod.execution == 'load' then return true end
    if type(child.spec) == 'table' and (child.spec.record ~= nil or child.spec.leveled ~= nil) then
      return true
    end
    if hasNestedLoadOnly(child, registry) then return true end
  end
  return false
end

local function collectFootprint(node, registry)
  local mod = actionModule(nodeFamily(node), registry)
  local reads, choice = {}, false
  if mod and type(mod.readFootprint) == 'function' then
    local fp = mod.readFootprint(node)
    if type(fp) == 'table' then
      for _, read in ipairs(fp.reads or {}) do reads[#reads + 1] = read end
      choice = fp.choice == true
    end
  end
  for _, child in ipairs(node.children or {}) do
    local nested = collectFootprint(child, registry)
    for _, read in ipairs(nested.reads) do reads[#reads + 1] = read end
    choice = choice or nested.choice
  end
  return {reads = reads, choice = choice}
end

local function intersects(left, right)
  if left == nil or right == nil then return true end
  for name in pairs(left) do if right[name] then return true end end
  return false
end

local function pureOverlap(left, right)
  if not intersects(left.types, right.types) then return false end
  local a, b = left.source, right.source
  if a.sourceKeyKind == b.sourceKeyKind then return a.sourceValue == b.sourceValue end
  -- Without a record catalog, exact IDs and mesh selectors cannot be proved disjoint.
  return true
end

local function pureInterference(descriptor, otherFootprint)
  for _, row in ipairs(descriptor.rows or {}) do
    if not row.noop then
      for _, read in ipairs(otherFootprint.reads or {}) do
        if pureOverlap(row, read) or (intersects(row.types, read.types)
            and read.source.sourceKeyKind == 'model_path'
            and read.source.sourceValue == row.model) then
          return true
        end
      end
    end
  end
  return false
end

-- Lazy read-only openmw.content catalog shared across interference resolution.
local function newContentCatalog(content)
  local meshIndexes = {}
  local function meshIndex(typeName)
    local cached = meshIndexes[typeName]
    if cached ~= nil then return cached or nil end
    local records = schema.store(content, typeName)
    if not records then meshIndexes[typeName] = false; return nil end
    local out, seen = {}, {}
    local function append(record, key)
      local rawId, idErr = schema.lookup(record, 'id')
      if idErr then return end
      local id = schema.id(rawId or (type(key) == 'string' and key))
      if not id or seen[id] then return end
      seen[id] = true
      local rawModel, modelErr = schema.lookup(record, 'model')
      if modelErr or type(rawModel) ~= 'string' or rawModel == '' then return end
      local model = model_path.normalize(rawModel)
      if model then
        local bucket = out[model]
        if bucket == nil then bucket = {}; out[model] = bucket end
        bucket[#bucket + 1] = {type = typeName, id = id, model = model, record = record}
      end
    end
    local ok = pcall(function()
      if #records > 0 then
        for i = 1, #records do append(records[i], i) end
      else
        for key, record in pairs(records) do append(record, key) end
      end
    end)
    if not ok then meshIndexes[typeName] = false; return nil end
    meshIndexes[typeName] = out
    return out
  end

  local function resolveRowTargets(row)
    local targets = {}
    for _, typeName in ipairs(LOAD_MODEL_TYPE_LIST) do
      if row.types[typeName] then
        if row.source.sourceKeyKind == 'model_path' then
          local index = meshIndex(typeName)
          if index then
            for _, entry in ipairs(index[row.source.sourceValue] or {}) do
              local script
              if row.query and row.query.mwscript and schema.types[typeName].fields.mwscript then
                script = schema.lookup(entry.record, 'mwscript')
              end
              if not row.excluded[entry.id] and (row.query == nil
                  or selectors.matchesRecord(row.query, entry.id, typeName, script)) then
                targets[#targets + 1] = entry
              end
            end
          end
        else
          local records = schema.store(content, typeName)
          local record = records and schema.lookup(records, row.source.sourceValue) or nil
          if record ~= nil then
            local rawModel = schema.lookup(record, 'model')
            local model = type(rawModel) == 'string' and rawModel ~= '' and model_path.normalize(rawModel) or nil
            local script
            if row.query and row.query.mwscript and schema.types[typeName].fields.mwscript then
              script = schema.lookup(record, 'mwscript')
            end
            if not row.excluded[row.source.sourceValue] and (row.query == nil
                or selectors.matchesRecord(row.query, row.source.sourceValue, typeName, script)) then
              targets[#targets + 1] = {
                type = typeName, id = row.source.sourceValue, model = model, record = record,
              }
            end
          end
        end
      end
    end
    return targets
  end

  local function buildWriteProfile(descriptor)
    local mutatedRecords = {}
    local touchedModelsByType = {}
    local hasWrites = false
    for _, row in ipairs(descriptor.rows or {}) do
      if not row.noop then
        local targets = resolveRowTargets(row)
        for _, target in ipairs(targets) do
          if target.model ~= row.model then
            hasWrites = true
            mutatedRecords[target.type .. '\0' .. target.id] = true
            local byModel = touchedModelsByType[target.type]
            if byModel == nil then
              byModel = {}
              touchedModelsByType[target.type] = byModel
            end
            if target.model then byModel[target.model] = true end
            byModel[row.model] = true
          end
        end
      end
    end
    return {
      hasWrites = hasWrites,
      mutatedRecords = mutatedRecords,
      touchedModelsByType = touchedModelsByType,
    }
  end

  local function interferes(writeProfile, otherFootprint)
    if not writeProfile.hasWrites then return false end
    for _, read in ipairs(otherFootprint.reads or {}) do
      local typeScope = read.types or LOAD_MODEL_TYPES
      if read.source.sourceKeyKind == 'record_id' then
        for typeName in pairs(typeScope) do
          if writeProfile.mutatedRecords[typeName .. '\0' .. read.source.sourceValue] then
            return true
          end
        end
      else
        for typeName in pairs(typeScope) do
          local byModel = writeProfile.touchedModelsByType[typeName]
          if byModel and byModel[read.source.sourceValue] then
            return true
          end
        end
      end
    end
    return false
  end

  return {
    buildWriteProfile = buildWriteProfile,
    interferes = interferes,
  }
end

local function semantic(node)
  local value = {
    spec = node.spec,
    priority = node.priority,
    conflict = node.conflict,
    uniqueSourceKey = node.uniqueSourceKey,
    compositionOrder = node.compositionOrder,
  }
  if node.guardOwner ~= nil then
    value.guard = node.guardOwner.when or node.guardOwner.rawWhen or true
  end
  if #(node.children or {}) > 0 then
    value.children = {}
    for i, child in ipairs(node.children) do value.children[i] = semantic(child) end
  end
  return value
end
M.semantic = semantic

local CODE_TO_DECISION = {[0] = 'global', [1] = 'load', [2] = 'split'}
local DECISION_TO_CODE = {global = 0, load = 1, split = 2}
local HEX_CHARS = '0123456789abcdef'

-- Compact 2-bit-per-candidate hex codec (2 candidates per hex digit).
-- Prefix `<count>:` makes trailing padding unambiguous and canonical.
function M.encodeDecisions(decisions)
  local count = #(decisions or {})
  if count == 0 then return '' end
  local out = {tostring(count), ':'}
  for i = 1, count, 2 do
    local low = DECISION_TO_CODE[decisions[i]]
    assert(low ~= nil, 'invalid load decision: ' .. tostring(decisions[i]))
    local high = (i + 1 <= count) and DECISION_TO_CODE[decisions[i + 1]] or 0
    assert(high ~= nil, 'invalid load decision: ' .. tostring(decisions[i + 1]))
    local nibble = low + high * 4
    out[#out + 1] = HEX_CHARS:sub(nibble + 1, nibble + 1)
  end
  return table.concat(out)
end

function M.decodeDecisions(encoded)
  if encoded == nil or encoded == '' then return {}, nil end
  if type(encoded) ~= 'string' then return nil, 'LOAD decisions must be a string' end
  local countText, hex = encoded:match('^(%d+):([0-9a-f]+)$')
  local count = tonumber(countText)
  if not count or count < 1 or count % 1 ~= 0 or #hex ~= math.ceil(count / 2) then
    return nil, 'LOAD decisions encoding is malformed'
  end
  local out = {}
  for i = 1, count, 2 do
    local nibble = tonumber(hex:sub(math.floor((i - 1) / 2) + 1, math.floor((i - 1) / 2) + 1), 16)
    local low = nibble % 4
    local high = math.floor(nibble / 4)
    if CODE_TO_DECISION[low] == nil then return nil, 'LOAD decision code is invalid' end
    out[i] = CODE_TO_DECISION[low]
    if i + 1 <= count then
      if CODE_TO_DECISION[high] == nil then return nil, 'LOAD decision code is invalid' end
      out[i + 1] = CODE_TO_DECISION[high]
    elseif high ~= 0 then
      return nil, 'LOAD decisions trailing padding is non-zero'
    end
  end
  return out, nil
end

local function analyzeAll(attempts, registry)
  local roots, descriptors, footprints, errors = {}, {}, {}, {}
  local candidates = {}
  for _, attempt in ipairs(attempts or {}) do
    if attempt.status == 'resolved' then
      for _, node in ipairs(attempt.actions or {}) do
        if hasNestedLoadOnly(node, registry) then
          errors[#errors + 1] = tostring(node.diagnosticId or '<action>')
            .. ': record/list definitions cannot be children'
        else
          local mod = actionModule(nodeFamily(node), registry)
          local descriptor, err
          if mod and type(mod.analyzeLoad) == 'function' then
            descriptor, err = mod.analyzeLoad(node, {
              guarded = node.guardOwner ~= nil,
              hasChildren = #(node.children or {}) > 0,
              conflict = node.conflict,
            })
          end
          if err ~= nil then
            errors[#errors + 1] = tostring(node.diagnosticId or '<action>') .. ': ' .. tostring(err)
          else
            local idx = #roots + 1
            roots[idx] = node
            if descriptor ~= nil then
              descriptors[node] = descriptor
              candidates[#candidates + 1] = idx
              if descriptor.mode == 'load_only' then
                footprints[node] = {reads = {}, choice = false}
              else
                local reads = {}
                for _, row in ipairs(descriptor.rows or {}) do
                  if not row.noop then reads[#reads + 1] = row end
                end
                footprints[node] = {reads = reads, choice = descriptor.choice == true}
              end
            else
              footprints[node] = collectFootprint(node, registry)
            end
          end
        end
      end
    end
  end
  if #errors > 0 then return nil, errors end
  return {
    roots = roots,
    descriptors = descriptors,
    footprints = footprints,
    candidates = candidates,
  }
end

-- Pure catalog-independent fingerprint input set so LOAD and GLOBAL derive
-- identical loadFingerprints while invalidating whenever any candidate or
-- statically-overlapping runtime action changes.
local function buildLoadInputs(roots, descriptors, footprints, candidates)
  local included = {}
  for _, idx in ipairs(candidates) do
    local node = roots[idx]
    local d = descriptors[node]
    included[idx] = true
    if d.mode ~= 'load_only' then
      for j = 1, #roots do
        if j ~= idx and not included[j] and pureInterference(d, footprints[roots[j]]) then
          included[j] = true
        end
      end
    end
  end
  local inputs = {}
  for i = 1, #roots do
    if included[i] then
      inputs[#inputs + 1] = semantic(roots[i])
    end
  end
  return inputs
end

-- Computes LOAD / SPLIT / GLOBAL decisions across all resolved root actions.
-- When `opts.content` is supplied (in LOAD), uses exact pre-edit catalog
-- inspection so unrelated runtime rules (e.g. DOR) never demote LOAD writes.
function M.plan(attempts, opts)
  opts = opts or {}
  local registry = opts.actionRegistry
  local analysis, errors = analyzeAll(attempts, registry)
  if not analysis then return nil, errors end

  local roots = analysis.roots
  local descriptors = analysis.descriptors
  local footprints = analysis.footprints
  local candidates = analysis.candidates

  local decisions = {}
  local owners = {}
  for _, node in ipairs(roots) do
    local d = descriptors[node]
    if d == nil then
      decisions[node] = 'global'
      owners[node] = 'GLOBAL'
    elseif d.mode == 'load_only' then
      decisions[node] = 'load'
      owners[node] = 'LOAD'
    elseif d.mode == 'split' then
      decisions[node] = 'split'
      owners[node] = 'SPLIT'
    else
      decisions[node] = 'load'
      owners[node] = 'LOAD'
    end
  end

  local catalog = opts.content ~= nil and newContentCatalog(opts.content) or nil
  local writeProfiles = {}
  if catalog then
    for _, idx in ipairs(candidates) do
      local node = roots[idx]
      local d = descriptors[node]
      if d.mode ~= 'load_only' then
        writeProfiles[node] = catalog.buildWriteProfile(d)
      end
    end
  end

  local parent = {}
  local function find(i)
    local root = i
    while parent[root] ~= root do root = parent[root] end
    while parent[i] ~= i do
      local nextIdx = parent[i]
      parent[i] = root
      i = nextIdx
    end
    return root
  end
  local function union(i, j) parent[find(j)] = find(i) end
  for i = 1, #roots do parent[i] = i end

  local involved = {}
  for _, i in ipairs(candidates) do
    local node = roots[i]
    local d = descriptors[node]
    if d.mode ~= 'load_only' then
      involved[i] = true
      for j = 1, #roots do
        if i ~= j then
          local other = roots[j]
          local conflict
          if catalog then
            conflict = catalog.interferes(writeProfiles[node], footprints[other])
          else
            conflict = pureInterference(d, footprints[other])
          end
          if conflict then
            union(i, j)
            involved[j] = true
          end
        end
      end
    end
  end

  local components = {}
  for i = 1, #roots do
    if involved[i] then
      local root = find(i)
      local group = components[root]
      if not group then
        group = {nodes = {}, runtime = false, choices = false}
        components[root] = group
      end
      local node = roots[i]
      group.nodes[#group.nodes + 1] = node
      group.runtime = group.runtime or decisions[node] == 'global'
      group.choices = group.choices or footprints[node].choice
    end
  end

  for _, group in pairs(components) do
    if group.runtime or (group.choices and #group.nodes > 1) then
      for _, node in ipairs(group.nodes) do
        local d = descriptors[node]
        if d ~= nil and d.mode ~= 'load_only' then
          decisions[node] = 'global'
          owners[node] = 'GLOBAL'
        end
      end
    end
  end

  local candidateDecisions = {}
  for ci, rootIdx in ipairs(candidates) do
    candidateDecisions[ci] = decisions[roots[rootIdx]]
  end

  return {
    owners = owners,
    decisions = decisions,
    candidateDecisions = candidateDecisions,
    encodedDecisions = M.encodeDecisions(candidateDecisions),
    loadInputs = buildLoadInputs(roots, descriptors, footprints, candidates),
  }
end

-- Applies a LOAD-emitted decision receipt in GLOBAL without re-inspecting
-- the post-edit catalog (avoiding any LOAD/GLOBAL catalog divergence).
function M.applyDecisions(attempts, encodedDecisions, opts)
  opts = opts or {}
  local registry = opts.actionRegistry
  local analysis, errors = analyzeAll(attempts, registry)
  if not analysis then return nil, errors end

  local decoded, decodeErr = M.decodeDecisions(encodedDecisions)
  if not decoded then return nil, {decodeErr} end
  if #decoded ~= #analysis.candidates then
    return nil, {'LOAD decision count mismatch; fully restart OpenMW'}
  end

  local decisions = {}
  local owners = {}
  for _, node in ipairs(analysis.roots) do
    decisions[node] = 'global'
    owners[node] = 'GLOBAL'
  end
  for ci, rootIdx in ipairs(analysis.candidates) do
    local node = analysis.roots[rootIdx]
    local dec = decoded[ci]
    decisions[node] = dec
    owners[node] = dec == 'load' and 'LOAD' or (dec == 'split' and 'SPLIT' or 'GLOBAL')
  end

  return {
    owners = owners,
    decisions = decisions,
    candidateDecisions = decoded,
    encodedDecisions = encodedDecisions or '',
    loadInputs = buildLoadInputs(analysis.roots, analysis.descriptors, analysis.footprints, analysis.candidates),
  }
end

function M.select(attempts, plan, phase)
  local selected = {}
  for i, attempt in ipairs(attempts or {}) do
    local copy = {}
    for key, value in pairs(attempt) do copy[key] = value end
    copy.actions = {}
    for _, node in ipairs(attempt.actions or {}) do
      local dec = plan.decisions and plan.decisions[node]
        or (plan.owners and plan.owners[node] == 'LOAD' and 'load'
          or plan.owners and plan.owners[node] == 'SPLIT' and 'split'
          or 'global')
      if phase == 'LOAD' then
        if dec == 'load' or dec == 'split' then
          node.loadDecision = dec
          copy.actions[#copy.actions + 1] = node
        end
      else
        if dec == 'global' or dec == 'split' then
          node.loadDecision = dec == 'split' and 'split' or nil
          copy.actions[#copy.actions + 1] = node
        end
      end
    end
    selected[i] = copy
  end
  return selected
end

function M.phase(value)
  value = value or 'GLOBAL'
  if value ~= 'LOAD' and value ~= 'GLOBAL' then
    return nil, 'compiler phase must be LOAD or GLOBAL'
  end
  return value
end

return M
