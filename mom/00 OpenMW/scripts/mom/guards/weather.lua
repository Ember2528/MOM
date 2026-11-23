local scalar_match = require('scripts.mom.contracts.scalar_match')
local matchesScalar = scalar_match.matchesScalar
local lowerScalarTuple = scalar_match.lowerScalarTuple
local WEATHER_OPERATORS = {
  eq = true,
  any = true,
  ['not'] = true,
}
return {
  id = 'weather',
  needsScene = true,
  abiVersion = 0,
  behaviorVersion = 0,
  programVersion = 0,
  lowerTuple = function(tuple, path)
    local regionId = tuple[2]
    if type(regionId) ~= 'string' or regionId == '' then
      return nil, path .. '[2]: expected region id string'
    end
    local spec = {
      type = 'weather',
      region = regionId,
    }
    local operator = tuple[3]
    if not WEATHER_OPERATORS[operator] then
      return nil, path .. '[3]: unsupported weather operator ' .. tostring(operator)
        .. ' (weather supports eq, any, not)'
    end
    local scalarSpec, scalarErr = lowerScalarTuple(tuple, path, 3)
    if not scalarSpec then return nil, scalarErr end
    spec.scriptId = scalarSpec
    return spec, nil
  end,
  compileProgram = function(spec)
    return {
      program = spec,
      subscriptions = {'weatherChanged'},
    }
  end,
  evaluate = function(program, capabilities)
    local readWeather = capabilities and capabilities.readWeather or nil
    if type(readWeather) ~= 'function' then
      return {state = 'unknown', reason = 'weather provider unavailable'}
    end
    local entry, err = readWeather(program.region)
    if type(entry) ~= 'table' then
      return {state = 'unknown', reason = tostring(err or 'weather state unavailable')}
    end
    if program.scriptId ~= nil then
      if type(entry.scriptId) ~= 'number' then
        return {state = 'unknown', reason = 'weather provider returned invalid scriptId'}
      end
      if not matchesScalar(entry.scriptId, program.scriptId, 'scriptId') then
        return {state = 'inactive'}
      end
    end
    return {state = 'active'}
  end,
}
