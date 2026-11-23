local done = false
return {engineHandlers = {onContentFilesLoaded = function()
  if done then return end
  done = true
  local ok, status, err = pcall(require('scripts.mom.compiler.startup_compile').load)
  if not ok or not status then print('[MOM][ERROR][content] ' .. tostring(ok and err or status))
  else print('[MOM][INFO][content] ' .. tostring(status.content.status)
    .. ' changed=' .. tostring(status.content.changedCount)) end
end}}
