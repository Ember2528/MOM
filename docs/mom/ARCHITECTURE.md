# MOM Architecture

MOM compiles all discovered YAML and compatibility sources independently in OpenMW's **LOAD** and **GLOBAL** phases, partitions work across base-record edits and live-world actions automatically, and reconciles the world synchronously per tick against a single `schemaVersion = 1` in-memory ledger.

---

## Compilation Pipeline (LOAD & GLOBAL)

[`mom.omwscripts`](<../../mom/00 OpenMW/mom.omwscripts>) wires four OpenMW script entries: LOAD ([`load.lua`](<../../mom/00 OpenMW/scripts/mom/load.lua>)), GLOBAL ([`mom.lua`](<../../mom/00 OpenMW/scripts/mom/mom.lua>)), a player watcher, and actor-local helpers.

```text
Native YAML / SSS / DOR / VFR sources
        │
        ▼
Discovery & Compat Translation (bootstrap_config.lua, compat/*/translator.lua)
        │
        ▼
Shared Normalization & Admission (action_frontend.lua, action_normalization.lua)
        │  - canonical selectors, predicates, choices, plugin gates, seeded sampling
        ▼
Action-Owned Phase Partitioning (phase_partition.lua, actions/*/load.lua)
        │  - uniform model proofs, interference checks, 12-type SPLIT promotion
        ├──────────────────────────────────────┐
        ▼                                      ▼
LOAD Content Backend                   GLOBAL Runtime Compiler
(compiler/content/{compile,executor})  (compiler/compile_sources.lua)
        │                                      │
        ▼                                      ▼
Compact MOMLOAD2 GMST Receipt ────────► Startup Verification & Manifest Activation
(compiler/load_status.lua)             (app.lua, runtime/coordinator.lua)
```

### Key Compile Invariants

