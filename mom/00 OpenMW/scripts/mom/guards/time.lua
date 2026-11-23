-- Time guards normalize tuples and object specs to scalar/date predicates,
-- evaluated against snapshots supplied by the readTime capability.
local scalar_match = require('scripts.mom.contracts.scalar_match')
local matchesScalar = scalar_match.matchesScalar
local lowerScalarTuple = scalar_match.lowerScalarTuple
local parseInteger = scalar_match.parseInteger
local parseRangeMode = scalar_match.parseRangeMode
local isArray = require('scripts.mom.common.tables').isArray
local SCALAR_OPTS = { wrapRange = true }
local SCALAR_FIELDS = {'hour', 'month', 'day', 'dayOfWeek', 'yearDay'}
local SCALAR_FIELD_SET = {}
for _, field in ipairs(SCALAR_FIELDS) do SCALAR_FIELD_SET[field] = true end
local function parseBoolean(value, path)
  if type(value) ~= 'boolean' then
    return nil, path .. ': expected boolean'
  end
  return value, nil
end
local function normalizeDatePoint(rawDate, path, opts)
  opts = opts or {}
  if type(rawDate) ~= 'table' then
    return nil, path .. ': expected date object'
  end
  local out = {}
  if rawDate.month ~= nil then
    local month, monthErr = parseInteger(rawDate.month, path .. '.month')
    if not month then return nil, monthErr end
    if month < 1 or month > 12 then
      return nil, path .. '.month: expected value between 1 and 12'
    end
    out.month = month
  end
  if rawDate.day ~= nil then
    local day, dayErr = parseInteger(rawDate.day, path .. '.day')
    if not day then return nil, dayErr end
    if day < 1 or day > 31 then
      return nil, path .. '.day: expected value between 1 and 31'
    end
    out.day = day
  end
  if rawDate.year ~= nil then
    local year, yearErr = parseInteger(rawDate.year, path .. '.year')
    if not year then return nil, yearErr end
    out.year = year
  end
  if next(out) == nil then
    return nil, path .. ': expected at least one of month, day, or year'
  end
  if opts.forRange and (out.month == nil or out.day == nil) then
    return nil, path .. ': date range endpoints require month and day'
  end
  return out, nil
end
local function compareDate(left, right, ignoreYear)
  local leftYear = not ignoreYear and tonumber(left.year) or 0
  local rightYear = not ignoreYear and tonumber(right.year) or 0
  if leftYear ~= rightYear then return leftYear < rightYear and -1 or 1 end
  local leftMonth = assert(tonumber(left.month), 'date comparison requires month')
  local rightMonth = assert(tonumber(right.month), 'date comparison requires month')
  if leftMonth ~= rightMonth then return leftMonth < rightMonth and -1 or 1 end
  local leftDay = assert(tonumber(left.day), 'date comparison requires day')
  local rightDay = assert(tonumber(right.day), 'date comparison requires day')
  if leftDay ~= rightDay then return leftDay < rightDay and -1 or 1 end
  return 0
end
local function matchesDate(time, spec)
  if spec.month ~= nil and time.month ~= tonumber(spec.month) then return false end
  if spec.day ~= nil and time.day ~= tonumber(spec.day) then return false end
  if spec.year ~= nil and time.year ~= tonumber(spec.year) then return false end
  return true
end
local function matchesDateRange(time, rangeSpec)
  assert(type(rangeSpec) == 'table', 'date.range must be an object')
  local fromDate = assert(rangeSpec.from, 'date.range requires from')
  local toDate = assert(rangeSpec.to, 'date.range requires to')
  assert(fromDate.month ~= nil and fromDate.day ~= nil, 'date.range.from requires month and day')
  assert(toDate.month ~= nil and toDate.day ~= nil, 'date.range.to requires month and day')
  local inclusive = rangeSpec.inclusive ~= false
  local hasFromYear = fromDate.year ~= nil
  local hasToYear = toDate.year ~= nil
  if hasFromYear ~= hasToYear then
    -- A single year caps a recurring month/day window at that endpoint.
    if hasFromYear and compareDate(time, fromDate) < 0 then return false end
    if hasToYear then
      local endComparison = compareDate(time, toDate)
      if endComparison > 0 or (endComparison == 0 and not inclusive) then
        return false
      end
    end
  end
  local ignoreYear = not (hasFromYear and hasToYear)
  local cmpFrom = compareDate(time, fromDate, ignoreYear)
  local cmpTo = compareDate(time, toDate, ignoreYear)
  if compareDate(fromDate, toDate, ignoreYear) <= 0 then
    if inclusive then
      return cmpFrom >= 0 and cmpTo <= 0
    end
    return cmpFrom >= 0 and cmpTo < 0
  end
  if inclusive then
    return cmpFrom >= 0 or cmpTo <= 0
  end
  return cmpFrom >= 0 or cmpTo < 0
