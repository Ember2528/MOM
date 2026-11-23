-- Author-facing validation for select.cell and select.recordId shapes. Kept
-- separate from lowering so diagnostics remain close to the public DSL.
local M = {}
local ref_selector = require('scripts.mom.contracts.ref_selector')
local isInteger = require('scripts.mom.common.numbers').isInteger
local function addError(errors, path, message)
  errors[#errors + 1] = string.format('%s: %s', path, message)
end
local function validateArrayShape(value, path, errors, itemDescription)
  local count = #value
  if count == 0 then
    addError(errors, path, 'expected non-empty array of ' .. itemDescription)
    return count
  end
  for key in pairs(value) do
    if type(key) ~= 'number' or key < 1 or key > count or key % 1 ~= 0 then
      addError(errors, path .. '.' .. tostring(key), 'is not allowed; expected array of ' .. itemDescription)
    end
  end
  return count
end
local function validateStringOrArrayOfStrings(value, path, errors)
  if type(value) == 'string' then return end
  if type(value) ~= 'table' then
    addError(errors, path, 'expected string or array')
    return
  end
  local count = validateArrayShape(value, path, errors, 'strings')
  for i = 1, count do
    if type(value[i]) ~= 'string' then
      addError(errors, string.format('%s[%d]', path, i), 'expected string')
    end
  end
end
local function validateInteger(value, path, errors)
  if not isInteger(value) then
    addError(errors, path, 'expected integer')
  end
end
local function validateIntegerPair(value, path, errors)
  if type(value) ~= 'table' then
    addError(errors, path, 'expected coord pair')
    return
  end
  validateArrayShape(value, path, errors, 'integer coord pair')
  if #value ~= 2 then
    addError(errors, path, 'expected 2 items')
  end
  validateInteger(value[1], path .. '[1]', errors)
  validateInteger(value[2], path .. '[2]', errors)
end
local function validateCellQuerySpec(cellSpec, path, errors, opts)
  opts = opts or {}
  if cellSpec == nil or type(cellSpec) == 'string' then return end
  if type(cellSpec) ~= 'table' then
    addError(errors, path, 'expected string or object')
    return
  end
  local allowed = {
    exact = true,
    match = true,
    kind = true,
    worldspace = true,
    region = true,
    coords = true,
  }
  if opts.allowExclude == true then
    allowed.exclude = true
  end
  for key in pairs(cellSpec) do
    if not allowed[key] then
      addError(errors, path .. '.' .. tostring(key), 'is not allowed')
    end
  end
  if cellSpec.exact ~= nil then
    validateStringOrArrayOfStrings(cellSpec.exact, path .. '.exact', errors)
  end
  if cellSpec.match ~= nil then
    validateStringOrArrayOfStrings(cellSpec.match, path .. '.match', errors)
  end
  if cellSpec.worldspace ~= nil then
    validateStringOrArrayOfStrings(cellSpec.worldspace, path .. '.worldspace', errors)
  end
  if cellSpec.region ~= nil then
    validateStringOrArrayOfStrings(cellSpec.region, path .. '.region', errors)
  end
  if cellSpec.kind ~= nil and cellSpec.kind ~= 'interior' and cellSpec.kind ~= 'exterior' then
    addError(errors, path .. '.kind', 'must be interior or exterior')
  end
  local coords = cellSpec.coords
  if coords ~= nil then
    if type(coords) ~= 'table' then
      addError(errors, path .. '.coords', 'expected coord pair or coord pair array')
    elseif coords.x ~= nil or coords.y ~= nil then
      validateInteger(coords.x, path .. '.coords.x', errors)
      validateInteger(coords.y, path .. '.coords.y', errors)
      for key in pairs(coords) do
        if key ~= 'x' and key ~= 'y' then
          addError(errors, path .. '.coords.' .. tostring(key), 'is not allowed')
        end
      end
    elseif #coords == 2 and type(coords[1]) == 'number' and type(coords[2]) == 'number' then
      validateInteger(coords[1], path .. '.coords[1]', errors)
      validateInteger(coords[2], path .. '.coords[2]', errors)
    else
      local count = validateArrayShape(coords, path .. '.coords', errors, 'coord pairs')
      for i = 1, count do
        validateIntegerPair(coords[i], string.format('%s.coords[%d]', path, i), errors)
      end
    end
  end
end
local function validateCellSpec(cellSpec, path, errors)
  if cellSpec == nil or type(cellSpec) == 'string' then return end
  if type(cellSpec) ~= 'table' then
    addError(errors, path, 'expected string or object')
    return
  end
  validateCellQuerySpec(cellSpec, path, errors, { allowExclude = true })
  if cellSpec.exclude ~= nil then
    validateCellQuerySpec(cellSpec.exclude, path .. '.exclude', errors)
  end
end
function M.validateSelectSpec(selectSpec, actionPath, opts)
  actionPath = tostring(actionPath or 'actions.action')
  if selectSpec == nil then return true, {} end
  if type(selectSpec) ~= 'table' then
    return false, { actionPath .. '.select: expected object' }
  end
  local errors = {}
  local allowed = {recordId = true, cell = true, ref = true, type = true,
    contentFile = true, mwscript = true}
  if opts and opts.internal then allowed.query = true; allowed.cellConstraints = true end

  for key in pairs(selectSpec) do
    if not allowed[key] then
      addError(errors, actionPath .. '.select.' .. tostring(key), 'is not allowed')
    end
  end
  if ref_selector.isExtended(selectSpec) and selectSpec.query == nil then
    local raw = {}
    for key, value in pairs(selectSpec) do if key ~= 'cell' then raw[key] = value end end
    local _, err = ref_selector.normalize(raw, actionPath .. '.select')
    if err then addError(errors, actionPath .. '.select', err) end
  elseif selectSpec.recordId ~= nil then
    validateStringOrArrayOfStrings(selectSpec.recordId, actionPath .. '.select.recordId', errors)
  end
  if selectSpec.cell ~= nil then
    validateCellSpec(selectSpec.cell, actionPath .. '.select.cell', errors)
  end
  return #errors == 0, errors
end
return M
