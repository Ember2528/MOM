# How MOM runs

MOM invokes its compiler independently in LOAD and GLOBAL, then reconciles the
world with the resulting runtime plan synchronously per tick. Permanent patches
run once per observed cell (or at LOAD time for eligible record/model edits);
guarded actions are owned by tri-state guards that activate, retain, or revert
cleanly. A single `schemaVersion = 1` in-memory ledger tracks live operations,
generated outputs, and completed static scans across OpenMW saves and restarts.

## From OpenMW callbacks to an active plan

[`mom.omwscripts`](<../../mom/00 OpenMW/mom.omwscripts>) registers a LOAD script,
a GLOBAL script, a player watcher, and actor-local helpers. The GLOBAL script
uses [`script_factory.lua`](<../../mom/00 OpenMW/scripts/mom/script_factory.lua>)
to create one App and its OpenMW session factory.
[`entrypoint.lua`](<../../mom/00 OpenMW/scripts/mom/entrypoint.lua>) adapts OpenMW
callbacks and exposes `I.MOM`. [`app.lua`](<../../mom/00 OpenMW/scripts/mom/app.lua>)
owns loading, startup, saving, observations, and runtime lifetime.

```text
Native / SSS / VFR / DOR sources
        |
Shared discovery, decoding and declarative action translation
        |
Common normalization: selectors, predicates, choices, admission, identity
        |
Action-owned execution planning: uniform-result proof, 12-type SPLIT & interference
        |
        +------------------------------+
        |                              |
LOAD definition lowering         GLOBAL reference lowering
        |                              |
Content executor                 App activation / Ledger v1
        |
Compact MOMLOAD2 GMST receipt --> GLOBAL startup check
```

