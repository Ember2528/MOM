-- Architecture audits read source text rather than executing it. The native
-- OpenMW lane supplies a read-only snapshot through this test-only module.
local M = {}

function M.read(path)
  local handle, err = io.open(path, 'rb')
  if handle == nil then return nil, err end
  local content = handle:read('*a')
  handle:close()
  return content
end

function M.exists(path)
  local handle = io.open(path, 'rb')
  if handle == nil then return false end
  handle:close()
  return true
end

function M.luaFiles(root)
  local quoted = "'" .. root:gsub("'", "'\\''") .. "'"
  local handle = assert(io.popen('find ' .. quoted .. " -type f -name '*.lua' -print", 'r'))
  local files = {}
  for path in handle:lines() do files[#files + 1] = path end
  local ok, _, code = handle:close()
  assert(ok == true, 'source file discovery failed with exit ' .. tostring(code))
  table.sort(files)
  return files
end

return M
