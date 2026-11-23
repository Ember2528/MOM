local M = {}
local canonical = require('scripts.mom.contracts.canonical')

-- These private keys also become DOR family signatures. Use the same exact
-- number and byte-string encoding as semantic identity, rather than runtime
-- dependent tostring(number) and string.format('%q', string) spellings.
function M.fromSpec(spec)
  local key, errors = canonical.encode(spec)
  if key ~= nil then return key end
  error('source spec key failed: ' .. table.concat(errors or {}, ' | '), 2)
end

return M