end
local function matchesTime(spec, time)
  spec = spec or {}
  local isWeekend = nil
  if spec.flags and spec.flags.isWeekend ~= nil then
    isWeekend = spec.flags.isWeekend == true
  end
  if not time then return false end
  if spec.hour ~= nil and not matchesScalar(time.hour, spec.hour, 'hour', SCALAR_OPTS) then return false end
  if spec.month ~= nil and not matchesScalar(time.month, spec.month, 'month', SCALAR_OPTS) then return false end
  if spec.day ~= nil and not matchesScalar(time.day, spec.day, 'day', SCALAR_OPTS) then return false end
  if spec.dayOfWeek ~= nil and not matchesScalar(time.dayOfWeek, spec.dayOfWeek, 'dayOfWeek', SCALAR_OPTS) then return false end
  if spec.yearDay ~= nil and not matchesScalar(time.yearDay, spec.yearDay, 'yearDay', SCALAR_OPTS) then return false end
  if spec.season ~= nil then
    local allowed = spec.season
    if allowed.eq ~= nil then
      if time.season ~= allowed.eq:lower() then return false end
    else
      local matched = false
      for _, season in ipairs(assert(allowed.any, 'season requires eq or any')) do
        if time.season == season:lower() then matched = true; break end
      end
      if not matched then return false end
    end
  end
  if spec.date ~= nil then
    local dates = spec.date
    if dates.range ~= nil then
      if not matchesDateRange(time, dates.range) then return false end
    elseif dates.eq ~= nil then
      if not matchesDate(time, dates.eq) then return false end
    else
      local matched = false
      for _, date in ipairs(assert(dates.any, 'date requires eq, any, or range')) do
        if matchesDate(time, date) then matched = true; break end
      end
      if not matched then return false end
    end
  end
  if isWeekend ~= nil then
    local weekend = time.dayOfWeek == 1 or time.dayOfWeek == 7
    if weekend ~= isWeekend then return false end
  end
  return true
end
local function dateNeedsYear(dateSpec)
  if type(dateSpec) ~= 'table' then return false end
  if type(dateSpec.eq) == 'table' and dateSpec.eq.year ~= nil then return true end
  for i = 1, #(dateSpec.any or {}) do
    if dateSpec.any[i].year ~= nil then return true end
  end
  local range = dateSpec.range
  return type(range) == 'table'
    and ((type(range.from) == 'table' and range.from.year ~= nil)
      or (type(range.to) == 'table' and range.to.year ~= nil))
end
local function validateSnapshot(program, time)
  for i = 1, #SCALAR_FIELDS do
    local field = SCALAR_FIELDS[i]
    if program[field] ~= nil and type(time[field]) ~= 'number' then
      return nil, 'time provider returned invalid ' .. field
    end
  end
  if program.season ~= nil and type(time.season) ~= 'string' then
    return nil, 'time provider returned invalid season'
  end
  if program.date ~= nil then
    if type(time.month) ~= 'number' or type(time.day) ~= 'number' then
      return nil, 'time provider returned invalid date'
    end
    if dateNeedsYear(program.date) and type(time.year) ~= 'number' then
      return nil, 'time provider returned invalid year'
    end
  end
  if program.flags and program.flags.isWeekend ~= nil
      and type(time.dayOfWeek) ~= 'number' then
    return nil, 'time provider returned invalid dayOfWeek'
  end
  return true, nil
end
local function eventForSpec(spec)
  spec = spec or {}
  if spec.hour ~= nil then
    return 'timeHourChanged'
  end
  return 'timeDayChanged'
