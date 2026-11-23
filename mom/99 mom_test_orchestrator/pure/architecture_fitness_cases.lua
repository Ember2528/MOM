local M = {}

local test_support = require('pure.test_support')
local source_files = require('pure.source_files')
local expect = test_support.expect
local fail = test_support.fail

local repoRoot = assert(arg[1], 'repository root argument is required')
local dataRoot = repoRoot .. '/mom/00 OpenMW'
local productionRoot = repoRoot .. '/mom/00 OpenMW/scripts/mom'
local scriptsManifest = repoRoot .. '/mom/00 OpenMW/mom.omwscripts'

local sourceCache, dependencyCache, filesCache = {}, {}, nil

local function read(path)
  if sourceCache[path] then return sourceCache[path] end
  local content, err = source_files.read(path)
  if content == nil then fail('failed reading ' .. tostring(path) .. ': ' .. tostring(err)) end
  sourceCache[path] = content
  return content
end

local exists = source_files.exists

local function productionFiles()
  if filesCache then return filesCache end
  filesCache = source_files.luaFiles(productionRoot)
  return filesCache
end

local function relative(path)
  return path:sub(#productionRoot + 2)
end

local function moduleForPath(path)
  local rel = relative(path):gsub('%.lua$', ''):gsub('/', '.')
  return 'scripts.mom.' .. rel
end

local function pathForModule(moduleName)
  if type(moduleName) ~= 'string' or not moduleName:match('^scripts%.mom%.') then return nil end
  local rel = moduleName:gsub('^scripts%.mom%.', ''):gsub('%.', '/')
  return productionRoot .. '/' .. rel .. '.lua'
end

local function longBracket(content, startIndex)
  if content:sub(startIndex, startIndex) ~= '[' then return nil end
  local cursor = startIndex + 1
  while content:sub(cursor, cursor) == '=' do cursor = cursor + 1 end
  if content:sub(cursor, cursor) ~= '[' then return nil end
  local equals = content:sub(startIndex + 1, cursor - 1)
  local close = ']' .. equals .. ']'
  local closeStart = content:find(close, cursor + 1, true)
  if closeStart == nil then
    return cursor + 1, #content, #content + 1
  end
  return cursor + 1, closeStart - 1, closeStart + #close
end

-- Tokenize only what the fitness rules need. Unlike a source regex, this
-- distinguishes executable require calls from examples in comments/strings.
local function luaTokens(content)
  local tokens = {}
  local cursor, length = 1, #content
  while cursor <= length do
    local char = content:sub(cursor, cursor)
    local pair = content:sub(cursor, cursor + 1)
    if char:match('%s') then
      cursor = cursor + 1
    elseif pair == '--' then
      local valueStart, valueEnd, nextCursor = longBracket(content, cursor + 2)
      if valueStart ~= nil then
        cursor = nextCursor
      else
        cursor = content:find('\n', cursor + 2, true) or (length + 1)
      end
    elseif char == "'" or char == '"' then
      local quote = char
      local value = {}
      cursor = cursor + 1
      while cursor <= length do
        char = content:sub(cursor, cursor)
        if char == quote then
          cursor = cursor + 1
          break
        elseif char == '\\' and cursor < length then
          value[#value + 1] = content:sub(cursor + 1, cursor + 1)
          cursor = cursor + 2
        else
          value[#value + 1] = char
          cursor = cursor + 1
        end
      end
      tokens[#tokens + 1] = {kind = 'string', value = table.concat(value)}
    elseif char == '[' then
      local valueStart, valueEnd, nextCursor = longBracket(content, cursor)
      if valueStart ~= nil then
        tokens[#tokens + 1] = {
          kind = 'string',
          value = content:sub(valueStart, valueEnd),
        }
        cursor = nextCursor
      else
        tokens[#tokens + 1] = {kind = 'symbol', value = char}
        cursor = cursor + 1
      end
    elseif char:match('[%a_]') then
      local stop = cursor + 1
      while content:sub(stop, stop):match('[%w_]') do stop = stop + 1 end
      tokens[#tokens + 1] = {
        kind = 'identifier',
        value = content:sub(cursor, stop - 1),
      }
      cursor = stop
    else
      tokens[#tokens + 1] = {kind = 'symbol', value = char}
      cursor = cursor + 1
    end
  end
  return tokens
end

local function staticRequires(content)
  if dependencyCache[content] then return dependencyCache[content] end
  local out, seen = {}, {}
  local tokens = luaTokens(content)
  for i = 1, #tokens do
    local token = tokens[i]
    local previous = tokens[i - 1]
    if token.kind == 'identifier' and token.value == 'require'
        and (previous == nil
          or (previous.value ~= '.' and previous.value ~= ':')) then
      local valueIndex = i + 1
      if tokens[valueIndex] and tokens[valueIndex].value == '(' then
        valueIndex = valueIndex + 1
      end
      local value = tokens[valueIndex]
      local moduleName = value and value.kind == 'string' and value.value or nil
      if moduleName ~= nil and not seen[moduleName] then
        seen[moduleName] = true
        out[#out + 1] = moduleName
      end
    elseif token.kind == 'identifier' and token.value == 'bind'
        and previous ~= nil and previous.value == '.'
        and tokens[i - 2] ~= nil and tokens[i - 2].value == 'lazy_hooks' then
      -- lazy_hooks.bind(M, 'scripts.mom.<module>', ...)
      for k = i + 1, math.min(#tokens, i + 6) do
        local candidate = tokens[k]
        if candidate.kind == 'string' and candidate.value:match('^scripts%.mom%.') then
          if not seen[candidate.value] then
            seen[candidate.value] = true
            out[#out + 1] = candidate.value
          end
          break
        end
      end
    end
  end
  table.sort(out)
  dependencyCache[content] = out
  return out
end

local MANIFEST_KINDS = {
  CUSTOM = true,
  GLOBAL = true,
  LOAD = true,
  MENU = true,
  PLAYER = true,
}

local function manifestEntries()
  local entries, seen = {}, {}
  local lineNumber = 0
  for line in (read(scriptsManifest) .. '\n'):gmatch('(.-)\n') do
    lineNumber = lineNumber + 1
    local body = line:gsub('%s*#.*$', ''):match('^%s*(.-)%s*$')
    if body ~= '' then
      local kind, path = body:match('^([A-Z]+)%s*:%s*(%S+)$')
      expect(kind ~= nil and path ~= nil,
        'malformed mom.omwscripts entry at line ' .. tostring(lineNumber))
      expect(MANIFEST_KINDS[kind] == true,
        'unknown mom.omwscripts kind at line ' .. tostring(lineNumber)
          .. ': ' .. tostring(kind))
      local entryKey = kind .. '\0' .. path
      expect(seen[entryKey] ~= true,
        'duplicate mom.omwscripts entry at line ' .. tostring(lineNumber)
          .. ': ' .. kind .. ': ' .. path)
      seen[entryKey] = true
      expect(exists(dataRoot .. '/' .. path),
        'mom.omwscripts entry is missing: ' .. path)
      entries[#entries + 1] = {kind = kind, path = path}
    end
  end
  return entries
end

local function manifestRoots()
  local roots, globals = {}, {}
  for _, entry in ipairs(manifestEntries()) do
    if entry.path:match('^scripts/mom/') then
      roots[#roots + 1] = entry.path:gsub('%.lua$', ''):gsub('/', '.')
      if entry.kind == 'GLOBAL' then globals[#globals + 1] = entry.path end
    end
  end
  return roots, globals
end

local function dynamicExtensionRoots(files)
  local roots = {}
  for i = 1, #files do
    local rel = relative(files[i])
    if rel:match('^actions/[^/]+%.lua$')
        or rel:match('^guards/.+%.lua$')
        or rel:match('^compat/[^/]+/translator%.lua$') then
      roots[#roots + 1] = moduleForPath(files[i])
    end
  end
  return roots
end

local function moduleClosure(roots)
  local seen, queue = {}, {}
  for i = 1, #roots do queue[#queue + 1] = roots[i] end
  local cursor = 1
  while cursor <= #queue do
    local moduleName = queue[cursor]
    cursor = cursor + 1
    if not seen[moduleName] then
      seen[moduleName] = true
      local path = pathForModule(moduleName)
      if path then
        expect(exists(path), 'module closure dependency is missing: ' .. moduleName)
        local dependencies = staticRequires(read(path))
        for i = 1, #dependencies do
          if pathForModule(dependencies[i]) ~= nil then queue[#queue + 1] = dependencies[i] end
        end
      end
    end
  end
  return seen
end

local function entrypointContract()
  local _, globals = manifestRoots()
  expect(#globals == 1 and globals[1] == 'scripts/mom/mom.lua',
    'mom.omwscripts must declare exactly one MOM GLOBAL entrypoint')
end

local function staticRequireLexerContract()
  local dependencies = staticRequires([==[
    -- require('scripts.mom.ignored.line_comment')
    --[=[ require("scripts.mom.ignored.block_comment") ]=]
    local example = "require('scripts.mom.ignored.quoted')"
    local longExample = [=[require('scripts.mom.ignored.long_string')]=]
    local first = require('scripts.mom.real.first')
    local second = require "scripts.mom.real.second"
    local duplicate = require(
      'scripts.mom.real.first'
    )
    local method = object.require('scripts.mom.ignored.method')
  ]==])
  expect(#dependencies == 2
      and dependencies[1] == 'scripts.mom.real.first'
      and dependencies[2] == 'scripts.mom.real.second',
    'Lua-aware require discovery accepted comments/strings/methods or lost calls')
end

local function productionImportsResolve()
  local missing = {}
  local files = productionFiles()
  for i = 1, #files do
    local dependencies = staticRequires(read(files[i]))
    for j = 1, #dependencies do
      local path = pathForModule(dependencies[j])
      if path ~= nil and not exists(path) then
        missing[#missing + 1] = relative(files[i]) .. ' -> ' .. dependencies[j]
      end
    end
  end
  expect(#missing == 0, 'missing production imports: ' .. table.concat(missing, ', '))
end

local function productionReachability()
  local files = productionFiles()
  local roots = manifestRoots()
  local extensionRoots = dynamicExtensionRoots(files)
  for i = 1, #extensionRoots do roots[#roots + 1] = extensionRoots[i] end
  local reachable = moduleClosure(roots)
  local unreachable = {}
  for i = 1, #files do
    local moduleName = moduleForPath(files[i])
    if not reachable[moduleName] then unreachable[#unreachable + 1] = relative(files[i]) end
  end
  expect(#unreachable == 0, 'unreachable production modules: ' .. table.concat(unreachable, ', '))
end

local function productionDependencyGraphIsAcyclic()
  local graph = {}
  for _, path in ipairs(productionFiles()) do
    local moduleName = moduleForPath(path)
    local dependencies = {}
    for _, dependency in ipairs(staticRequires(read(path))) do
      local dependencyPath = pathForModule(dependency)
      if dependencyPath ~= nil and exists(dependencyPath) then
        dependencies[#dependencies + 1] = dependency
      end
    end
    graph[moduleName] = dependencies
  end

  local state, stack, stackIndex = {}, {}, {}
  local function visit(moduleName)
    if state[moduleName] == 2 then return nil end
    if state[moduleName] == 1 then
      local cycle = {}
      for i = stackIndex[moduleName], #stack do
        cycle[#cycle + 1] = stack[i]
      end
      cycle[#cycle + 1] = moduleName
      return table.concat(cycle, ' -> ')
    end
    state[moduleName] = 1
    stack[#stack + 1] = moduleName
    stackIndex[moduleName] = #stack
    for _, dependency in ipairs(graph[moduleName]) do
      local cycle = visit(dependency)
      if cycle ~= nil then return cycle end
    end
    stackIndex[moduleName] = nil
    stack[#stack] = nil
    state[moduleName] = 2
    return nil
  end

  local modules = {}
  for moduleName in pairs(graph) do modules[#modules + 1] = moduleName end
  table.sort(modules)
  for _, moduleName in ipairs(modules) do
    local cycle = visit(moduleName)
    expect(cycle == nil,
      'cyclic production dependencies: ' .. tostring(cycle))
  end
end

local function runtimeCoreDoesNotImportExtensions()
  local violations = {}
  local files = productionFiles()
  for i = 1, #files do
    local rel = relative(files[i])
    local isCore = rel:match('^runtime/') or rel:match('^openmw/')
    if isCore then
      local dependencies = staticRequires(read(files[i]))
      for j = 1, #dependencies do
        if dependencies[j]:match('^scripts%.mom%.actions%.')
            or dependencies[j]:match('^scripts%.mom%.guards%.')
            or dependencies[j]:match('^scripts%.mom%.compat%.[^.]+%.') then
          violations[#violations + 1] = rel .. ' -> ' .. dependencies[j]
        end
      end
    end
  end
  expect(#violations == 0,
    'runtime/openmw core imports concrete extensions: ' .. table.concat(violations, ', '))
end

local function compilerDoesNotImportRuntime()
  local violations = {}
  for _, path in ipairs(productionFiles()) do
    local rel = relative(path)
    if rel:match('^compiler/') then
      for _, dependency in ipairs(staticRequires(read(path))) do
        if dependency:match('^scripts%.mom%.runtime%.') then
          violations[#violations + 1] = rel .. ' -> ' .. dependency
        end
      end
    end
  end
  table.sort(violations)
  expect(#violations == 0,
    'compiler imports the runtime layer: ' .. table.concat(violations, ', '))
end

local function contractsAndLedgerAvoidRuntime()
  local violations = {}
  for _, path in ipairs(productionFiles()) do
    local rel = relative(path)
    if rel:match('^contracts/') or rel:match('^ledger/') then
      for _, dependency in ipairs(staticRequires(read(path))) do
        if dependency:match('^scripts%.mom%.runtime%.') then
          violations[#violations + 1] = rel .. ' -> ' .. dependency
        end
      end
    end
  end
  table.sort(violations)
  expect(#violations == 0,
    'contracts or ledger import runtime execution: '
      .. table.concat(violations, ', '))
end

local function manifestCompilerClosureIsPure()
  local root = 'scripts.mom.compiler.compile_manifest'
  local rootPath = pathForModule(root)
  expect(rootPath ~= nil and exists(rootPath),
    'manifest compiler authority is missing: ' .. root)

  local violations = {}
  for moduleName in pairs(moduleClosure({root})) do
    local path = pathForModule(moduleName)
    if path ~= nil and exists(path) then
      for _, dependency in ipairs(staticRequires(read(path))) do
        if dependency:match('^openmw%.')
            or dependency:match('^scripts%.mom%.runtime%.') then
          violations[#violations + 1] =
            relative(path) .. ' -> ' .. dependency
        end
      end
    end
  end
  table.sort(violations)
  expect(#violations == 0,
    'manifest compiler closure reaches runtime or OpenMW: '
      .. table.concat(violations, ', '))
end

local function runtimeAndLedgerAvoidCompiler()
  local violations = {}
  for _, path in ipairs(productionFiles()) do
    local rel = relative(path)
    if rel:match('^runtime/') or rel:match('^ledger/') or rel == 'app.lua' then
      for _, dependency in ipairs(staticRequires(read(path))) do
        if dependency:match('^scripts%.mom%.compiler%.') then
          violations[#violations + 1] = rel .. ' -> ' .. dependency
        end
      end
    end
  end
  table.sort(violations)
  expect(#violations == 0,
    'runtime or ledger imports the compiler layer: ' .. table.concat(violations, ', '))
end

local function plainLayersDoNotImportOpenmw()
  local violations = {}
  for _, path in ipairs(productionFiles()) do
    local rel = relative(path)
    local plainLayer = rel:match('^common/') or rel:match('^contracts/')
      or rel:match('^domain/') or rel:match('^ledger/')
      or rel:match('^runtime/') or rel:match('^actions/') or rel:match('^guards/')
    if plainLayer then
      for _, dependency in ipairs(staticRequires(read(path))) do
        if dependency:match('^openmw%.') then
          violations[#violations + 1] = rel .. ' -> ' .. dependency
        end
      end
    end
  end
  table.sort(violations)
  expect(#violations == 0,
    'plain production layer imports OpenMW: ' .. table.concat(violations, ', '))
end

local function appLayerAvoidsOpenmw()
  local content = read(productionRoot .. '/app.lua')
  for _, dependency in ipairs(staticRequires(content)) do
    expect(not dependency:match('^openmw%.'),
      'App imports OpenMW directly: ' .. dependency)
  end
end

local CASES = {
  {'entrypoint contract', entrypointContract},
  {'static require lexer contract', staticRequireLexerContract},
  {'production imports resolve', productionImportsResolve},
  {'production reachability', productionReachability},
  {'production dependency graph is acyclic',
    productionDependencyGraphIsAcyclic},
  {'runtime core extension independence', runtimeCoreDoesNotImportExtensions},
  {'compiler avoids runtime', compilerDoesNotImportRuntime},
  {'contracts and ledger avoid runtime', contractsAndLedgerAvoidRuntime},
  {'manifest compiler closure is pure', manifestCompilerClosureIsPure},
  {'runtime and ledger avoid compiler', runtimeAndLedgerAvoidCompiler},
  {'plain layers avoid OpenMW', plainLayersDoNotImportOpenmw},
  {'App layer avoids OpenMW', appLayerAvoidsOpenmw},
}

function M.run()
  sourceCache, dependencyCache, filesCache = {}, {}, nil
  return test_support.runCases('architecture fitness', CASES)
end

return M
