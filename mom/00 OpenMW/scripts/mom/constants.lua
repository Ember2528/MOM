-- Stable release-facing MOM identifiers and defaults.
local M = {
  modName = 'MOM - Modular Object Manipulator',
  shortName = 'MOM',
  namespace = 'mom',
  interfaceName = 'MOM',
  interfaceVersion = 0,
  consoleInterface = 'I.MOM',
  authoredConfigVersion = 0,
  configDir = 'scripts/mom/config',
  events = {
    equipDone = 'MOM_EquipDone',
    guardEvent = 'MOM_GuardEvent',
    questStageChanged = 'MOM_QuestStageChanged',
    questStageSnapshot = 'MOM_QuestStageSnapshot',
    questStageSnapshotChunk = 'MOM_QuestStageSnapshotChunk',
    equipItem = 'MOM_EquipItem',
    killCancel = 'MOM_KillCancel',
    killNow = 'MOM_KillNow',
    killDone = 'MOM_KillDone',
  },
}
return M
