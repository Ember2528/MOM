-- One source frontend, invoked independently in each context. Actions define
-- their own LOAD and GLOBAL compile paths; LOAD resolves catalog-exact
-- interference and passes a compact 2-bit decision receipt to GLOBAL.
local M = {}
local bootstrap = require('scripts.mom.compiler.bootstrap_config')
local canonical = require('scripts.mom.contracts.canonical')
local result = require('scripts.mom.contracts.compiler_result')
local lifecycle = require('scripts.mom.compiler.load_status')
local load_planner = require('scripts.mom.compiler.load_planner')
local bounds = require('scripts.mom.diagnostics.bounds')
local copy = require('scripts.mom.common.tables').copyObject

local function rejected(code, errors)
  if type(errors) ~= 'table' then errors = {tostring(errors)} end
  local details = bounds.sample(errors, nil, function(value) return bounds.text(value, nil, '') end)
  local value = result.rejected({fatal = {code = code, message = table.concat(details, ' | '), errors = details}})
  value.errors = details
  return value
end

local function sourceErrors(aggregated)
  local errors = {}
  for _, attempt in ipairs(aggregated.sourceAttempts) do
    if attempt.status ~= 'resolved' then
      errors[#errors + 1] = tostring(attempt.sourcePath or attempt.path)
        .. ': ' .. tostring(attempt.error and attempt.error.message or 'invalid source')
    end
  end
  return errors
end

local function discoverCatalog()
  local loader = require('scripts.mom.compiler.module_loader')
  local guards, actions
  local function requireGuards()
    if not guards then guards = loader.buildGuardRegistry() end
    return guards
  end
  local function requireActions()
    if not actions then actions = loader.buildActionRegistry() end
    return actions
  end
  local catalog = {
    kind = 'mom-extension-catalog',
    compat = require('scripts.mom.compat.registry').buildRegistry(),
    guards = requireGuards,
  }
  return catalog, requireGuards, requireActions
end

function M.compile(opts)
  opts = opts or {}
  local phase, phaseError = load_planner.phase(opts.phase)
  if not phase then return rejected('compiler_phase_invalid', phaseError) end
  local catalog, requireGuards, requireActions = discoverCatalog()
  local inputs = bootstrap.resolveInputs(opts, catalog)
  local aggregated = bootstrap.loadAggregated(inputs, {catalog = catalog, deferPlacement = true})
  local semantic, normalizationErrors = require('scripts.mom.compiler.action_frontend').normalize(
    aggregated.sourceAttempts, {activeContent = opts.activeContent})
  if not semantic then return rejected('action_semantics_invalid', normalizationErrors) end

  -- Lower & validate guards in BOTH LOAD and GLOBAL so broken guard syntax
  -- rejects atomically before LOAD mutates openmw.content.
  local guardsOk, guardErrors = require('scripts.mom.compiler.source_variant_actions').lowerGuards(
    semantic, requireGuards)
  if not guardsOk then return rejected('guard_semantics_invalid', guardErrors) end

  local actionRegistry = requireActions()
  local content = phase == 'LOAD' and (opts.content or require('openmw.content')) or nil

  local placement, placementErrors
  if phase == 'GLOBAL' and opts.loadDecisions ~= nil then
    placement, placementErrors = load_planner.applyDecisions(
      semantic, opts.loadDecisions, {actionRegistry = actionRegistry})
  else
    placement, placementErrors = load_planner.plan(
      semantic, {actionRegistry = actionRegistry, content = content})
  end
  if not placement then return rejected('action_placement_invalid', placementErrors) end

  local fingerprint = canonical.assertHash({version = 2, inputs = placement.loadInputs})
  if opts.expectedLoadFingerprint ~= nil and fingerprint ~= opts.expectedLoadFingerprint then
    return rejected('load_input_changed', 'LOAD configuration changed; fully restart OpenMW')
  end

  aggregated.sourceAttempts = load_planner.select(semantic, placement, phase)

  local compiled
  if phase == 'LOAD' then
    local errors = sourceErrors(aggregated)
    if #errors > 0 then return rejected('load_source_invalid', errors) end
    local modelCache = {}
    local modelExists = opts.modelExists or function(path)
      return require('scripts.mom.openmw.model_path').modelExists(path, modelCache)
    end
    local plan, planErrors = require('scripts.mom.compiler.content.compile').compile(aggregated, {
      content = content,
      modelExists = modelExists,
      actionRegistry = actionRegistry,
    })
    if not plan then return rejected('content_compile_failed', planErrors) end
    compiled = {status = 'accepted', plan = plan, diagnostics = {}}
  else
    catalog = require('scripts.mom.compiler.discover_extensions').discover({
      actions = actionRegistry,
      guards = requireGuards(),
      compat = catalog.compat,
    })
    compiled = require('scripts.mom.compiler.compile_sources').compile(aggregated, catalog)
    if result.isAccepted(compiled) then compiled.extensionCatalog = catalog end
  end
  compiled.loadFingerprint = fingerprint
  compiled.loadDecisions = placement.encodedDecisions
  compiled.sourceMetrics = {
    phase = phase,
    nativeSources = #inputs.configSources,
    sourceActions = #semantic,
  }
  return compiled
end

function M.installed(opts)
  local status, err = lifecycle.read()
  if not status or status.status ~= 'ready' then
    local failed = rejected('content_startup_failed', err
      or (status and status.message ~= '' and status.message)
      or 'LOAD did not complete; fully restart OpenMW')
    failed.startup = status
    return failed
  end
  local options = copy(opts)
  options.phase = 'GLOBAL'
  options.expectedLoadFingerprint = status.sourceHash
  options.loadDecisions = status.decisions or ''
  local compiled = M.compile(options)
  compiled.startup = status
  return compiled
end

-- Production LOAD boundary: compile first, then invoke the sole writer.
function M.load(opts)
  opts = copy(opts)
  opts.phase = 'LOAD'
  local content = opts.content or require('openmw.content')
  opts.content = content
  local writer = lifecycle.writer(content.gameSettings.records)
  local prepared, err = writer.prepare()
  if not prepared then return nil, err end
  local ok, compiled = pcall(M.compile, opts)
  if not ok or not result.isAccepted(compiled) then
    local failure = ok and type(compiled) == 'table' and compiled.fatal
      and compiled.fatal.message or tostring(compiled)
    writer.publish({
      version = lifecycle.VERSION,
      status = 'failed',
      message = failure,
      content = {status = 'rejected'},
    })
    return nil, failure
  end
  for index = 1, math.min(#compiled.plan.diagnostics, 8) do
    local diagnostic = compiled.plan.diagnostics[index]
    print(('[MOM][INFO][content] %s: %s (%s)'):format(tostring(diagnostic.code),
      tostring(diagnostic.message), tostring(diagnostic.id)):sub(1, 2048))
  end
  if compiled.plan.metrics.unverifiedMembers > 0 then
    print('[MOM][INFO][content] list members without LOAD type/existence verification='
      .. tostring(compiled.plan.metrics.unverifiedMembers))
  end
  local util = opts.util or require('openmw.util')
  local executed, outcome = pcall(require('scripts.mom.compiler.content.executor').execute, compiled.plan, {
    content = content,
    colorFromRGB = function(rgb)
      return util.color.rgb(rgb % 256 / 255, math.floor(rgb / 256) % 256 / 255,
        math.floor(rgb / 65536) % 256 / 255)
    end,
  })
  if not executed then outcome = {status = 'partial', errors = {tostring(outcome)}} end
  local accepted = outcome.status == 'noop' or outcome.status == 'committed'
  local status = {
    version = lifecycle.VERSION,
    status = accepted and 'ready' or 'failed',
    sourceHash = compiled.loadFingerprint,
    decisions = accepted and (compiled.loadDecisions or '') or '',
    content = {
      status = outcome.status,
      contentHash = outcome.contentHash,
      changedCount = outcome.changedCount,
      noopCount = outcome.noopCount,
      createdCount = outcome.createdCount,
      attemptedWrites = outcome.attemptedWrites,
    },
    message = table.concat(outcome.errors or {}, ' | '),
  }
  if #(outcome.cleanupErrors or {}) > 0 then
    status.message = status.message .. ' | ' .. table.concat(outcome.cleanupErrors, ' | ')
  end
  local published, publishError = writer.publish(status)
  if not published then return nil, publishError end
  if not accepted then return nil, status.message end
  return status
end

return M