The compiler runs these shared stages independently in each context. Adapters
map foreign formats into ordinary declarations; they cannot supply prepared
family inputs, sampled winners, resolved records or content-planner nodes.
Compatibility translators use ABI 1; action/guard families retain ABI 0.
The [extension contract](EXTENSIONS.md#compatibility-translators) defines source
admission and diagnosed optional-source policies. Foreign ordering/seeds that
affect behavior become semantic action data; source coordinates remain diagnostic.

The GLOBAL execution path runs through the unified runtime:

```text
       Manifest + compile diagnostics
                 |
       App decodes Ledger v1 (or cleanly resets pre-release v0) and activates bindings
                 |
       Coordinator (runtime/coordinator.lua)
         |-- LocalBroker (actor-local completion & leases)
         |-- OpenMW Session (world, ref/inv/placement ops, guard reads)
         |-- Guards (tri-state coalesced evaluation & retry deadlines)
         |-- Reconciler (static cell scans + guarded state reconciliation)
         |-- Arbiter (greedy deterministic claim resolution)
         |-- Executor (1-commit synchronous apply/revert + pending resumption)
         v
       Ledger v1 (single document + O(1) indexes + save-time compactor)
```

[`startup_compile.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/startup_compile.lua>)
reads the same supported sources in both contexts. Native variants and every
compatibility adapter converge on ordinary source actions.
[`action_frontend.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/action_frontend.lua>)
calls the engine-free shared normalizer before deriving implicit sampling keys,
then folds installed-content requirements and deterministic declaration admission
and resolves absolute placement alternatives. Equivalent compact filters, cell
queries and record selectors have one canonical meaning before placement.

The batch [`phase_partition.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/phase_partition.lua>)
planner delegates action-family placement metadata and proves uniform model
intent while analyzing replacement interference across sources. For untyped or
mixed model replacements without runtime blockers, `SPLIT` routes all 12
LOAD-writable model types (`Static`, `Activator`, `Door`, `Light`, `Book`,
`Miscellaneous`, `Ingredient`, `Potion`, `Apparatus`, `Lockpick`, `Probe`,
`Repair`) to LOAD while retaining complementary runtime-only types (`Container`,
`Creature`) in GLOBAL. Constant choices can become ordinary model writes.
Guards, reference restrictions, nonzero offsets, supplied rotations and
dependent children keep their runtime meaning. Their semantic dependencies join
the LOAD fingerprint, so changing a relevant runtime blocker requires restarting
OpenMW. Unrelated runtime edits remain reloadable.

After placement, the content backend resolves definitions/assets through its
read-only host view. Runtime family preparation resolves only selected GLOBAL
actions, loads guard implementations and lazily builds record/cell indexes.
Backend failure is diagnosed in the chosen plan, without runtime fallback.
LOAD sees pre-edit content at MOM's position; GLOBAL sees the final catalog.
Later LOAD overrides retain their authority.

[`source_ir.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/source_ir.lua>)
separates ordinary declarations from compiler-owned prepared family input.
Generic MOM replacement choices retain profiles, KEEP stop/fallthrough,
record-before-mesh routing, precedence and stable sampling. The VFR adapter maps
its fields into those capabilities; the same capabilities are available to
native declarations. SSS and DOR pass through the same normalization/planning.
VFR list injections become ordinary `leveled` operations.

An accepted result contains a plain-data manifest: actions, owners, routes,
claims, dependency edges, family versions, and a content hash. Semantic action
identity follows compiled meaning, so moving an equivalent source or reordering
independent entries does not replay an operation. Source paths remain available
for diagnostics. Invalid sources reject the candidate as a whole. An unused
broken extension can be quarantined during discovery; referencing an unavailable
family rejects the affected compilation.

Activation binds action modules and guard evaluators via
[`runtime/coordinator.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/coordinator.lua>)
and opens the OpenMW session. Built-in family descriptors lazily load their
runtime hooks via [`common/lazy_action_hooks.lua`](<../../mom/00 OpenMW/scripts/mom/common/lazy_action_hooks.lua>)
only when current or saved work needs them. Fully restart OpenMW after changing
LOAD-owned input so the next startup uses the new definitions.

The separate [`load.lua`](<../../mom/00 OpenMW/scripts/mom/load.lua>) calls the
same compiler facade and then the sole
[content executor](<../../mom/00 OpenMW/scripts/mom/compiler/content/executor.lua>).
Native and imported list edits join this same plan after ordinary action lowering.
One compact [`load_status.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/load_status.lua>)
`MOMLOAD2` GMST receipt carries status, LOAD-input and content hashes, write counts,
and any failure message. GLOBAL verifies it before activation. `compileReport().startup`
and `selfcheck().startup` expose bounded LOAD results.

## One update

[`runtime/coordinator.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/coordinator.lua>)
executes a deterministic frame tick in order:

1. Poll actor-local lease timeouts and deliver completed local notifications via
   [`runtime/local_broker.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/local_broker.lua>).
2. Synchronize observed cells (active cells, players, active actors) through
   [`openmw/session.lua`](<../../mom/00 OpenMW/scripts/mom/openmw/session.lua>)
   and enqueue newly entered cells.
3. Poll guard event sources (quest, time, weather, external providers) and mark
   subscribed owners dirty in [`runtime/guards.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/guards.lua>).
4. Evaluate dirty guard owners and due unknown-truth retries.
5. Advance pending operations, reconcile static scans for queued cells, and
   reconcile guarded state (cleanup of inactive/stale operations followed by
   claim-arbitrated application of active owners) via
   [`runtime/reconciler.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/reconciler.lua>).

When no local completions, new cells, guard events, retries, or pending work
exist, the tick returns immediately on an O(1) idle fast path.

## Static work, guarded work, and arbitration

[`runtime/reconciler.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/reconciler.lua>)
handles both static and guarded reconciliation over the same ledger and executor:

- **Static cell scans** inspect each newly observed cell once per manifest hash,
  arbitrate candidates against live claims, apply winning operations, and mark
  the cell complete in `ledger.doc.staticScans`. Revisiting a completed cell
  under the same manifest performs zero ref discovery.
- **Guarded state** coalesces owner wakeups in `runtime/guards.lua`: `active`
  reconciles desired targets, `inactive` reverts reversible operations deepest-child
  first, and `unknown` retains existing operations without applying new ones.
  Exact interior `scope == 'cell'` actions resolve their target cell directly so
  cross-cell placements and relocations converge even when the player is elsewhere.
- **Claim arbitration** ([`runtime/arbiter.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/arbiter.lua>))
  resolves competing claims synchronously in total rank order (`priority > specificity > actionId > id`),
  enforces conflict groups and deterministic chance sampling, and orders apply
  shallowest-first and revert deepest-first.

