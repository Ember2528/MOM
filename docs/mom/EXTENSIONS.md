# Implementing MOM Extensions

MOM automatically discovers Lua extensions from OpenMW's virtual filesystem across three extension points: **Action families**, **Guard families**, and **Compatibility translators**.

All compiled programs, tokens, and persisted values must be **acyclic plain data** (tables, strings, numbers, booleans — no functions, metatables, or engine userdata). Keep module tables stateless; per-runtime state belongs in the ledger or runtime context.

---

## 1. Discovery Paths & Versioning

| Extension kind | VFS discovery path | Derived `id` | Current `abiVersion` |
| --- | --- | --- | :---: |
| Action family | `scripts/mom/actions/<id>.lua` (direct children; helpers in subdirs) | `<id>` | `0` |
| Guard family | `scripts/mom/guards/<ns>/<name>.lua` (recursive; skips `init.lua`) | `<ns>.<name>` | `0` |
| Compatibility translator | `scripts/mom/compat/<id>/translator.lua` | `<id>` | `1` |

- Segment names must match `[a-z][a-z0-9_]*`, and the module's declared `id` must match its path.
- Every module declares `abiVersion` and `behaviorVersion` (non-negative integers). Actions and guards also declare `programVersion`; actions with reversal/storage declare `revertTokenVersion` and `storageVersion`.
- Invalid or duplicate IDs are quarantined during discovery; referencing an unavailable family fails compilation or saved-state activation. Runtime activation checks saved op ABI/token versions and calls `validateStoredState` before accepting persisted work.

| Bump when… | Field |
| --- | --- |
| Hook signatures or shared return contracts change | `abiVersion` |
| Identical programs would behave differently | `behaviorVersion` |
| Compiled program schema or semantics change | `programVersion` |
| Persisted capture/revert token layout changes | `revertTokenVersion` |
| Family-owned persistent storage layout changes | `storageVersion` |

Reference implementations: [`module_loader.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/module_loader.lua>), [`extension_registry.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/extension_registry.lua>), [`coordinator.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/coordinator.lua>).

---

## 2. Action Families

YAML verbs map to action families in [`authored_contract.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/authored_contract.lua>) (`place`/`attach` → `place_ref`, `modify` → `modify_ref`, `inventory` → `modify_inventory`, `kill` → `kill_actor`, `record` → `record_content`, `leveled` → `leveled_content`).

### Compiler & Metadata Hooks

| Field / Hook | Required? | Purpose |
| --- | :---: | --- |
| `publicFields` | Yes | Array of family-owned authored field names. |
| `behavior` or `resolveBehavior(spec)` | Yes | Scope (`ref`/`cell`), explicit-cell requirement, parent/child eligibility, and cell-mutation flags. |
| `execution` | Optional | `'global'` (default), `'load'`, or `'split'`. |
| `prepareAction(input, queries, ctx)` | Yes (GLOBAL/split) | Validate syntax, prepare `MomFamilyInput`, and record needed record/mesh lookups in `queries`; return `prepared` or `nil, errors`. |
| `compileAction(input, ctx)` | Yes (GLOBAL/split) | Lower into an array of `mom-family-program` envelopes (or `{}` for an intentional no-op, or `nil, errors`). Declare all `claims` upfront (`contracts/claim_contract.lua`). |
| `validateProgram(program, errors, actionId, helpers)` | Yes (GLOBAL/split) | Append validation errors for compiled program payloads. |
| `validateStoredState(kind, value, ctx)` | Optional | Validate persisted tokens/programs during save activation. |
| `analyzeLoad(node, opts)` / `readFootprint(node)` / `compileLoad(node, loadCtx)` | LOAD / `split` | Action-owned LOAD eligibility proof, interference footprint, and content-plan lowering (see [`actions/place_ref/load.lua`](<../../mom/00 OpenMW/scripts/mom/actions/place_ref/load.lua>)). |
| `outputTypeEnvelope(input, ctx)` | Output parents | Prove possible output OpenMW types so child actions validate cleanly. |
| `prepareTargetFilters(actions)` / `prepareDiscoveryFilters(actions)` | Optional | Build read-only per-action target filter maps at activation (used by `place_ref` choice routing). |

### Runtime & Reconciliation Hooks

```lua
capture(program, target, ctx)                      -- Read-only snapshot; return plain revert token
apply(program, target, token, ctx)                 -- Perform mutation; return result table
revert(token, target, ctx)                         -- Undo reversible mutation; return result table
advance(op, target, ctx)                           -- Resume pending multi-frame op
onLocalComplete(op, completion, ctx)               -- Handle actor-local script reply
reassert(op, target, ctx)                          -- Optional reassertion on cell re-entry
matchesTarget(program, target, facts, ctx)         -- Optional runtime match refinement
transitionKey(program)                             -- Optional O(1) key for in-place static replacement
matchesTransitionSource(program, prevOp)           -- Optional predicate for static replacement eligibility
acceptsGeneratedRoot(program)                      -- Return false to skip MOM-generated outputs as root targets
```

