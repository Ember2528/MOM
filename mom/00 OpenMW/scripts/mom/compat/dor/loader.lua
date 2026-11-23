-- Minimal DOR Lua-table loader. It parses the static subset used by DOR config
-- files without executing arbitrary Lua from MWSE-era modules.
local M = {}
local readAll = require('scripts.mom.openmw.vfs')
local function newParser(input)
  local state = {
    input = input,
    len = #input,
    pos = 1,
    lookahead = nil,
  }
  local function parseError(message, pos)
    error(string.format('%s at byte %d', tostring(message), tonumber(pos) or state.pos), 0)
  end
  local function skipTrivia()
    while state.pos <= state.len do
      local ch = state.input:sub(state.pos, state.pos)
      local next_two = state.input:sub(state.pos, state.pos + 1)
      if ch:match('%s') then
        state.pos = state.pos + 1
      elseif next_two == '--' then
        state.pos = state.pos + 2
        if state.input:sub(state.pos, state.pos + 1) == '[[' then
          local close_pos = state.input:find(']]', state.pos + 2, true)
          if not close_pos then
            state.pos = state.len + 1
          else
            state.pos = close_pos + 2
          end
        else
          while state.pos <= state.len and state.input:sub(state.pos, state.pos) ~= '\n' do
            state.pos = state.pos + 1
          end
        end
      else
        break
      end
    end
  end
  local function readString(quote)
    local pos = state.pos
    state.pos = state.pos + 1
    local out = {}
    while state.pos <= state.len do
      local ch = state.input:sub(state.pos, state.pos)
      if ch == quote then
        state.pos = state.pos + 1
        return table.concat(out)
      end
      if ch == '\\' then
        local escaped = state.input:sub(state.pos + 1, state.pos + 1)
        if escaped == '' then
          parseError('unterminated string escape', state.pos)
        end
        local mapped = ({
          ['n'] = '\n',
          ['r'] = '\r',
          ['t'] = '\t',
          ['\\'] = '\\',
          ['\"'] = '\"',
          ["'"] = "'",
        })[escaped] or escaped
        out[#out + 1] = mapped
        state.pos = state.pos + 2
      else
        out[#out + 1] = ch
        state.pos = state.pos + 1
      end
    end
    parseError('unterminated string', pos)
  end
  local function readNumber()
    local start = state.pos
    if state.input:sub(state.pos, state.pos) == '-' then
      state.pos = state.pos + 1
    end
    while state.pos <= state.len and state.input:sub(state.pos, state.pos):match('%d') do
      state.pos = state.pos + 1
    end
    if state.input:sub(state.pos, state.pos) == '.' then
      state.pos = state.pos + 1
      while state.pos <= state.len and state.input:sub(state.pos, state.pos):match('%d') do
        state.pos = state.pos + 1
      end
    end
    local value = tonumber(state.input:sub(start, state.pos - 1))
    if value == nil then
      parseError('invalid number', start)
    end
    return value
  end
  local function readIdentifier()
    local start = state.pos
    state.pos = state.pos + 1
    while state.pos <= state.len and state.input:sub(state.pos, state.pos):match('[%w_]') do
      state.pos = state.pos + 1
    end
    return state.input:sub(start, state.pos - 1)
  end
  local function scanToken()
    skipTrivia()
    if state.pos > state.len then
      return { type = 'eof', pos = state.pos }
    end
    local pos = state.pos
    local ch = state.input:sub(state.pos, state.pos)
    if ch == '{' or ch == '}' or ch == '[' or ch == ']' or ch == '=' or ch == ',' or ch == ';' then
      state.pos = state.pos + 1
      return { type = ch, value = ch, pos = pos }
    end
    if ch == '"' or ch == "'" then
      return { type = 'string', value = readString(ch), pos = pos }
    end
    if ch:match('[%a_]') then
      local ident = readIdentifier()
      if ident == 'local' or ident == 'return' then
        return { type = 'keyword', value = ident, pos = pos }
      end
      if ident == 'true' then
        return { type = 'boolean', value = true, pos = pos }
      end
      if ident == 'false' then
        return { type = 'boolean', value = false, pos = pos }
      end
      if ident == 'nil' then
        return { type = 'nil', value = nil, pos = pos }
      end
      return { type = 'identifier', value = ident, pos = pos }
    end
    if ch:match('%d') or (ch == '-' and state.pos + 1 <= state.len and state.input:sub(state.pos + 1, state.pos + 1):match('%d')) then
      return { type = 'number', value = readNumber(), pos = pos }
    end
    parseError('unsupported token ' .. tostring(ch), pos)
  end
  local function peek()
    if not state.lookahead then
      state.lookahead = scanToken()
    end
    return state.lookahead
  end
  local function consume()
    local token = peek()
    state.lookahead = nil
    return token
  end
  local function expect(token_type, token_value)
    local token = consume()
    if token.type ~= token_type or (token_value ~= nil and token.value ~= token_value) then
      parseError(
        string.format('expected %s%s, got %s', token_type, token_value and (' ' .. tostring(token_value)) or '', token.type),
        token.pos
      )
    end
    return token
  end
  local parseValue
  local function parseKey()
    local token = peek()
    if token.type == 'identifier' then
      consume()
      return token.value
    end
    if token.type == '[' then
      consume()
      local inner = consume()
      if inner.type ~= 'string' and inner.type ~= 'number' and inner.type ~= 'identifier' then
        parseError('expected string, number, or identifier key', inner.pos)
      end
      expect(']')
      return inner.value
    end
    return nil
  end
  local function parseTable(bindings, allow_reference)
    expect('{')
    local out = {}
    local array_index = 1
    while true do
      local token = peek()
      if token.type == '}' then
        consume()
        return out
      end
      if token.type == 'identifier' or token.type == '[' then
        local saved_pos = state.pos
        local saved_lookahead = state.lookahead
        local key = parseKey()
        local after_key = peek()
        if after_key.type == '=' then
          consume()
          out[key] = parseValue(bindings, allow_reference)
        else
          state.pos = saved_pos
          state.lookahead = saved_lookahead
          out[array_index] = parseValue(bindings, allow_reference)
          array_index = array_index + 1
        end
      else
        out[array_index] = parseValue(bindings, allow_reference)
        array_index = array_index + 1
      end
      local separator = peek()
      if separator.type == ',' or separator.type == ';' then
        consume()
      elseif separator.type ~= '}' then
        parseError('expected table separator', separator.pos)
      end
    end
  end
  parseValue = function(bindings, allow_reference)
    local token = peek()
    if token.type == '{' then
      return parseTable(bindings, allow_reference)
    end
    if token.type == 'string' or token.type == 'number' or token.type == 'boolean' or token.type == 'nil' then
      consume()
      return token.value
    end
    if token.type == 'identifier' and allow_reference and bindings[token.value] ~= nil then
      consume()
      return bindings[token.value]
    end
    parseError('unsupported value form', token.pos)
  end
  local function parseChunk()
    local bindings = {}
    while true do
      local token = peek()
      if token.type == 'keyword' and token.value == 'local' then
        consume()
        local name = expect('identifier').value
        expect('=')
        bindings[name] = parseValue(bindings, false)
      else
        break
      end
    end
    local keyword = expect('keyword')
    if keyword.value ~= 'return' then
      parseError('expected return', keyword.pos)
    end
    local value = parseValue(bindings, true)
    expect('eof')
    return value
  end
  return {
    parse = parseChunk,
  }
end
function M.load(path)
  local content, err = readAll(path)
  if not content then
    return nil, err
  end
  local parser = newParser(content)
  return parser.parse(), nil
end
return M
