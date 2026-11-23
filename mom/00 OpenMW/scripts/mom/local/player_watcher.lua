-- Player-local quest watcher. OpenMW exposes quest updates only to PLAYER
-- scripts, so this mirrors quest state into the global MOM runtime.
local self = require('openmw.self')
local core = require('openmw.core')
local types = require('openmw.types')
local constants = require('scripts.mom.constants')

local lastQuestStages = {}

local function onQuestUpdate(questId, stage)
  if type(questId) ~= 'string' or type(stage) ~= 'number' then return end
  local questIdLower = questId:lower()
  local oldStage = lastQuestStages[questIdLower]
  lastQuestStages[questIdLower] = stage
  -- Journal text updates may fire this event without changing the stage.
  if oldStage == stage then return end
  core.sendGlobalEvent(constants.events.questStageChanged, {
    questId = questIdLower,
    oldStage = oldStage,
    newStage = stage,
  })
end

-- Seed the global cache before the first real quest update.
local function onActive()
  if not (types.Player and types.Player.quests) then return end
  local okQuests, quests = pcall(types.Player.quests, self)
  if not okQuests or not quests then return end
  local snapshot = {}
  for questId, quest in pairs(quests) do
    if type(questId) == 'string' and type(quest.stage) == 'number' then
      local questIdLower = questId:lower()
      lastQuestStages[questIdLower] = quest.stage
      snapshot[questIdLower] = quest.stage
    end
  end
  core.sendGlobalEvent(constants.events.questStageSnapshotChunk, {
    quests = snapshot,
  })
end

return {
  engineHandlers = {
    onQuestUpdate = onQuestUpdate,
    onActive = onActive,
  },
}
