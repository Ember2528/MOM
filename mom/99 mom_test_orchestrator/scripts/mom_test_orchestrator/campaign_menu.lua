local menu = require('openmw.menu')
local storage = require('openmw.storage')
local protocol = require('scripts.mom_test_orchestrator.performance.protocol')

local optionsOk, runOptions = pcall(require, 'scripts.mom_test_orchestrator.run_options')
if not optionsOk or type(runOptions) ~= 'table' then runOptions = {} end

local section = nil
local selectedScenario = type(runOptions.scenarios) == 'table' and runOptions.scenarios[1] or nil
local campaignSelected = type(selectedScenario) == 'string'
  and selectedScenario:match('^campaign_') ~= nil
local handled = false
local quitFrames = nil
local runningObserved = false
local requestObserved = false

local function emitPhaseReceipt(status, event, errorMessage)
  local receipt = {
    schemaVersion = 1,
    kind = 'mom.process-campaign.engine-phase',
    status = status,
    scenario = tostring(selectedScenario),
    event = event,
  }
  if errorMessage ~= nil then receipt.error = tostring(errorMessage) end
  print('[MOMCampaign][PHASE_RECEIPT] ' .. protocol.encode(receipt))
end

if campaignSelected then
  print(string.format(
    '[MOMCampaign][MENU_LOADED] options=%s scenario=%s',
    tostring(optionsOk),
    tostring(selectedScenario)
  ))
end

local function onFrame()
  if not campaignSelected then return end
  if menu.getState() ~= menu.STATE.Running then return end
  if not runningObserved then
    runningObserved = true
    print(string.format('[MOMCampaign][MENU_RUNNING] scenario=%s', tostring(selectedScenario)))
  end
  if quitFrames ~= nil then
    quitFrames = quitFrames - 1
    if quitFrames <= 0 then
      print(string.format('[MOMCampaign][SAVE_COMPLETE] scenario=%s', tostring(selectedScenario)))
      emitPhaseReceipt('passed', 'save_complete')
      menu.quit()
    end
    return
  end
  if handled or type(selectedScenario) ~= 'string' then return end
  if section == nil then section = storage.globalSection('MOMTestCampaignControl') end
  local request = section:get('request')
  if request ~= nil and not requestObserved then
    requestObserved = true
    print(string.format(
      '[MOMCampaign][MENU_REQUEST] type=%s scenario=%s',
      type(request),
      tostring(request.scenarioId)
    ))
  end
  if request == nil or request.scenarioId ~= selectedScenario then return end
  handled = true
  local ok, err = pcall(menu.saveGame, request.description)
  if not ok then
    print(string.format(
      '[MOMCampaign][SAVE_FAILED] scenario=%s error=%s',
      tostring(selectedScenario),
      tostring(err)
    ))
    emitPhaseReceipt('failed', 'save_failed', err)
    menu.quit()
    return
  end
  print(string.format('[MOMCampaign][SAVE_WRITTEN] scenario=%s', tostring(selectedScenario)))
  quitFrames = 5
end

return {
  engineHandlers = {
    onFrame = onFrame,
  },
}