- **Single shared frontend:** [`startup_compile.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/startup_compile.lua>) runs discovery, compat translation, normalization, and partitioning identically in LOAD and GLOBAL without reading live world state.
- **Declarative translators only:** Compatibility translators ([`compat/sss`](<../../mom/00 OpenMW/scripts/mom/compat/sss/translator.lua>), [`compat/dor`](<../../mom/00 OpenMW/scripts/mom/compat/dor/translator.lua>), [`compat/vfr`](<../../mom/00 OpenMW/scripts/mom/compat/vfr/translator.lua>)) emit ordinary `mom-source-action` specs validated by [`source_action_contract.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/source_action_contract.lua>). They cannot query engine catalogs or bypass shared normalization.
- **Automatic 12-type `SPLIT` promotion:** [`phase_partition.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/phase_partition.lua>) delegates execution placement to each action family. Unrestricted uniform model swaps automatically promote across all 12 LOAD-writable model types (`Static`, `Activator`, `Door`, `Light`, `Book`, `Miscellaneous`, `Ingredient`, `Potion`, `Apparatus`, `Lockpick`, `Probe`, `Repair`) while keeping runtime-only types (`Container`, `Creature`) in GLOBAL.
- **LOAD-to-GLOBAL handoff:** [`load.lua`](<../../mom/00 OpenMW/scripts/mom/load.lua>) writes a compact `MOMLOAD2` GMST summary via [`load_status.lua`](<../../mom/00 OpenMW/scripts/mom/compiler/load_status.lua>) carrying the LOAD input fingerprint, decisions, and content status. GLOBAL verifies that fingerprint before activating so stale LOAD edits are caught cleanly.
- **Error isolation:** Native configs are always compiled atomically (any error rejects the whole candidate). An opt-in `compatErrorPolicy = 'skip'` mode quarantines failing compat sources with `compat_source_skipped` warnings across both LOAD and GLOBAL while keeping native sources strictly atomic.
- **Semantic identity:** Action IDs are hashed from normalized compiled meaning (`contracts/plan_identity.lua`), so moving files or reordering independent rules preserves saved progress.

---

## Runtime Architecture

[`script_factory.lua`](<../../mom/00 OpenMW/scripts/mom/script_factory.lua>) wires [`entrypoint.lua`](<../../mom/00 OpenMW/scripts/mom/entrypoint.lua>) (`I.MOM` + OpenMW callbacks) to [`app.lua`](<../../mom/00 OpenMW/scripts/mom/app.lua>). When GLOBAL has zero actions and the ledger has no saved ops or refs, `app.lua` activates a zero-overhead **dormant fast path** without opening an engine session.

```text
App (app.lua) — decode Ledger v1 (reset legacy v0) & bind extensions
  │
  ▼
Coordinator (runtime/coordinator.lua)
  ├── LocalBroker (runtime/local_broker.lua)      — actor-local leases & completions
  ├── OpenMW Session (openmw/session.lua)         — world, ref, inventory, placement, guard adapters
  ├── Guards (runtime/guards.lua)                 — tri-state coalesced evaluation & retry deadlines
  ├── Reconciler (runtime/reconciler.lua)         — static cell scans, state reconciliation & children
  ├── Arbiter (runtime/arbiter.lua)               — deterministic claim & conflict resolution
  └── Executor (runtime/executor.lua)             — synchronous apply/revert/transition & pending advance
  │
  ▼
Ledger v1 (ledger/ledger.lua, compactor.lua, identity.lua)
```

### One Frame Tick (`coordinator.tick`)

1. **Local completions & leases:** Drain actor-local replies and time out expired leases via `local_broker.lua`.
2. **Observed cells:** Sync active cells, player cells, and active actor cells via `openmw/session.lua`; enqueue newly observed cells for static scans and wake deferred reverts targeting newly loaded cells.
3. **Guard events & truth:** Poll quest, time, weather (filtered to subscribed regions), and external provider events; mark affected owners dirty and evaluate due owners in `runtime/guards.lua`.
4. **Pending ops & reconciliation:** Advance pending multi-frame operations (with exponential backoff `1..120` frames for unloaded-target reverts), scan queued static cells within bounded budgets, and reconcile dirty guarded owners/cells in `runtime/reconciler.lua`.

If no local replies, cell entries, guard wakeups, retries, or queued work exist, the tick exits immediately on an O(1) idle fast path.

### Static Work, Guarded Work, & Claim Arbitration

- **Static scans:** Each observed cell is scanned once per `staticScan.planHash` (incorporating action IDs, query revisions, and static child IDs) and recorded in `ledger.doc.staticScans`. Revisiting a settled cell does zero ref discovery. Keyed absolute placements (`transitionKey`) support in-place updates, child revert on removal (e.g. `scale -> 1.0`), and cross-cell moves with deferred source cleanup.
- **Guarded state:** Tri-state owners (`active` applies, `inactive` reverts deepest-child first, `unknown` holds existing ops) reconcile incrementally by dirty owner and dirty cell. Exact interior cell-scoped actions resolve unloaded cells only when `previsit: true` or when a descendant relocates into an observed cell.
- **Arbitration ([`runtime/arbiter.lua`](<../../mom/00 OpenMW/scripts/mom/runtime/arbiter.lua>)):** Resolves competing claims deterministically by `priority > specificity > actionId > id`, enforces conflict groups and deterministic chance, and orders applies shallowest-first and reverts deepest-first.

---

## Ledger v1 & Persistence

OpenMW only calls `onSave()` between Lua frames, never mid-tick. [`ledger/ledger.lua`](<../../mom/00 OpenMW/scripts/mom/ledger/ledger.lua>) stores one plain-data `schemaVersion = 1` document alongside synchronous O(1) derived indexes:

- **`ops`:** live operations indexed by `semanticId`, `targetId`, `ownerId`, `actionId`, `parentOpId`, `transitionKey`, `pending`, and occupied `(targetId, claim)`.
- **`refs`:** tracked content refs (with captured starting transforms/origins) and generated outputs indexed by `objectId` and `producerOpId`.
- **`staticScans`:** per-cell completed plan hashes.
- **`variants`:** cached deterministic choice draws.

[`ledger/compactor.lua`](<../../mom/00 OpenMW/scripts/mom/ledger/compactor.lua>) runs mark-and-sweep cleanup on `save()` (skipped when the ledger is clean), dropping stale static scans and unreferenced dead refs while preserving recorded origins and active outputs.

---

## Action Families & Layer Boundaries

Built-in action families live under `scripts/mom/actions/` and lazily load their runtime modules via [`common/lazy_action_hooks.lua`](<../../mom/00 OpenMW/scripts/mom/common/lazy_action_hooks.lua>) only when active or saved work needs them:

| Family | Execution | Responsibility |
| --- | :---: | --- |
| [`place_ref`](<../../mom/00 OpenMW/scripts/mom/actions/place_ref.lua>) | `split` | Absolute placement, relative attachment/replacement, spatial choices, generated records, synchronous 1-tick container transfer, and 12-type LOAD model promotion |
| [`modify_ref`](<../../mom/00 OpenMW/scripts/mom/actions/modify_ref.lua>) | `global` | `enabled`, `owner`, `scale`, `position`, `rotation`, `relocate`, starting transforms, Door origin capture, and static transitions |
| [`modify_inventory`](<../../mom/00 OpenMW/scripts/mom/actions/modify_inventory.lua>) | `global` | Item `add`, `ensure`, `remove`, `replace`, `equip`, `unequip`, mid-apply rollback, and best-effort reversal |
| [`kill_actor`](<../../mom/00 OpenMW/scripts/mom/actions/kill_actor.lua>) | `global` | Irreversible actor-local kill commands via `local_broker.lua` |
| [`record_content`](<../../mom/00 OpenMW/scripts/mom/actions/record_content.lua>) | `load` | Startup base-record field edits and named record creation |
| [`leveled_content`](<../../mom/00 OpenMW/scripts/mom/actions/leveled_content.lua>) | `load` | Startup `CreatureLevelledList` / `ItemLevelledList` edits |

**Strict dependency boundaries** (enforced by [`architecture_fitness_cases.lua`](<../../mom/99 mom_test_orchestrator/pure/architecture_fitness_cases.lua>)):
- `common/`, `contracts/`, `domain/`, `ledger/`, `runtime/`, `actions/`, and `guards/` never import `openmw.*`.
- `runtime/` and `openmw/` never import `actions/*`, `guards/*`, or `compat/*` — all family-specific behavior enters through explicit extension hooks (`transitionKey`, `acceptsGeneratedRoot`, `prepareTargetFilters`, etc.).
- Every file under `scripts/mom/` is statically reachable and acyclic.
