local scalar_match = require('scripts.mom.contracts.scalar_match')
local matchesScalar = scalar_match.matchesScalar
local lowerScalarTuple = scalar_match.lowerScalarTuple
return {
  id = 'quest_stage',
  needsScene = false,
  abiVersion = 0,
  behaviorVersion = 0,
  programVersion = 0,
  lowerTuple = function(tuple, path)
    local questId = tuple[2]
    if type(questId) ~= 'string' or questId == '' then
      return nil, path .. '[2]: expected quest id string'
    end
    local spec = {
      type = 'quest_stage',
      questId = questId,
    }
    local scalarSpec, scalarErr = lowerScalarTuple(tuple, path, 3)
    if not scalarSpec then return nil, scalarErr end
    spec.stage = scalarSpec
    return spec, nil
  end,
  compileProgram = function(spec)
    return {
      program = spec,
      subscriptions = {'questStageChanged'},
    }
  end,
  evaluate = function(program, capabilities)
    local readQuestStage = capabilities and capabilities.readQuestStage or nil
    if type(readQuestStage) ~= 'function' then
      return {state = 'unknown', reason = 'quest provider unavailable'}
    end
    local stage, err = readQuestStage(program.questId)
    if type(stage) == 'number' then
      return {state = matchesScalar(stage, program.stage, 'stage') and 'active' or 'inactive'}
    end
    if err == 'quest-not-active' then return {state = 'inactive'} end
    return {state = 'unknown', reason = tostring(err or 'quest state unavailable')}
  end,
}