## Persistence and in-memory indexes

OpenMW invokes `onSave()` only between Lua ticks — never mid-tick. MOM models
this directly with a single in-memory `schemaVersion = 1` ledger with
synchronous O(1) derived indexes in
[`ledger/ledger.lua`](<../../mom/00 OpenMW/scripts/mom/ledger/ledger.lua>):

- `ops`: live operations indexed by `semanticId`, `targetId`, `ownerId`,
  `actionId`, `parentOpId`, `pending`, and occupied `(targetId, claim)`.
- `refs`: tracked content refs (with captured original cell/transform) and
  generated outputs indexed by `objectId` and `producerOpId`.
- `staticScans`: per-cell completed manifest hashes.
- `variants`: deterministic sampled variant cache.

[`ledger/compactor.lua`](<../../mom/00 OpenMW/scripts/mom/ledger/compactor.lua>)
runs on `save()` to drop stale static scans, unreferenced dead refs (preserving
any ref with recorded origin metadata or live operation references), and bounded
dead variant entries. Pre-release `schemaVersion = 0` payloads cleanly reset to
a fresh `schemaVersion = 1` ledger on load.

## Engine boundary and action families

[`openmw/session.lua`](<../../mom/00 OpenMW/scripts/mom/openmw/session.lua>)
binds focused capability adapters (`world.lua`, `ref_ops.lua`, `inventory_ops.lua`,
`placement_ops.lua`, `guard_reads.lua`).
[`ledger/identity.lua`](<../../mom/00 OpenMW/scripts/mom/ledger/identity.lua>)
decouples logical targets and generated outputs from transient engine handles.

Action families live as drop-in modules under `scripts/mom/actions/`:

| Family | Responsibility |
| --- | --- |
| [`modify_ref`](<../../mom/00 OpenMW/scripts/mom/actions/modify_ref.lua>) | Properties, starting transforms, reversal, reassertion, and static transitions |
| [`place_ref`](<../../mom/00 OpenMW/scripts/mom/actions/place_ref.lua>) | Absolute placement, attachment/replacement, generated records, outputs, and container transfer |
| [`modify_inventory`](<../../mom/00 OpenMW/scripts/mom/actions/modify_inventory.lua>) | Item additions/removals, equipment, and best-effort reversal |
| [`kill_actor`](<../../mom/00 OpenMW/scripts/mom/actions/kill_actor.lua>) | Irreversible actor-local death commands and completion |
| [`record_content`](<../../mom/00 OpenMW/scripts/mom/actions/record_content.lua>) | LOAD-time record field edits |
| [`leveled_content`](<../../mom/00 OpenMW/scripts/mom/actions/leveled_content.lua>) | LOAD-time leveled list edits |

Container replacement in
[`actions/place_ref/container_transfer.lua`](<../../mom/00 OpenMW/scripts/mom/actions/place_ref/container_transfer.lua>)
performs inventory clearing, live item transfer, lock/trap migration, and
visibility swap synchronously in one tick (with a 1-tick wait only where OpenMW
queues `teleport`/`moveInto` effects across frames), preserving player deposits
and preventing native respawning-container duplication on revert.

Actor-local kill and equip commands use
[`runtime/local_broker.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/local_broker.lua>)
to track leases, retries, and idempotent completions across saves and restarts.

## Observing and testing behavior

`I.MOM.selfcheck(options)` returns bounded runtime, startup, and ledger status
(including optional `operation` target queries). `I.MOM.compileReport()` returns
the active compilation report and the last rejected attempt.

The test mod exercises the exact production App, coordinator, ledger, and
entrypoint. Pure contract tests replace engine services; world scenarios verify
physical in-engine behavior across 40 ordinary + 4 stress scenarios; and 18
real process-restart campaigns save real OpenMW state between ticks and relaunch
fresh engine processes on both LuaJIT OpenMW and Luau OpenMW (`clockwork-alpha`).