end
return {
  id = 'time',
  needsScene = false,
  abiVersion = 0,
  behaviorVersion = 0,
  programVersion = 0,
  lowerTuple = function(tuple, path)
    local field = tuple[2]
    if type(field) ~= 'string' or field == '' then
      return nil, path .. '[2]: expected time field path'
    end
    local spec = { type = 'time' }
    if field == 'flags.isWeekend' then
      local flagValue, flagErr = parseBoolean(tuple[3], path .. '[3]')
      if not flagValue and flagErr then return nil, flagErr end
      if tuple[4] ~= nil then
        return nil, path .. ': flags.isWeekend tuple is too long'
      end
      spec.flags = { isWeekend = flagValue }
      return spec, nil
    end
    local op = tuple[3]
    if type(op) ~= 'string' or op == '' then
      return nil, path .. '[3]: expected operator string'
    end
    if field == 'date' then
      if op == 'eq' then
        local dateEq, dateErr = normalizeDatePoint(tuple[4], path .. '[4]')
        if not dateEq then return nil, dateErr end
        if tuple[5] ~= nil then return nil, path .. ': date eq tuple is too long' end
        spec.date = { eq = dateEq }
        return spec, nil
      end
      if op == 'any' then
        if not isArray(tuple[4]) then
          return nil, path .. '[4]: expected array of date objects'
        end
        local dates = {}
        for i, rawDate in ipairs(tuple[4]) do
          local dateValue, dateErr = normalizeDatePoint(rawDate, path .. '[4][' .. tostring(i) .. ']')
          if not dateValue then return nil, dateErr end
          dates[#dates + 1] = dateValue
        end
        if #dates == 0 then return nil, path .. '[4]: expected at least one date object' end
        if tuple[5] ~= nil then return nil, path .. ': date any tuple is too long' end
        spec.date = { any = dates }
        return spec, nil
      end
      if op == 'range' then
        local fromDate, fromErr = normalizeDatePoint(tuple[4], path .. '[4]', { forRange = true })
        if not fromDate then return nil, fromErr end
        local toDate, toErr = normalizeDatePoint(tuple[5], path .. '[5]', { forRange = true })
        if not toDate then return nil, toErr end
        local inclusive, inclusiveErr = parseRangeMode(tuple[6], path .. '[6]')
        if inclusive == nil then return nil, inclusiveErr end
        if tuple[7] ~= nil then return nil, path .. ': date range tuple is too long' end
        spec.date = {
          range = {
            from = fromDate,
            to = toDate,
            inclusive = inclusive,
          },
        }
        return spec, nil
      end
      return nil, path .. '[3]: unsupported date operator ' .. tostring(op)
    end
    if field == 'season' then
      if op == 'eq' then
        if type(tuple[4]) ~= 'string' or tuple[4] == '' then
          return nil, path .. '[4]: expected season string'
        end
        if tuple[5] ~= nil then return nil, path .. ': season eq tuple is too long' end
        spec.season = { eq = tostring(tuple[4]):lower() }
        return spec, nil
      end
      if op == 'any' then
        if not isArray(tuple[4]) then
          return nil, path .. '[4]: expected season array'
        end
        local values = {}
        for i, rawValue in ipairs(tuple[4]) do
          if type(rawValue) ~= 'string' or rawValue == '' then
            return nil, path .. '[4][' .. tostring(i) .. ']: expected season string'
          end
          values[#values + 1] = tostring(rawValue):lower()
        end
        if #values == 0 then return nil, path .. '[4]: expected at least one season' end
        if tuple[5] ~= nil then return nil, path .. ': season any tuple is too long' end
        spec.season = { any = values }
        return spec, nil
      end
      return nil, path .. '[3]: unsupported season operator ' .. tostring(op)
    end
    if not SCALAR_FIELD_SET[field] then
      return nil, path .. '[2]: unsupported time field ' .. tostring(field)
    end
    local scalarSpec, scalarErr = lowerScalarTuple(tuple, path, 3)
    if not scalarSpec then return nil, scalarErr end
    spec[field] = scalarSpec
    return spec, nil
  end,
  compileProgram = function(spec)
    return {
      program = spec,
      subscriptions = {eventForSpec(spec)},
    }
  end,
  evaluate = function(program, capabilities)
    local readTime = capabilities and capabilities.readTime or nil
    if type(readTime) ~= 'function' then
      return {state = 'unknown', reason = 'time provider unavailable'}
    end
    local time, err = readTime()
    if type(time) ~= 'table' then
      return {state = 'unknown', reason = tostring(err or 'time state unavailable')}
    end
    local valid, validationError = validateSnapshot(program, time)
    if not valid then return {state = 'unknown', reason = validationError} end
    return {state = matchesTime(program, time) and 'active' or 'inactive'}
  end,
}
