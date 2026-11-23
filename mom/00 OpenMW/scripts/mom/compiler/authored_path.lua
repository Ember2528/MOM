-- Builds diagnostic paths into the authored source document. Errors use
-- source locations rather than runtime or semantic identifiers.
local M = {}

local function appendSegment(path, segment)
  if type(segment) == 'number' then
    return path .. '[' .. tostring(segment) .. ']'
  end
  if path == '' then return tostring(segment) end
  return path .. '.' .. tostring(segment)
end

local function appendSuffix(path, suffix)
  if suffix == nil or suffix == '' then return path end
  suffix = tostring(suffix)
  if suffix:sub(1, 1) == '[' then return path .. suffix end
  return path .. '.' .. suffix
end

function M.fromActionId(actionId, suffix)
  local id = tostring(actionId or 'action')
  local path
  if id:sub(1, 8) == 'variant:' then
    path = 'variants.' .. id:sub(9)
  elseif id:sub(1, 9) == 'variants.' then
    path = id
  else
    path = 'actions.' .. id
  end
  return appendSuffix(path, suffix)
end

function M.fromSource(source, fallbackActionId, suffix)
  source = type(source) == 'table' and source or {}
  local structuralPath = source.path
  local path = ''
  if type(structuralPath) == 'table'
      and #structuralPath > 0
      and source.adapterId == 'native'
      and type(source.variant) == 'string'
      and source.variant ~= '' then
    path = 'variants.' .. source.variant
  end
  if type(structuralPath) == 'table' and #structuralPath > 0 then
    for i = 1, #structuralPath do
      path = appendSegment(path, structuralPath[i])
    end
  end
  if path == '' then return M.fromActionId(fallbackActionId, suffix) end
  return appendSuffix(path, suffix)
end

function M.append(path, suffix)
  return appendSuffix(tostring(path or 'actions.action'), suffix)
end

-- Resolve diagnostic action labels and their authored locations.
function M.resolveActionId(spec, ctx, default)
  return spec.id or (ctx and ctx.actionId) or default or 'action'
end
function M.authoredActionPath(ctx, actionId, suffix)
  local path = type(ctx) == 'table' and ctx.authoredPath or nil
  if type(path) ~= 'string' or path == '' then
    return M.fromActionId(
      type(ctx) == 'table' and ctx.actionId or actionId,
      suffix
    )
  end
  return M.append(path, suffix)
end
function M.authoredTuplePath(ctx, actionId, verb, tuple)
  return M.authoredActionPath(ctx, actionId, tostring(verb)
    .. '[' .. tostring(tuple.sourceIndex) .. ']')
end

return M
