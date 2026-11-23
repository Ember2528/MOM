local H = require('scripts.mom_test_orchestrator.helpers')
local G = require('scripts.mom_test_orchestrator.scenarios.support.campaign_guard_common')

local M = {
  SOURCE_RECORD = 'de_p_chest_02_empty',
  OUTPUT_RECORD = 'com_sack_01',
  ITEM_RECORD = 'gold_001',
  ITEM_COUNT = 37,
  POSITION = {x = 1118.174, y = 1444.821, z = -361.513},
}

local function atPosition(cell, recordId)
  return H.findFirstObject(cell, function(obj)
    return H.objectRecordId(obj) == recordId
      and H.positionNear(obj.position, M.POSITION, 16)
  end)
end

function M.source(cell)
  return atPosition(cell, M.SOURCE_RECORD)
end

function M.output(cell)
  return atPosition(cell, M.OUTPUT_RECORD)
end

function M.outputs(cell)
  local rows = {}
  H.eachCellObject(cell, function(obj)
    if H.objectRecordId(obj) == M.OUTPUT_RECORD
        and H.positionNear(obj.position, M.POSITION, 16) then
      rows[#rows + 1] = obj
    end
  end)
  return rows
end

function M.waitBaseline(cell, description)
  H.waitUntil(function()
    local source = M.source(cell)
    return source ~= nil and source.enabled ~= false and M.output(cell) == nil
      and H.countContainerRecord(source, M.ITEM_RECORD) == M.ITEM_COUNT
  end, 1800, description)
end

function M.waitTransferred(cell, description)
  H.waitUntil(function()
    local source = M.source(cell)
    local output = M.output(cell)
    return source ~= nil and source.enabled == false
      and output ~= nil and output.enabled ~= false
      and H.countContainerRecord(source, M.ITEM_RECORD) == 0
      and H.countContainerRecord(output, M.ITEM_RECORD) == M.ITEM_COUNT
  end, 1800, description)
end

function M.logState(cell, label)
  local source = M.source(cell)
  local output = M.output(cell)
  local outputs = M.outputs(cell)
  local enabledOutputs = 0
  for i = 1, #outputs do
    if outputs[i].enabled ~= false then enabledOutputs = enabledOutputs + 1 end
  end
  print(string.format(
    '[MOMCampaign][CONTAINER_STATE] label=%s source=%s sourceEnabled=%s sourceItems=%d output=%s outputEnabled=%s outputItems=%d outputs=%d enabledOutputs=%d',
    tostring(label),
    tostring(source and H.objectRecordId(source) or nil),
    tostring(source and source.enabled or nil),
    source and H.countContainerRecord(source, M.ITEM_RECORD) or -1,
    tostring(output and H.objectRecordId(output) or nil),
    tostring(output and output.enabled or nil),
    output and H.countContainerRecord(output, M.ITEM_RECORD) or -1,
    #outputs,
    enabledOutputs
  ))
end

function M.teleport()
  return G.teleport()
end

return M
