local M = {}

local cell_index = require('scripts.mom.compiler.cell_index')
local model_path = require('scripts.mom.openmw.model_path')
local record_index = require('scripts.mom.compiler.record_index')

local METRIC_FIELDS = {
  'cellIndexesBuilt',
  'recordContextsBuilt',
  'cellSelectionPlansBuilt',
  'cellSelectionCacheHits',
  'modelPathQueries',
  'modelPathCacheHits',
}

local function lazyValue(factory, metrics, field)
  local value = nil
  return function()
    if value == nil then
      value = factory()
      metrics[field] = metrics[field] + 1
    end
    return value
  end
end

function M.build(queries, opts)
  opts = opts or {}
  queries = queries or {recordIds = {}, meshPathTypes = {}}
  local metrics = {
    cellIndexesBuilt = 0,
    recordContextsBuilt = 0,
    cellSelectionPlansBuilt = 0,
    cellSelectionCacheHits = 0,
    modelPathQueries = 0,
    modelPathCacheHits = 0,
  }
  local workspace = {
    cellSelectionPlans = {},
    modelPaths = {},
  }
  return {
    contentFileActive = record_index.contentFileActive,
    -- Compiler extensions request only the host indexes they need.
    -- The accessors return stable concrete tables, so iteration and length
    -- retain ordinary Lua semantics after resolution.
    requireCellIndex = lazyValue(
      cell_index.build,
      metrics,
      'cellIndexesBuilt'
    ),
    requireRecordContext = lazyValue(
      function() return record_index.build(queries) end,
      metrics,
      'recordContextsBuilt'
    ),
    modelExists = function(path)
      metrics.modelPathQueries = metrics.modelPathQueries + 1
      local exists, normalized, err, cacheHit = model_path.modelExists(
        path,
        workspace.modelPaths
      )
      if cacheHit then
        metrics.modelPathCacheHits = metrics.modelPathCacheHits + 1
      end
      return exists, normalized, err
    end,
    diagnosticCollector = opts.diagnosticCollector,
    workspace = workspace,
    metrics = metrics,
  }, nil
end

function M.metrics(context)
  local metrics = type(context) == 'table' and context.metrics or nil
  local out = {}
  for i = 1, #METRIC_FIELDS do
    local field = METRIC_FIELDS[i]
    out[field] = type(metrics) == 'table' and metrics[field] or 0
  end
  return out
end

return M
