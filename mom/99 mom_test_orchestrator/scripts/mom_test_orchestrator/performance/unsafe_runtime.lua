local M = {}

local function sortedKeys(value)
  local keys = {}
  for key in pairs(value or {}) do keys[#keys + 1] = tostring(key) end
  table.sort(keys)
  return keys
end

local function gcSnapshot(collectgarbageFn)
  local memoryKb = collectgarbageFn('count')
  local running = nil
  local ok, value = pcall(collectgarbageFn, 'isrunning')
  if ok then running = value == true end
  return {memoryKb = memoryKb, running = running}
end

local function jitDescription(jitApi)
  if type(jitApi) ~= 'table' then return {available = false} end
  local status = {}
  if type(jitApi.status) == 'function' then
    local values = {pcall(jitApi.status)}
    if values[1] then
      status.enabled = values[2] == true
      status.options = {}
      for i = 3, #values do status.options[#status.options + 1] = tostring(values[i]) end
    end
  end
  return {
    available = true,
    enabled = status.enabled,
    options = status.options,
    version = jitApi.version,
    versionNumber = jitApi.version_num,
    architecture = jitApi.arch,
    operatingSystem = jitApi.os,
  }
end

local function newRuntime(options)
  local authority = assert(options.authority)
  local collectgarbageFn = assert(authority.collectgarbage,
    'collectgarbage authority is unavailable')
  local osApi = authority.os
  local ioApi = authority.io
  local atomicWriter = authority.writeAtomic
  if type(atomicWriter) ~= 'function' then
    assert(osApi, 'os authority is unavailable')
    assert(ioApi, 'io authority is unavailable')
  end
  local runtime = {
    mode = assert(options.mode),
    clockKind = assert(options.clockKind),
    _executableSha256 = options.executableSha256,
    _authority = authority,
    _clock = assert(options.clock),
    _cpuClock = options.cpuClock,
  }

  function runtime:collect()
    collectgarbageFn('collect')
  end

  function runtime:stopCollector()
    collectgarbageFn('stop')
  end

  function runtime:restartCollector()
    collectgarbageFn('restart')
  end

  function runtime:gcSnapshot()
    return gcSnapshot(collectgarbageFn)
  end

  function runtime:startTimer()
    return {
      primary = self._clock(),
      processCpu = self._cpuClock and self._cpuClock() or nil,
    }
  end

  function runtime:stopTimer(started)
    local primary = self._clock() - started.primary
    local processCpu = nil
    if self._cpuClock and started.processCpu ~= nil then
      processCpu = self._cpuClock() - started.processCpu
    end
    return {elapsedSeconds = primary, processCpuSeconds = processCpu}
  end

  function runtime:traceback(message)
    local debugApi = authority.debug
    if type(debugApi) == 'table' and type(debugApi.traceback) == 'function' then
      return debugApi.traceback(tostring(message), 2)
    end
    return tostring(message)
  end

  function runtime:prepareJit()
    local jitApi = authority.jit
    if type(jitApi) ~= 'table' then return end
    if type(jitApi.on) == 'function' then jitApi.on() end
    if type(jitApi.flush) == 'function' then jitApi.flush() end
  end

  function runtime:describe()
    local description = {
      mode = self.mode,
      clock = self.clockKind,
      lua = _VERSION,
      jit = jitDescription(authority.jit),
      authorityKeys = sortedKeys(authority),
    }
    if self._executableSha256 ~= nil then
      description.executableSha256 = self._executableSha256
    end
    return description
  end

  function runtime:capturedAtUtc()
    if type(osApi) ~= 'table' or type(osApi.date) ~= 'function' then return nil end
    return osApi.date('!%Y-%m-%dT%H:%M:%SZ')
  end

  function runtime:writeAtomic(path, bytes)
    if type(atomicWriter) == 'function' then
      local written, writeError = atomicWriter(path, bytes)
      assert(written == true,
        'cannot publish performance result: ' .. tostring(writeError))
      return true
    end
    local temporary = path .. '.tmp'
    local file, openError = ioApi.open(temporary, 'wb')
    assert(file, 'cannot open temporary result: ' .. tostring(openError))
    local wrote, writeError = file:write(bytes)
    if not wrote then
      file:close()
      if type(osApi.remove) == 'function' then osApi.remove(temporary) end
      error('cannot write temporary result: ' .. tostring(writeError), 0)
    end
    if type(file.flush) == 'function' then assert(file:flush()) end
    assert(file:close())

    local renamed, renameError = osApi.rename(temporary, path)
    if not renamed then
      if type(osApi.remove) == 'function' then osApi.remove(path) end
      renamed, renameError = osApi.rename(temporary, path)
    end
    if not renamed then
      if type(osApi.remove) == 'function' then osApi.remove(temporary) end
      error('cannot publish performance result: ' .. tostring(renameError), 0)
    end
    return true
  end

  return runtime
end

function M.standalone(options)
  options = options or {}
  local authority = {
    collectgarbage = assert(collectgarbage),
    io = assert(io),
    os = assert(os),
    debug = debug,
    jit = jit,
  }
  return newRuntime({
    mode = 'standalone',
    clockKind = 'process_cpu',
    authority = authority,
    clock = assert(os.clock),
    executableSha256 = assert(options.executableSha256,
      'standalone Lua executable SHA-256 is required'),
  })
end

function M.embedded(core)
  assert(core ~= nil and type(core.getRealTime) == 'function', 'openmw.core.getRealTime is required')
  local ok, authority = pcall(select, 'sandbox.bypass')
  assert(ok and type(authority) == 'table',
    'unsafe sandbox authority is unavailable; use the harness-owned OpenMW build')
  return newRuntime({
    mode = 'embedded',
    clockKind = 'monotonic_wall',
    authority = authority,
    clock = core.getRealTime,
    cpuClock = authority.os and authority.os.clock or nil,
  })
end

return M
