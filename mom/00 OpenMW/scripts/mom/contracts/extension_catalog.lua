-- Pure shape contract for the process-local extension catalog.
local M = {}

function M.validate(catalog)
  if type(catalog) ~= 'table' or catalog.kind ~= 'mom-extension-catalog' then
    return nil, {'extension catalog: expected mom-extension-catalog'}
  end
  for _, field in ipairs({'actions', 'guards', 'compat'}) do
    local registry = catalog[field]
    if type(registry) ~= 'table' or type(registry.ids) ~= 'table'
        or type(registry.byId) ~= 'table' then
      return nil, {'extension catalog.' .. field .. ': invalid registry'}
    end
  end
  for _, id in ipairs(catalog.actions.ids) do
    local entry = catalog.actions.byId[id]
    local mod = entry and entry.module
    if type(mod) ~= 'table' then
      return nil, {'extension catalog.actions.' .. tostring(id) .. ': module table is required'}
    elseif mod.execution == 'load' then
      if type(mod.analyzeLoad) ~= 'function' or type(mod.compileLoad) ~= 'function' then
        return nil, {'extension catalog.actions.' .. tostring(id) .. ': analyzeLoad and compileLoad are required'}
      end
    elseif type(mod.prepareAction) ~= 'function' or type(mod.compileAction) ~= 'function' then
      return nil, {'extension catalog.actions.' .. tostring(id) .. ': prepareAction and compileAction are required'}
    end
  end
  return true, nil
end

return M
