-- OpenMW guard read adapter: Morrowind calendar time, coherent observed-cell
-- region weather, player quest stage mirror, region climate, and safe external
-- OpenMW interface provider lookups.
local M = {}

local numbers = require('scripts.mom.common.numbers')
local openmw_api = require('scripts.mom.openmw.api')
local spatial = require('scripts.mom.domain.variation.spatial')
local strings = require('scripts.mom.common.strings')

local call = openmw_api.call
local property = openmw_api.property
local finite = numbers.isFinite
local lower = strings.lowerString

local SEASON_BY_MONTH = {
  'winter', 'winter', 'spring', 'spring', 'spring', 'summer',
  'summer', 'summer', 'autumn', 'autumn', 'autumn', 'winter',
}

local WEATHER_PROB_FIELDS = {
  'clear', 'rain', 'thunderstorm', 'snow', 'blizzard', 'ashstorm', 'blight',
}

function M.new(deps, worldAdapter)
  deps = deps or {}
  local core = openmw_api.dependency(deps, 'core', 'openmw.core')
  local calendar = openmw_api.dependency(deps, 'calendarconfig', 'openmw_aux.calendarconfig')
  local auxTime = openmw_api.dependency(deps, 'time', 'openmw_aux.time')
  local interfaces = openmw_api.dependency(deps, 'interfaces', 'openmw.interfaces')

  local months = calendar and calendar.monthsDuration or {31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31}
  local daysInYear = 0
  for i = 1, #months do daysInYear = daysInYear + months[i] end
  local startingYear = calendar and calendar.startingYear or 427
  local startingYearDay = calendar and calendar.startingYearDay or 228
  local startingWeekDay = calendar and calendar.startingWeekDay or 1
  local daysInWeek = calendar and calendar.daysInWeek or 7
  local secDay = auxTime and auxTime.day or 86400
  local secHour = auxTime and auxTime.hour or 3600
  local secMinute = auxTime and auxTime.minute or 60

  local cachedFrame = -1
  local cachedTime, cachedTimeErr = nil, nil
  local lastTimeMarker = nil
  local observedWeather = {}    -- regionKey -> { known, scriptId, recordId, name, reason }
  local weatherInitialized = false
  local questStages = {}
  local questSnapshotReady = false
  local climateCache = {}

  local function computeTime()
    if not (core and type(core.getGameTime) == 'function') then
      return nil, 'game time is unavailable'
    end
    local gameSeconds, err = call(core.getGameTime)
    if not finite(gameSeconds) then return nil, err or 'game time is unavailable' end
    local absoluteDay = math.floor(gameSeconds / secDay) + startingYearDay - 1
    local year = math.floor(absoluteDay / daysInYear) + startingYear
    local yearDay = absoluteDay % daysInYear + 1
    local dayOfWeek = (absoluteDay + startingWeekDay - startingYearDay) % daysInWeek + 1
    local timeOfDay = gameSeconds % secDay
    local hour = math.floor(timeOfDay / secHour)
    timeOfDay = timeOfDay % secHour
    local minute = math.floor(timeOfDay / secMinute)
    local second = math.floor(timeOfDay) % secMinute
    local month, day = 1, yearDay
    while month <= #months and day > months[month] do
      day = day - months[month]
      month = month + 1
    end
    return {
      gameSeconds = gameSeconds,
      hour = hour,
      minute = minute,
      second = second,
      day = day,
      month = month,
      year = year,
      yearDay = yearDay,
      season = SEASON_BY_MONTH[(month - 1) % #SEASON_BY_MONTH + 1],
      dayOfWeek = dayOfWeek,
      isDay = hour >= 6 and hour < 20,
      isNight = hour < 6 or hour >= 20,
    }, nil
  end

  local function readTimeCached()
    if cachedTime ~= nil or cachedTimeErr ~= nil then
      return cachedTime, cachedTimeErr
    end
    cachedTime, cachedTimeErr = computeTime()
    return cachedTime, cachedTimeErr
  end

  local function scanObservedWeather(watchedRegions)
    if not (core and openmw_api.isNamespace(core.weather)) then
      return {}, false
    end
    local filterTable = type(watchedRegions) == 'table' and watchedRegions or nil
    local nextMap = {}
    for _, entry in pairs(worldAdapter.observedCells()) do
      local facts = entry.facts
      local regionKey = facts and facts.regionKey
      if regionKey ~= nil and (facts.isExterior == true or facts.hasSky == true)
          and (filterTable == nil or filterTable[regionKey] == true) then
        local cell = entry.handle
        local nextW, nextErr = call(core.weather.getNext, cell)
        local curW, curErr = call(core.weather.getCurrent, cell)
        local effective = nextW or curW
        local rec = nextMap[regionKey]
        if rec == nil then
          rec = {known = false, reason = 'weather is unavailable for observed region ' .. regionKey}
          nextMap[regionKey] = rec
        end
        if (nextW == nil and nextErr ~= nil) or (curW == nil and curErr ~= nil) then
          rec.known, rec.invalid, rec.reason = false, true, tostring(nextErr or curErr)
        elseif effective ~= nil and not rec.invalid then
          local scriptId = property(effective, 'scriptId')
          if type(scriptId) ~= 'number' or scriptId % 1 ~= 0 then
            rec.known, rec.invalid, rec.reason = false, true, 'weather scriptId is invalid'
          elseif rec.known and rec.scriptId ~= scriptId then
            rec.known, rec.invalid, rec.reason = false, true, 'weather observations conflict for region ' .. regionKey
          elseif not rec.known then
            rec.known = true
            rec.scriptId = scriptId
            local rid = property(effective, 'recordId')
            local nm = property(effective, 'name')
            rec.recordId = rid ~= nil and tostring(rid) or nil
            rec.name = nm ~= nil and tostring(nm) or nil
            rec.reason = nil
          end
        end
      end
    end
    return nextMap, true
  end

  local function sameWeather(a, b)
    if a == nil or b == nil then return a == b end
    return a.known == b.known and (not a.known or a.scriptId == b.scriptId)
  end

  local reads = {}

  function reads.beginFrame(frame)
    if cachedFrame ~= frame then
      cachedFrame = frame
      cachedTime, cachedTimeErr = nil, nil
    end
  end

  function reads.readTime()
    return readTimeCached()
  end

  function reads.readWeather(regionId)
    local key = lower(regionId)
    if key == nil then return nil, 'weather region is invalid' end
    if not weatherInitialized then
      observedWeather = scanObservedWeather()
      weatherInitialized = true
    end
    local entry = observedWeather[key]
    if entry == nil then return nil, 'weather region is unobserved: ' .. key end
    if not entry.known then return nil, entry.reason end
    return {scriptId = entry.scriptId, recordId = entry.recordId, name = entry.name}, nil
  end

  function reads.readRegionClimate(regionId)
    local key = lower(regionId)
    if key == nil then return nil, nil end
    if climateCache[key] ~= nil then return climateCache[key] or nil, nil end
    local regions = core and property(core, 'regions')
    local records = regions and property(regions, 'records')
    local record = records and property(records, key)
    local probs = record and property(record, 'weatherProbabilities')
    if probs == nil then
      climateCache[key] = false
      return nil, nil
    end
    local values = {}
    for i = 1, #WEATHER_PROB_FIELDS do
      local f = WEATHER_PROB_FIELDS[i]
      values[f] = property(probs, f) or 0
    end
    climateCache[key] = spatial.climate(values)
    return climateCache[key], nil
  end

  function reads.replaceQuestSnapshot(quests)
    questStages = {}
    for k, v in pairs(quests or {}) do
      local id = lower(k)
      local stage = tonumber(v)
      if id ~= nil and stage ~= nil then questStages[id] = stage end
    end
    questSnapshotReady = true
    return true
  end

  function reads.updateQuestStage(questId, stage)
    local id = lower(questId)
    local num = tonumber(stage)
    if id == nil or num == nil then return nil, 'invalid quest stage update' end
    questStages[id] = num
    questSnapshotReady = true
    return id
  end

  function reads.readQuestStage(questId)
    local id = lower(questId)
    if id == nil then return nil, 'quest id is invalid' end
    if not questSnapshotReady then
      return nil, 'quest stage snapshot is unavailable'
    end
    return questStages[id] or 0, nil
  end

  function reads.provider(interfaceName)
    if not strings.isNonEmpty(interfaceName) or interfaces == nil then
      return nil, 'provider interface unavailable'
    end
    local ok, value = pcall(function() return interfaces[interfaceName] end)
    if not ok or value == nil then return nil, 'provider unavailable: ' .. tostring(interfaceName) end
    return value, nil
  end

  -- Polls time hour/day changes and observed-cell weather changes (filtered to
  -- subscribed regions when `watchedWeatherRegions` is a set table).
  -- Returns a list of event names to dispatch to subscribed guard owners.
  function reads.poll(frame, watchTime, watchWeather, watchedWeatherRegions)
    reads.beginFrame(frame)
    local events = {}
    if watchTime then
      local t = readTimeCached()
      local marker = t and {known = true, hour = t.hour, day = tostring(t.year) .. ':' .. tostring(t.yearDay)}
        or {known = false}
      if lastTimeMarker ~= nil then
        if lastTimeMarker.known ~= marker.known or lastTimeMarker.hour ~= marker.hour then
          events[#events + 1] = 'timeHourChanged'
        end
        if lastTimeMarker.known ~= marker.known or lastTimeMarker.day ~= marker.day then
          events[#events + 1] = 'timeDayChanged'
        end
      end
      lastTimeMarker = marker
    end
    if watchWeather then
      local nextMap, ok = scanObservedWeather(watchedWeatherRegions)
      if ok then
        local anyChanged = false
        local changedRegions = {}
        for regionKey, entry in pairs(nextMap) do
          if not weatherInitialized or not sameWeather(entry, observedWeather[regionKey]) then
            anyChanged = true
            changedRegions[regionKey] = true
          end
        end
        if weatherInitialized then
          for regionKey in pairs(observedWeather) do
            if nextMap[regionKey] == nil then
              anyChanged = true
              changedRegions[regionKey] = true
            end
          end
        end
        observedWeather = nextMap
        weatherInitialized = true
        if anyChanged then
          for regionKey in pairs(changedRegions) do
            events[#events + 1] = 'weatherChanged:' .. regionKey
          end
          events[#events + 1] = 'weatherChanged'
        end
      end
    end
    return events
  end

  function reads.clear()
    cachedFrame = -1
    cachedTime, cachedTimeErr = nil, nil
    lastTimeMarker = nil
    observedWeather = {}
    weatherInitialized = false
    questStages = {}
    questSnapshotReady = false
  end

  return reads
end

return M