- `apply`, `revert`, and `advance` return `{status = 'applied' | 'noop' | 'failed' | 'pending', changedClaims?, outputs?, pending?, recoveryCells?, message?}`.
- `ctx` (supplied by [`runtime/executor.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/executor.lua>)) provides `frame`, `opId`, `actionId`, `targetId`, `target`, `targetFacts`, `authoredRecordId`, `ledger`, `world`, `refOps`, `inventoryOps`, `placementOps`, `actorOps`, `localBroker`, `targetFilter`, and `choicePort`.
- Always roll back partial mutations if a later step inside `apply` fails.
- See [`kill_actor.lua`](<../../mom/00 OpenMW/scripts/mom/actions/kill_actor.lua>) for a minimal family and [`place_ref.lua`](<../../mom/00 OpenMW/scripts/mom/actions/place_ref.lua>) for a full split family with outputs and transitions.

---

## 3. Guard Families

Put third-party guards in your own namespace folder (e.g. `scripts/mom/guards/my_mod/ready.lua` → `id = 'my_mod.ready'`).

```lua
local M = {
  id = 'my_mod.ready',
  abiVersion = 0,
  behaviorVersion = 0,
  programVersion = 0,
  providerInterface = 'MyModState', -- Optional; binds openmw.interfaces.MyModState.read
}

function M.lowerTuple(tuple, path)
  if type(tuple[2]) ~= 'string' or type(tuple[3]) ~= 'boolean' then
    return nil, path .. ': expected [my_mod.ready, key, boolean]'
  end
  return {type = M.id, key = tuple[2], expected = tuple[3]}
end

function M.compileProgram(spec, ctx)
  return {
    program = {key = spec.key, expected = spec.expected},
    subscriptions = {ctx.guardEvent('my_mod', 'changed', spec.key)},
  }
end

function M.evaluate(program, ctx)
  local provider = ctx.providers[M.id]
  local value, reason = provider and provider.read(program.key)
  if type(value) ~= 'boolean' then
    return {state = 'unknown', reason = tostring(reason or 'provider unavailable')}
  end
  return {state = value == program.expected and 'active' or 'inactive'}
end

return M
```

### Guard Truth & Events

- `evaluate` returns `{state = 'active'}`, `{state = 'inactive'}`, or `{state = 'unknown', reason = '...'}` (no `reason` on known states; exceptions or malformed returns become `unknown`).
- In a conjunction (`when`), `inactive` overrides `unknown`. On `unknown`, MOM retains existing work without applying new work.
- External providers notify MOM after publishing new state:
  ```lua
  core.sendGlobalEvent('MOM_GuardEvent', {event = 'external:my_mod:changed:some_key'})
  ```
- Built-in guards receive `ctx.readTime`, `ctx.readWeather`, and `ctx.readQuestStage`. Reference: [`quest_stage.lua`](<../../mom/00 OpenMW/scripts/mom/guards/quest_stage.lua>), [`runtime/guards.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/guards.lua>).

---

## 4. Compatibility Translators

Translators run in **both LOAD and GLOBAL** and convert foreign file formats into ordinary `mom-source-action` specs using [`source_ir.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/source_ir.lua>).

```lua
local M = {
  id = 'my_format',
  abiVersion = 1,
  behaviorVersion = 0,
  allowEmptySources = true, -- Optional; allow returning {} without error
  configDirs = {'scripts/my_format/data'},
}
```

Declare **exactly one** ownership hook:
- `matchesPath(path)` — claim files by VFS path (may also supply `load(path)` to replace YAML decoding, and optional `sourcePolicy(path)` returning `{onLoadError = 'skip'}` for formats that skip malformed files).
- `claims({path = path, config = decodedConfig})` — claim already-decoded YAML by structure.

Implement `translateSource(source)`:
- Return `actions, true` (or `actions, true, nil, warningStrings`) on success.
- Return `nil, false` to decline the file.
- Return `nil, true, {kind = '...', message = '...'}` to reject malformed input.

**Boundary rules:** Translators must stay pure and engine-free — do not resolve OpenMW records/cells, sample winners, emit `familyInput`, or pick LOAD vs. GLOBAL. Express plugin gates, seeded sampling, priorities, and composition order as ordinary declarative fields on `mom-source-action` so shared normalization and promotion handle everything uniformly.

Reference implementations: [`sss/translator.lua`](<../../mom/00 OpenMW/scripts/mom/compat/sss/translator.lua>) (minimal), [`dor/translator.lua`](<../../mom/00 OpenMW/scripts/mom/compat/dor/translator.lua>) (custom loader), [`vfr/translator.lua`](<../../mom/00 OpenMW/scripts/mom/compat/vfr/translator.lua>) (multi-category).
