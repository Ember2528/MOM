-- Sole production entrypoint for MOM.
local script_factory = require('scripts.mom.script_factory')

local script, scriptError = script_factory.new()
if not script then error(scriptError, 0) end
return script
