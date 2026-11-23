local M = {}
local model_path_contract = require('scripts.mom.contracts.model_path')
local vfs = require('openmw.vfs')
local function pathPrefix(path)
  local parent = path:match('^(.*)/[^/]+$')
  if not parent or parent == '' then
    return ''
  end
  return parent .. '/'
end
local function prefixContainsPath(path)
  local prefix = pathPrefix(path)
  local okIterator, iterator = pcall(vfs.pathsWithPrefix, prefix)
  if not okIterator then
    return nil, iterator
  end
  while true do
    local okNext, nextPath = pcall(iterator)
    if not okNext then
      return nil, nextPath
    end
    if nextPath == nil then
      return false, nil
    end
    if tostring(nextPath) == path then
      return true, nil
    end
  end
end
-- The optional cache is owned by the caller. Compile contexts supply an
-- attempt-local table; focused callers that omit it perform a stateless lookup.
-- The fourth return value reports whether the answer came from that cache.
function M.modelExists(path, cache)
  local normalized = model_path_contract.normalize(path)
  if not normalized then return false, nil, 'invalid model path' end
  local cached = nil
  if cache then cached = cache[normalized] end
  if cached ~= nil then
    return cached, normalized, nil, true
  end
  local ok, exists = pcall(vfs.fileExists, normalized)
  if ok and type(exists) == 'boolean' then
    if cache then cache[normalized] = exists end
    return exists, normalized, nil, false
  end
  local fileExistsErr = ok and ('vfs.fileExists returned ' .. type(exists)) or tostring(exists)
  local fallbackExists, fallbackErr = prefixContainsPath(normalized)
  if fallbackErr then
    return false, normalized,
      string.format('vfs.fileExists failed: %s; pathsWithPrefix failed: %s',
        tostring(fileExistsErr),
        tostring(fallbackErr))
  end
  if cache then cache[normalized] = fallbackExists end
  return fallbackExists, normalized, nil, false
end
return M
