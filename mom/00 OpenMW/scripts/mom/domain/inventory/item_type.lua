-- Canonical inventory record-type predicates shared by compilation and runtime
-- validation. Keeping the set here prevents authored admission and execution
-- from drifting on which records may be equipped.
local M = {}

local EQUIPPABLE = {
  Armor = true,
  Clothing = true,
  Light = true,
  Weapon = true,
}

function M.isEquippable(typeName)
  return EQUIPPABLE[typeName] == true
end

return M
