-- Composes the sole global script from production modules. Harnesses may
-- replace the app-facing engine session while using the same App and callback
-- bridge.
local M = {}

local app_api = require('scripts.mom.app')
local constants = require('scripts.mom.constants')
local entrypoint = require('scripts.mom.entrypoint')
local error_message = require('scripts.mom.diagnostics.error_message')
local openmw_session = require('scripts.mom.openmw.session')

function M.new(opts)
  opts = opts or {}
  local sessionFactory = opts.engineSessionFactory
    or openmw_session.newFactory(opts.engineSessionOptions)
  local app, appErrors = app_api.new({
    engineSessionFactory = sessionFactory,
    unknownRetryDelay = opts.unknownRetryDelay,
    currentFrame = opts.currentFrame,
  })
  if not app then
    return nil, 'MOM App creation failed: ' .. table.concat(appErrors or {}, ' | ')
  end
  local script, entryError = entrypoint.new({
    app = app,
    sourceOptions = opts.sourceOptions or {configDir = constants.configDir},
  })
  if not script then
    return nil, 'MOM entrypoint creation failed: ' .. error_message.message(entryError)
  end
  return script, nil
end

return M
