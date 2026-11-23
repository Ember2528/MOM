-- Pure declaration metadata shared by partitioning and the LOAD backend.
local COMMON = {model = 'model', name = 'string', mwscript = 'id', icon = 'icon',
  weight = 'nonnegative', value = 'nonnegative_integer'}
local function fields(base, extra, omit)
  local out = {}
  for key, value in pairs(base or {}) do if not (omit and omit[key]) then out[key] = value end end
  for key, value in pairs(extra or {}) do out[key] = value end
  return out
end
return {
  Static = {namespace = 'statics', fields = {model = 'model'}},
  Activator = {namespace = 'activators', fields = {model = 'model', name = 'string', mwscript = 'id'}},
  Door = {namespace = 'doors', fields = {model = 'model', name = 'string', mwscript = 'id',
    openSound = 'id', closeSound = 'id'}},
  Book = {namespace = 'books', fields = fields(COMMON, {text = 'string', isScroll = 'boolean',
    enchant = 'id', enchantCapacity = 'capacity', skill = 'id'})},
  Light = {namespace = 'lights', fields = fields(COMMON, {duration = 'duration', radius = 'nonnegative_integer',
    color = 'color', isCarriable = 'boolean', isDynamic = 'boolean', isFire = 'boolean',
    isFlicker = 'boolean', isFlickerSlow = 'boolean', isNegative = 'boolean',
    isOffByDefault = 'boolean', isPulse = 'boolean', isPulseSlow = 'boolean'})},
  Miscellaneous = {namespace = 'miscs', fields = fields(COMMON)},
  Ingredient = {namespace = 'ingredients', fields = fields(COMMON)},
  Potion = {namespace = 'potions', fields = fields(COMMON, {isAutocalc = 'boolean'})},
  Apparatus = {namespace = 'apparatuses', fields = fields(COMMON, {quality = 'nonnegative'})},
  Lockpick = {namespace = 'lockpicks', fields = fields(COMMON, {quality = 'nonnegative', maxCondition = 'nonnegative_integer'})},
  Probe = {namespace = 'probes', fields = fields(COMMON, {quality = 'nonnegative', maxCondition = 'nonnegative_integer'})},
  Repair = {namespace = 'repairs', fields = fields(COMMON, {quality = 'nonnegative', maxCondition = 'nonnegative_integer'})},
  CreatureLevelledList = {namespace = 'levelledCreatures', entries = 'creatures', fields = {
    chanceNone = 'probability', calculateFromAllLevels = 'boolean'}},
  ItemLevelledList = {namespace = 'levelledItems', entries = 'items', fields = {
    chanceNone = 'probability', calculateFromAllLevels = 'boolean', calculateForEach = 'boolean'}},
}
