local vfs = require('openmw.vfs')
--- Read the entire contents of a VFS file.
--- @param path string VFS path to read.
--- @return string|nil content  File contents, or nil on error.
--- @return string|nil err      Error message on failure.
local function readAll(path)
  local fileHandle, err = vfs.open(path)
  if not fileHandle then return nil, err end
  local ok, content = pcall(fileHandle.read, fileHandle, '*all')
  fileHandle:close()
  if not ok then return nil, content end
  return content, nil
end
return readAll
