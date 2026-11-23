-- Coroutine waits and engine controls used to drive scenario state.
local C = require('scripts.mom_test_orchestrator.constants')
local values = require('scripts.mom_test_orchestrator.support.values')
local world_support = require('scripts.mom_test_orchestrator.support.world')
local calendar = require('openmw_aux.calendar')
local core = require('openmw.core')
local types = require('openmw.types')
local world = require('openmw.world')

local M = {}

function M.waitFrames(count)
  count = math.max(0, math.floor(tonumber(count) or 0))
  for _ = 1, count do
    coroutine.yield()
  end
end

-- OpenMW catches up at most one regional-weather interval per update after a
-- time jump. Allow one update per elapsed hour (the stock interval is 20 hours;
-- this assumes the configured interval is at least one hour), plus two for
-- the queued time action and its first weather update.
function M.waitForWeatherCatchup(hours)
  M.waitFrames(math.ceil(math.max(0, tonumber(hours) or 0)) + 2)
end

function M.waitUntil(predicate, timeoutFrames, description, minRealSeconds)
  timeoutFrames = math.max(1, math.floor(tonumber(timeoutFrames) or C.DEFAULT_TIMEOUT_FRAMES))
  minRealSeconds = math.max(0, tonumber(minRealSeconds) or 0)
  local startedAt = minRealSeconds > 0 and core.getRealTime() or nil
  local frames = 0
  while frames < timeoutFrames
    or (startedAt ~= nil and core.getRealTime() - startedAt < minRealSeconds)
  do
    if predicate() then
      return
    end
    frames = frames + 1
    coroutine.yield()
  end
  error(string.format('Timed out waiting for %s', tostring(description or 'condition')))
end

-- Time helpers

function M.currentHour()
  local timeParts = calendar.formatGameTime('*t')
  return (timeParts.hour or 0) + (timeParts.min or 0) / 60 + (timeParts.sec or 0) / 3600
end

function M.advanceToHour(targetHour)
  local current = M.currentHour()
  local delta = tonumber(targetHour) - current
  if math.abs(delta) < 0.001 then
    return
  end
  while delta <= 0 do
    delta = delta + 24
  end
  world.advanceTime(delta)
  -- Publish the clock change to the engine update before a subsequent cell
  -- load or clock change. Result predicates handle the remaining work.
  coroutine.yield()
  M.waitUntil(function()
    local difference = math.abs(M.currentHour() - tonumber(targetHour)) % 24
    return math.min(difference, 24 - difference) < 0.05
  end, C.DEFAULT_TIMEOUT_FRAMES, 'requested game hour')
  M.waitForWeatherCatchup(delta)
end

-- Teleport helpers

function M.teleportInterior(cellName, position, description)
  local actor = assert(world_support.player(), 'Player unavailable for teleport')
  actor:teleport(cellName, values.vector3From(position), { onGround = true })
  M.waitUntil(function()
    local cur = actor.cell
    return cur
      and cur.isExterior ~= true
      and values.normalizeCellId(cur.id) == values.normalizeCellId(cellName)
  end, C.LONG_TIMEOUT_FRAMES, description or ('teleport to ' .. tostring(cellName)))
end

function M.teleportExterior(gridX, gridY, position, description)
  local actor = assert(world_support.player(), 'Player unavailable for teleport')
  actor:teleport('', values.vector3From(position), { onGround = true })
  M.waitUntil(function()
    local cur = actor.cell
    return cur
      and cur.isExterior == true
      and cur.gridX == gridX
      and cur.gridY == gridY
  end, C.LONG_TIMEOUT_FRAMES, description or string.format('teleport to exterior %d,%d', gridX, gridY))
end

function M.teleportInteriorReady(cellName, position, description, predicate, timeoutFrames, minRealSeconds)
  M.teleportInterior(cellName, position, description)
  local cell = M.requireCurrentInterior(cellName)
  if predicate then
    M.waitUntil(function()
      return predicate(cell)
    end, timeoutFrames or C.LONG_TIMEOUT_FRAMES, description, minRealSeconds)
  end
  return cell
end

function M.teleportExteriorReady(gridX, gridY, position, description, predicate, timeoutFrames, minRealSeconds)
  M.teleportExterior(gridX, gridY, position, description)
  local cell = M.requireCurrentExterior(gridX, gridY)
  if predicate then
    M.waitUntil(function()
      return predicate(cell)
    end, timeoutFrames or C.LONG_TIMEOUT_FRAMES, description, minRealSeconds)
  end
  return cell
end

