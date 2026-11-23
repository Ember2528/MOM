-- Pure model-path syntax shared by compiler, compat, and engine-facing lookup.
local M = {}

local normalizeString = require('scripts.mom.common.strings').normalizeString

function M.normalize(value)
  local str = normalizeString(value)
  if not str then return nil end
  str = str:gsub('^[/\\]+', '')
  str = str:gsub('\\', '/'):gsub('([^:])//+', '%1/')
  str = str:lower()
  if not str:match('^meshes/') then
    str = 'meshes/' .. str
  end
  return str
end

return M
