local H = require('scripts.mom_test_orchestrator.helpers')
local C = require('scripts.mom_test_orchestrator.constants')
local types = require('openmw.types')
local I = require('openmw.interfaces')
local model = require('scripts.mom.contracts.model_path')
local campaign = require('scripts.mom_test_orchestrator.campaign_control')
local M = {RECORD = 'mom_test_content_static', MODEL = 'meshes/f/furn_de_tapestry_03.nif',
  POSITION = {x = 3400, y = 3300, z = -100}}

local function output(cell)
  return H.findFirstObject(cell, function(object)
    return H.objectRecordId(object) == M.RECORD and H.positionNear(object.position, M.POSITION, 1)
  end)
end
local function count(cell)
  return H.countObjects(cell, function(object) return H.objectRecordId(object) == M.RECORD end)
end

function M.verify(options)
  options = options or {}
  local changed = options.changedDefinitions == true
  local expectedModel = changed and 'meshes/f/furn_de_tapestry_04.nif' or M.MODEL
  local expectedName = changed and 'MOM revised phase book' or 'MOM mixed phase book'
  local expectedText = changed and 'MOM revised content after a process restart.' or 'MOM shared content phase.'
  local expectedLevel = changed and 65534 or 65535
  local report = assert(I.MOM.compileReport({log = false}))
  local startup = report.startup
  H.expect(startup and startup.status == 'ready' and startup.content.status == 'committed'
      and type(startup.sourceHash) == 'string' and type(startup.content.contentHash) == 'string'
      and startup.content.changedCount >= 3 and startup.content.createdCount >= 1
      and startup.content.noopCount >= 1,
    'mixed source LOAD result was not committed independently of GLOBAL')
  local summary = report.summary
  H.expect(summary and summary.byFamily.record_content == nil and summary.byFamily.leveled_content == nil
      and (summary.byFamily.place_ref or 0) >= 1,
    'LOAD declarations leaked into the GLOBAL manifest')
  if options.singleSource then
    H.expect(summary.manifest.actions == 1 and summary.manifest.owners == 0,
      'single mixed source did not compile exactly its one GLOBAL placement')
  end
  local book = assert(types.Book.records.bk_lustyargonianmaid)
  H.expect(book.name == expectedName and book.text == expectedText
      and math.abs(book.weight - 0.25) < 0.000001, 'Book definition was not visible in GLOBAL')
  H.expect(model.normalize(assert(types.Static.records.furn_de_tapestry_03).model) == M.MODEL,
    'record-ID exclusion did not prevent a uniform LOAD model write')
  local static = assert(types.Static.records[M.RECORD])
  H.expect(model.normalize(static.model) == expectedModel, 'named LOAD record was unavailable in GLOBAL')
  local list = assert(types.LevelledCreature.records['ex_westgash_lev+0'])
  local duplicates, oldEntries = 0, 0
  for _, entry in ipairs(list.creatures) do
    if entry.id:lower() == 'rat' and entry.level == expectedLevel then duplicates = duplicates + 1 end
    if changed and entry.id:lower() == 'rat' and entry.level == 65535 then oldEntries = oldEntries + 1 end
  end
  H.expect(duplicates == 2 and oldEntries == 0 and list.chanceNone == 0,
    'leveled entries lost weighting duplicates or LOAD edits reapplied')

  local cell = H.teleportInteriorReady(C.GUILD_OF_MAGES, C.GUILD_SAFE_POSITION,
    'mixed content placement', function(current) return output(current) ~= nil end)
  H.waitUntil(function()
    local current = output(cell)
    return count(cell) == 1 and current and current.enabled == true
  end, C.LONG_TIMEOUT_FRAMES,
    'one runtime output from the named content definition')
  local placed = assert(output(cell))
  H.expect(placed.enabled == true and model.normalize(types.Static.record(placed).model) == expectedModel,
    'GLOBAL placement did not use the LOAD-created record')
  local objectId = tostring(placed.id)
  H.waitFrames(30)
  local after = assert(I.MOM.compileReport({log = false})).startup
  H.expect(count(cell) == 1 and after.sourceHash == startup.sourceHash
      and after.content.contentHash == startup.content.contentHash
      and after.content.attemptedWrites == startup.content.attemptedWrites,
    'content or runtime placement replayed during support reads')
  if options.reloaded then
    H.expect(objectId == campaign.handoffValue('content.output'), 'runtime output identity changed after reload')
    H.expect(report.activeManifestHash == campaign.handoffValue('content.runtime'),
      'LOAD-only definition changes altered the GLOBAL placement manifest')
    if changed then
      H.expect(startup.sourceHash ~= campaign.handoffValue('content.source'), 'edited LOAD input retained the previous source hash')
      H.expect(startup.content.contentHash ~= campaign.handoffValue('content.plan'), 'edited definitions retained the previous content plan')
    else
      H.expect(startup.sourceHash == campaign.handoffValue('content.source'), 'LOAD source changed across the same-design save')
      H.expect(startup.content.contentHash == campaign.handoffValue('content.plan'), 'content plan changed across the same-design save')
    end
  end
  return cell, objectId, startup, report.activeManifestHash
end
return M
