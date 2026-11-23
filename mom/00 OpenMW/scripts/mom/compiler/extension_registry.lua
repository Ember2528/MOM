-- Deterministic versioned registry for compiler/runtime extension modules.
-- Discovery is supplied by the caller so this contract remains host-testable.
local M = {}

local function diagnostic(code, message, entry)
  return {
    code = code,
    message = tostring(message),
    path = entry and entry.path or nil,
    id = entry and entry.module and entry.module.id or nil,
  }
end

local function normalizePath(path)
  return tostring(path or ''):gsub('\\', '/')
end

local function validId(id)
  if type(id) ~= 'string' or id == '' then return false end
  if id:sub(1, 1) == '.' or id:sub(-1) == '.' or id:find('..', 1, true) then
    return false
  end
  for segment in id:gmatch('[^.]+') do
    if not segment:match('^[a-z][a-z0-9_]*$') then
      return false
    end
  end
  return true
end

local function versionInteger(value)
  return type(value) == 'number' and value >= 0 and value % 1 == 0
end

local function sortedEntries(entries)
  local out = {}
  for i = 1, #(entries or {}) do
    local entry = entries[i]
    out[i] = {
      path = normalizePath(entry and entry.path or ''),
      expectedId = entry and entry.expectedId or nil,
      module = entry and entry.module or nil,
    }
  end
  table.sort(out, function(left, right)
    return left.path < right.path
  end)
  return out
end

local function validateMethods(errors, entry, requiredMethods)
  for i = 1, #(requiredMethods or {}) do
    local method = requiredMethods[i]
    if type(entry.module[method]) ~= 'function' then
      errors[#errors + 1] = diagnostic(
        'extension_method_missing',
        string.format('%s is missing required method %s()', tostring(entry.path), tostring(method)),
        entry
      )
    end
  end
end

local function validateExclusiveMethods(errors, entry, exclusiveMethods)
  if type(exclusiveMethods) ~= 'table' or #exclusiveMethods == 0 then return end
  local declared = 0
  for i = 1, #exclusiveMethods do
    if type(entry.module[exclusiveMethods[i]]) == 'function' then
      declared = declared + 1
    end
  end
  if declared ~= 1 then
    local names = {}
    for i = 1, #exclusiveMethods do
      names[i] = tostring(exclusiveMethods[i]) .. '()'
    end
    errors[#errors + 1] = diagnostic(
      'extension_method_choice_invalid',
      string.format(
        '%s must declare exactly one of %s',
        tostring(entry.path),
        table.concat(names, ' or ')
      ),
      entry
    )
  end
end

local function validateVersions(errors, entry, opts)
  local behaviorVersion = entry.module.behaviorVersion
  if not versionInteger(behaviorVersion) then
    errors[#errors + 1] = diagnostic(
      'extension_behavior_version_invalid',
      string.format('%s must declare a non-negative integer behaviorVersion', tostring(entry.path)),
      entry
    )
  end
  local programVersion = entry.module.programVersion
  if opts.requireProgramVersion == true and not versionInteger(programVersion) then
    errors[#errors + 1] = diagnostic(
      'extension_program_version_invalid',
      string.format('%s must declare a non-negative integer programVersion', tostring(entry.path)),
      entry
    )
  elseif programVersion ~= nil and not versionInteger(programVersion) then
    errors[#errors + 1] = diagnostic(
      'extension_program_version_invalid',
      string.format('%s programVersion must be a non-negative integer', tostring(entry.path)),
      entry
    )
  end
  local storageVersion = entry.module.storageVersion
  if storageVersion ~= nil and not versionInteger(storageVersion) then
    errors[#errors + 1] = diagnostic(
      'extension_storage_version_invalid',
      string.format('%s storageVersion must be a non-negative integer', tostring(entry.path)),
      entry
    )
  end
  local revertTokenVersion = entry.module.revertTokenVersion
  if revertTokenVersion ~= nil and not versionInteger(revertTokenVersion) then
    errors[#errors + 1] = diagnostic(
      'extension_revert_token_version_invalid',
      string.format('%s revertTokenVersion must be a non-negative integer',
        tostring(entry.path)),
      entry
    )
  end
