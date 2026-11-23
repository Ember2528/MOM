local support = require('scripts.mom_test_orchestrator.performance.cases.algorithmic.support')
local container_transfer = support.container_transfer

return function(define)
  define('container_transfer_protocol', {
    version = 4,
    category = 'runtime',
    operations = 256,
    minimumSampleSeconds = 0.0001,
    gcPolicy = 'inclusive',
    semantics = 'steady_state',
    detail = {
      cycles = 256,
      sourceItems = 8,
      defaultItems = 4,
      mode = 'synchronous',
    },
  }, function(measure)
    local ctx = {
      world = {isValid = function(r) return r ~= nil and r.valid ~= false end},
      refOps = {
        setEnabled = function(ref, val) ref.enabled = val == true; return true end,
        readLock = function(ref)
          return {
            locked = ref.lock.locked,
            lockLevel = ref.lock.lockLevel,
            keyRecordId = ref.lock.keyRecordId,
            trapSpellId = ref.lock.trapSpellId,
          }
        end,
        writeLock = function(ref, lock)
          ref.lock = {
            locked = lock.locked,
            lockLevel = lock.lockLevel,
            keyRecordId = lock.keyRecordId,
            trapSpellId = lock.trapSpellId,
          }
          return true
        end,
      },
      inventoryOps = {
        getInventory = function(ref) return ref, 'Container', nil end,
        ensureResolved = function() return true, nil end,
        clearInventory = function(inv) inv.items = {}; return true, nil end,
        moveAllItems = function(from, to)
          local moved = false
          for k, v in pairs(from.items) do
            to.items[k] = (to.items[k] or 0) + v
            moved = true
          end
          from.items = {}
          return true, nil, moved
        end,
      },
    }
    return measure(function()
      for i = 1, 256 do
        local sourceItems, defaultItems = {}, {}
        for j = 1, 8 do sourceItems['src_' .. j] = j end
        for j = 1, 4 do defaultItems['def_' .. j] = 1 end
        local source = {
          valid = true, enabled = true, items = sourceItems,
          lock = {locked = true, lockLevel = 55, keyRecordId = 'k', trapSpellId = 't'},
        }
        local output = {
          valid = true, enabled = false, items = defaultItems,
          lock = {locked = false, lockLevel = 0},
        }
        local applied = assert(container_transfer.apply(source, output, ctx))
        assert(source.enabled == false and output.enabled == true
            and output.lock.lockLevel == 55 and output.items.src_8 == 8
            and output.items.def_1 == nil)
        local reverted = assert(container_transfer.revert(
          source, output, {lock = applied.lock, sourceRespawning = true}, true, ctx
        ))
        assert(reverted.movedItems == true and source.enabled == true
            and output.enabled == false and source.items.src_8 == 8
            and source.lock.lockLevel == 55)
      end
      return 'cycles=256;sourceItems=8;mode=synchronous'
    end)
  end)
end
