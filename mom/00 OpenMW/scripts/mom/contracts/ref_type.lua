-- Stable live-reference type grammar shared by compiler and engine adapters.
local M = {}

local NAMES = {
  'Static',
  'Activator',
  'Light',
  'Door',
  'Container',
  'NPC',
  'Creature',
  'Miscellaneous',
  'Weapon',
  'Armor',
  'Clothing',
  'Book',
  'Ingredient',
  'Potion',
  'Apparatus',
  'Lockpick',
  'Probe',
  'Repair',
}

local BY_NAME = {}
for i = 1, #NAMES do BY_NAME[NAMES[i]] = true end

function M.contains(typeName)
  return type(typeName) == 'string' and BY_NAME[typeName] == true
end

function M.names()
  local out = {}
  for i = 1, #NAMES do out[i] = NAMES[i] end
  return out
end

return M
