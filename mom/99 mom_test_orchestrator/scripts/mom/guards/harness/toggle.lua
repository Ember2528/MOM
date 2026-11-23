return {
  id = 'harness.toggle',
  providerInterface = 'MOMTestOrchestrator',
  abiVersion = 0,
  behaviorVersion = 0,
  programVersion = 0,
  lowerTuple = function(tuple, path)
    local key = tuple[2]
    if type(key) ~= 'string' or key == '' then
      return nil, path .. '[2]: expected toggle key string'
    end
    local expected = tuple[3]
    if type(expected) ~= 'boolean' then
      return nil, path .. '[3]: expected boolean'
    end
    if tuple[4] ~= nil then
      return nil, path .. ': harness.toggle tuple is too long'
    end
    return {
      type = 'harness.toggle',
      key = key,
      expected = expected,
    }, nil
  end,
  compileProgram = function(spec, env)
    return {
      program = spec,
      subscriptions = {env.guardEvent('harness', 'toggle_changed', spec.key)},
    }
  end,
  evaluate = function(program, capabilities)
    local provider = capabilities and capabilities.providers
      and capabilities.providers['harness.toggle'] or nil
    local read = provider and provider.read or nil
    if type(read) ~= 'function' then
      return {state = 'unknown', reason = 'harness toggle provider unavailable'}
    end
    local value, err = read(program)
    if type(value) ~= 'boolean' then
      return {state = 'unknown', reason = tostring(err or 'harness toggle state unavailable')}
    end
    return {state = value == program.expected and 'active' or 'inactive'}
  end,
}