function M.teleportInteriorAtHour(hour, cellName, position, description)
  M.advanceToHour(hour)
  M.teleportInterior(cellName, position, description)
  return M.requireCurrentInterior(cellName)
end

function M.advanceLoadedInteriorToHour(hour, cellName)
  M.advanceToHour(hour)
  return M.requireCurrentInterior(cellName)
end

-- Assertion helpers

function M.expect(condition, message)
  if condition then return end
  error(message or 'assertion failed')
end

function M.requireCurrentInterior(cellName)
  local cell = world_support.currentCell()
  M.expect(cell ~= nil, 'No current cell available')
  M.expect(cell.isExterior ~= true, 'Expected interior cell ' .. tostring(cellName))
  M.expect(values.normalizeCellId(cell.id) == values.normalizeCellId(cellName),
    'Expected current cell ' .. tostring(cellName) .. ', got ' .. tostring(cell.id))
  return cell
end

function M.requireCurrentExterior(gridX, gridY)
  local cell = world_support.currentCell()
  M.expect(cell ~= nil, 'No current cell available')
  M.expect(cell.isExterior == true, 'Expected exterior cell')
  M.expect(cell.gridX == gridX and cell.gridY == gridY,
    string.format('Expected exterior %d,%d, got %s', gridX, gridY, tostring(cell.id)))
  return cell
end

-- Quest helpers

local function questFor(questId, purpose)
  local actor = assert(world_support.player(), 'Player unavailable for quest lookup')
  local quests = assert(types.Player and types.Player.quests and types.Player.quests(actor),
    'Player quest API unavailable')
  local quest = quests[questId] or quests[values.normalizeRecordId(questId)]
  M.expect(quest ~= nil, 'Quest not available for ' .. tostring(purpose) .. ': ' .. tostring(questId))
  return quest
end

function M.currentQuestStage(questId)
  local quest = questFor(questId, 'lookup')
  return quest.stage
end

function M.setQuestStage(questId, stage)
  local quest = questFor(questId, 'mutation')
  if quest.stage == stage then
    return
  end
  quest.stage = stage
end

-- Weather helpers

function M.settleWeatherTransitions()
  -- OpenMW has a hidden queued transition behind getNext. Drain it before
  -- requesting weather: requesting the same value as getNext does not replace
  -- an older queued value.
  local gameTime
  local observedFrames = 0
  local function advanceWeather()
    gameTime = core.getGameTime()
    observedFrames = 0
    world.advanceTime(0.001)
  end
  advanceWeather()
  M.waitUntil(function()
    -- OpenMW stores the hour as a float; allow for its rounding.
    if core.getGameTime() < gameTime + 3.59 then return false end
    -- The time action and weather update are separate engine steps. A region
    -- update can start another transition after fast-forwarding the first.
    observedFrames = observedFrames + 1
    if observedFrames < 2 then return false end
    local activeCell = world_support.currentCell()
    if activeCell and (activeCell.isExterior or activeCell.hasSky)
        and core.weather.getNext(activeCell) ~= nil then
      advanceWeather()
      return false
    end
    return true
  end, C.LONG_TIMEOUT_FRAMES, 'weather transitions to settle')
end

-- Force weather in a region by scriptId, after draining queued transitions.
function M.changeWeather(regionId, scriptId)
  local region = core.regions.records[tostring(regionId):lower()]
  M.expect(region ~= nil, 'Region not found: ' .. tostring(regionId))

  local weatherRecord = nil
  for _, rec in pairs(core.weather.records) do
    if rec.scriptId == scriptId then
      weatherRecord = rec
      break
    end
  end
  M.expect(weatherRecord ~= nil, 'Weather record not found for scriptId: ' .. tostring(scriptId))

  M.settleWeatherTransitions()

  core.weather.changeWeather(region.id, weatherRecord)
  -- Weather is observable only in an active cell with sky. When configuring
  -- a region before travel, the destination's effect predicate supplies readiness.
  local cell = world_support.currentCell()
  if cell and (cell.isExterior or cell.hasSky)
      and values.normalizeRecordId(cell.region) == values.normalizeRecordId(region.id) then
    M.waitUntil(function()
      local weather = core.weather.getNext(cell) or core.weather.getCurrent(cell)
      return weather ~= nil and weather.scriptId == scriptId
    end, C.LONG_TIMEOUT_FRAMES, 'requested region weather')
  end
end

function M.resetScenarioState()
  local api = world_support.momInterface()
  if api and api.logLevel then
    api.logLevel('info')
  end

  M.setQuestStage(C.KNIGHT_AKAY_QUEST, 0)
  M.advanceToHour(2.0)
end

-- MOM readiness

return M