end

function M.build(kind, entries, opts)
  opts = opts or {}
  local errors = {}
  local byId = {}
  local seenPaths = {}
  local ordered = sortedEntries(entries)
  local supportedAbiVersion = tonumber(opts.supportedAbiVersion) or 0

  for i = 1, #ordered do
    local entry = ordered[i]
    if entry.path == '' then
      errors[#errors + 1] = diagnostic('extension_path_invalid', 'extension path must be non-empty', entry)
    elseif seenPaths[entry.path] then
      errors[#errors + 1] = diagnostic(
        'extension_path_duplicate',
        'duplicate extension path ' .. tostring(entry.path),
        entry
      )
    else
      seenPaths[entry.path] = true
    end

    if type(entry.module) ~= 'table' then
      errors[#errors + 1] = diagnostic(
        'extension_module_invalid',
        string.format('%s must return a table', tostring(entry.path)),
        entry
      )
    else
      local id = entry.module.id
      if not validId(id) then
        errors[#errors + 1] = diagnostic(
          'extension_id_invalid',
          string.format('%s declares invalid extension id %s', tostring(entry.path), tostring(id)),
          entry
        )
      elseif entry.expectedId ~= nil and id ~= entry.expectedId then
        errors[#errors + 1] = diagnostic(
          'extension_id_path_mismatch',
          string.format(
            '%s declares extension id %s but its path requires %s',
            tostring(entry.path),
            tostring(id),
            tostring(entry.expectedId)
          ),
          entry
        )
      end
      local abiVersion = entry.module.abiVersion
      if not versionInteger(abiVersion) then
        errors[#errors + 1] = diagnostic(
          'extension_abi_invalid',
          string.format('%s must declare a non-negative integer abiVersion', tostring(entry.path)),
          entry
        )
      elseif abiVersion ~= supportedAbiVersion then
        errors[#errors + 1] = diagnostic(
          'extension_abi_unsupported',
          string.format(
            '%s declares ABI %d; supported %s ABI is %d',
            tostring(entry.path),
            abiVersion,
            tostring(kind),
            supportedAbiVersion
          ),
          entry
        )
      end
      validateVersions(errors, entry, opts)
      if validId(id) and byId[id] ~= nil then
        errors[#errors + 1] = diagnostic(
          'extension_id_duplicate',
          string.format(
            'duplicate %s extension id %s at %s and %s',
            tostring(kind),
            tostring(id),
            tostring(byId[id].path),
            tostring(entry.path)
          ),
          entry
        )
      elseif validId(id) then
        byId[id] = {
          id = id,
          abiVersion = abiVersion,
          behaviorVersion = entry.module.behaviorVersion,
          programVersion = entry.module.programVersion,
          storageVersion = entry.module.storageVersion,
          revertTokenVersion = entry.module.revertTokenVersion,
          path = entry.path,
          module = entry.module,
        }
      end
      local methods = (entry.module.execution == 'load' and opts.loadRequiredMethods)
        or opts.requiredMethods
      validateMethods(errors, entry, methods)
      validateExclusiveMethods(errors, entry, opts.exclusiveMethods)
    end
  end

  if #errors > 0 then return nil, errors end
  local ids = {}
  for id in pairs(byId) do ids[#ids + 1] = id end
  table.sort(ids)
  return {
    kind = kind,
    ids = ids,
    byId = byId,
  }, nil
end

local function quarantineIdsFor(entry)
  local ids = {}
  local seen = {}
  local function add(id)
    if validId(id) and not seen[id] then
      seen[id] = true
      ids[#ids + 1] = id
    end
  end
  add(entry and entry.expectedId)
  add(entry and entry.module and entry.module.id)
  table.sort(ids)
  return ids
end

local function appendQuarantine(quarantinedById, id, entry, errors)
  local quarantine = quarantinedById[id]
  if quarantine == nil then
    quarantine = {
      id = id,
      paths = {},
      diagnostics = {},
    }
    quarantinedById[id] = quarantine
  end
  local path = normalizePath(entry and entry.path or '')
  if path ~= '' then
    local duplicate = false
    for i = 1, #quarantine.paths do
      if quarantine.paths[i] == path then duplicate = true break end
    end
    if not duplicate then
      quarantine.paths[#quarantine.paths + 1] = path
      table.sort(quarantine.paths)
    end
  end
  for i = 1, #(errors or {}) do
    local err = errors[i]
    quarantine.diagnostics[#quarantine.diagnostics + 1] = {
      code = tostring(err.code or 'extension_invalid'),
      message = tostring(err.message or 'extension is invalid'),
      path = err.path,
      id = err.id,
    }
  end
end

-- Discovery omits invalid entries from the usable registry and records
-- errors against every canonical ID they could have owned. Duplicate paths and
-- IDs invalidate every claimant; load order never selects a winner. The strict
-- build() API validates a registry as one atomic declaration.
function M.buildQuarantined(kind, entries, opts)
  opts = opts or {}
  local ordered = sortedEntries(entries)
  local diagnostics = {}
  local quarantinedById = {}
  local pathCounts = {}
  local candidates = {}

  for i = 1, #ordered do
    local path = ordered[i].path
    pathCounts[path] = (pathCounts[path] or 0) + 1
  end

  for i = 1, #ordered do
    local entry = ordered[i]
    local registry, entryErrors = M.build(kind, {entry}, opts)
    local errors = {}
    for j = 1, #(entryErrors or {}) do errors[#errors + 1] = entryErrors[j] end
    if entry.path ~= '' and pathCounts[entry.path] > 1 then
      errors[#errors + 1] = diagnostic(
        'extension_path_duplicate',
        'duplicate extension path ' .. tostring(entry.path),
        entry
      )
    end
    if #errors > 0 then
      for j = 1, #errors do diagnostics[#diagnostics + 1] = errors[j] end
      local ids = quarantineIdsFor(entry)
      for j = 1, #ids do appendQuarantine(quarantinedById, ids[j], entry, errors) end
    elseif registry ~= nil then
      local id = registry.ids[1]
      candidates[#candidates + 1] = registry.byId[id]
    end
  end

  for i = 1, #(opts.loadErrors or {}) do
    local err = opts.loadErrors[i]
    local normalized = {
      code = tostring(err.code or 'extension_require_failed'),
      message = tostring(err.message or 'extension could not be loaded'),
      path = normalizePath(err.path),
      id = err.id,
    }
    diagnostics[#diagnostics + 1] = normalized
    local ids = quarantineIdsFor({
      path = err.path,
      expectedId = err.expectedId,
      module = validId(err.id) and {id = err.id} or nil,
    })
    for j = 1, #ids do
      appendQuarantine(quarantinedById, ids[j], err, {normalized})
    end
  end

  local candidatesById = {}
  for i = 1, #candidates do
    local candidate = candidates[i]
    local bucket = candidatesById[candidate.id]
    if bucket == nil then
      bucket = {}
      candidatesById[candidate.id] = bucket
    end
    bucket[#bucket + 1] = candidate
  end

  local byId = {}
  for id, bucket in pairs(candidatesById) do
    if #bucket == 1 and quarantinedById[id] == nil then
      byId[id] = bucket[1]
    else
      local duplicateErrors = {}
      for i = 1, #bucket do
        duplicateErrors[i] = diagnostic(
          'extension_id_duplicate',
          string.format(
            'duplicate %s extension id %s; every claimant is quarantined',
            tostring(kind),
            tostring(id)
          ),
          bucket[i]
        )
        diagnostics[#diagnostics + 1] = duplicateErrors[i]
        appendQuarantine(quarantinedById, id, bucket[i], {duplicateErrors[i]})
      end
    end
  end

  local ids = {}
  for id in pairs(byId) do ids[#ids + 1] = id end
  table.sort(ids)
  local quarantinedIds = {}
  for id in pairs(quarantinedById) do quarantinedIds[#quarantinedIds + 1] = id end
  table.sort(quarantinedIds)
  table.sort(diagnostics, function(left, right)
    if tostring(left.path) ~= tostring(right.path) then
      return tostring(left.path) < tostring(right.path)
    end
    if tostring(left.code) ~= tostring(right.code) then
      return tostring(left.code) < tostring(right.code)
    end
    return tostring(left.message) < tostring(right.message)
  end)
  return {
    kind = kind,
    ids = ids,
    byId = byId,
    quarantinedIds = quarantinedIds,
    quarantinedById = quarantinedById,
    quarantineDiagnostics = diagnostics,
  }, nil
end

local function describeEntry(entry)
  return {
    abiVersion = entry.abiVersion,
    behaviorVersion = entry.behaviorVersion,
    programVersion = entry.programVersion,
    storageVersion = entry.storageVersion,
    revertTokenVersion = entry.revertTokenVersion,
  }
end

-- Optionally project only an ID set so manifest compilation scales with the
-- extensions a source uses rather than every installed extension.
function M.describe(registry, selectedIds)
  local out = {}
  if selectedIds ~= nil then
    for id in pairs(selectedIds) do
      local entry = registry and registry.byId and registry.byId[id] or nil
      if entry ~= nil then out[id] = describeEntry(entry) end
    end
    return out
  end
  for i = 1, #((registry and registry.ids) or {}) do
    local id = registry.ids[i]
    local entry = registry.byId[id]
    out[id] = describeEntry(entry)
  end
  return out
end

function M.claim(registry, source, opts)
  opts = opts or {}
  local method = opts.method or 'matchesPath'
  local claims = {}
  local claimedIds = {}
  local preclaimed = opts.preclaimed
  if preclaimed ~= nil and type(preclaimed) ~= 'table' then
    return nil, {
      diagnostic('extension_claim_invalid', 'preclaimed extensions must be a table'),
    }
  end
  if type(preclaimed) == 'table' and preclaimed.id ~= nil then
    preclaimed = {preclaimed}
  end
  for i = 1, #(preclaimed or {}) do
    local entry = preclaimed[i]
    if type(entry) ~= 'table' or type(entry.id) ~= 'string'
        or registry == nil or registry.byId == nil
        or registry.byId[entry.id] ~= entry then
      return nil, {
        diagnostic(
          'extension_claim_invalid',
          'preclaimed extension does not belong to the selected registry',
          entry
        ),
      }
    end
    if not claimedIds[entry.id] then
      claimedIds[entry.id] = true
      claims[#claims + 1] = entry
    end
  end
  for i = 1, #((registry and registry.ids) or {}) do
    local id = registry.ids[i]
    local entry = registry.byId[id]
    local claim = entry and entry.module and entry.module[method] or nil
    local skipMethod = opts.skipEntriesWithMethod
    local skipped = type(skipMethod) == 'string'
      and type(entry and entry.module and entry.module[skipMethod]) == 'function'
    if not claimedIds[id] and not skipped and type(claim) == 'function' then
      local ok, matched = pcall(claim, source)
      if not ok then
        return nil, {
          diagnostic(
            'extension_claim_failed',
            string.format('%s claim failed: %s', tostring(id), tostring(matched)),
            entry
          ),
        }
      end
      if matched then claims[#claims + 1] = entry end
    end
  end
  if #claims == 1 then return claims[1], nil end
  if #claims == 0 and opts.allowUnclaimed == true then return nil, nil end
  if #claims == 0 then
    return nil, {
      diagnostic('extension_source_unclaimed', 'no extension claimed source ' .. tostring(source)),
    }
  end
  local ids = {}
  for i = 1, #claims do ids[i] = claims[i].id end
  return nil, {
    diagnostic(
      'extension_source_ambiguous',
      string.format('source %s was claimed by %s', tostring(source), table.concat(ids, ', '))
    ),
  }
end

return M
