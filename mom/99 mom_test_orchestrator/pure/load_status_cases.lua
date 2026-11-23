local M = {}
local support = require('pure.test_support')
local status = require('scripts.mom.compiler.load_status')
local canonical = require('scripts.mom.contracts.canonical')
local function ready()
  return {version = status.VERSION, status = 'ready', sourceHash = canonical.assertHash({'input'}),
    decisions = '3:91',
    content = {status = 'committed', contentHash = canonical.assertHash({'content'}),
      changedCount = 2, noopCount = 3, createdCount = 1, attemptedWrites = 2}}
end
function M.run()
  return support.runCases('LOAD lifecycle status', {
    {'fixed metadata and 2-bit decisions round trip cleanly', function()
      local input = ready()
      local encoded = assert(status.encode(input))
      local decoded = assert(status.decode(encoded))
      support.expect(decoded.sourceHash == input.sourceHash and decoded.content.changedCount == 2
        and decoded.decisions == '3:91'
        and #encoded < 4096 and decoded.targets == nil and decoded.actions == nil, 'invalid metadata')
    end},
    {'preparing cannot be confused with committed content', function()
      local values = {}
      local writer = status.writer(values)
      assert(writer.prepare())
      support.expect(assert(status.read(function(key) return values[key] end)).status == 'preparing', 'missing fence')
      assert(writer.publish(ready()))
      support.expect(assert(status.read(function(key) return values[key] end)).status == 'ready', 'terminal outcome missing')
    end},
    {'foreign namespace and write failures are preserved', function()
      local values = {[status.KEY] = 'foreign'}
      support.expect(status.writer(values).prepare() == nil and values[status.KEY] == 'foreign', 'foreign GMST overwritten')
      local failing = setmetatable({}, {__newindex = function() error('write fault') end})
      support.expect(status.writer(failing).prepare() == nil, 'write failure hidden')
    end},
    {'malformed and noncanonical status cannot grant activation', function()
      local valid = assert(status.encode(ready()))
      for _, raw in ipairs({'', 'MOMLOAD1', 'MOMLOAD3', valid .. '|extra', valid:gsub('|2|3|1|2|', '|02|3|1|2|'),
        valid:gsub('|3:91|', '|3:9|'), valid:gsub('|3:91|', '|3:ZZ|'),
        valid:gsub('ready', 'unknown'), valid:gsub('mom64:', 'bad:', 1), string.rep('x', 4097)}) do
        support.expect(status.decode(raw) == nil, 'invalid status accepted')
      end
      local input = ready(); input.content.attemptedWrites = 1
      support.expect(status.encode(input) == nil, 'inconsistent write count accepted')
    end},
    {'failure diagnostics stay bounded plain text', function()
      local encoded = assert(status.encode({version = status.VERSION, status = 'failed',
        content = {status = 'partial'}, message = string.rep('bad|\n', 2000)}))
      local decoded = assert(status.decode(encoded))
      support.expect(#decoded.message == 2048 and not decoded.message:find('[|\n]') and #encoded < 4096,
        'status diagnostic escaped fixed framing')
    end},
  })
end
return M
