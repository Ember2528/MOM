# Benchmark Conventions

Use benchmarks to measure a specific hot path with reproducible, statistically valid runs. See the [developer guide](../../../docs/mom/README.md#performance-benchmarks) for top-level commands.

---

## Lanes & Profiles

- **Lanes:** `standalone` (LuaJIT with fake engine services, process CPU clock), `embedded` (inside OpenMW VM, monotonic wall time), and `integration` (loaded world & `I.MOM`, monotonic wall time). Only compare runs from the same lane and engine.
- **Profiles** ([profiles.json](profiles.json)):
  - `quick` — fast sanity check of a workload or pipeline
  - `standard` — before/after comparisons
  - `release` — full release evidence (requires clean tree and `--cpu-set`; `--allow-dirty` records an exception)
  - `memory` — isolated per-replicate heap diagnostics (never mix with timing-only runs)
  - `profile` — extended single-workload run for native `perf` (`--native-campaign record|stat-core|stat-cache|wall-control`)

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode standalone --profile quick --lua luajit --workload idle_tick \
  --output /tmp/mom-idle.json
```

Omitting `--workload` runs all workloads for the selected lane.

---

## Writing or Updating Workloads

- Lua workload definitions under [`performance/cases/`](../scripts/mom_test_orchestrator/performance/cases/) are the source of truth; [workloads.json](workloads.json) is their generated projection. Run `mom_harness.py catalog --check` in CI and `catalog --write` after editing a workload definition.
- Each workload's `execute(measure, options)` builds its fixture outside `measure`, calls `measure` exactly once around the timed work, and returns a deterministic scalar checksum verified by [`runner.lua`](../scripts/mom_test_orchestrator/performance/runner.lua).
- Bump a workload's `version` whenever you change what it measures or its setup boundary (normal production-code edits do not require a workload version bump).

---

## Heap & Allocation Evidence

`memory` runs collect five GC boundaries per case: `gcCaseBefore`, `gcSetupBefore`, `gcBefore`, `gcAfter` (telemetry), and `gcRetained` (budget input after a full collection). Calibrated standalone workloads also run a stopped-GC allocation probe in a fresh process to measure net heap growth during the timed body.

Absolute heap calibrations in [budgets.json](budgets.json) are keyed to the exact Lua executable hash so uncalibrated binaries collect measurements without inheriting incompatible limits.

---

## Comparing Results

Keep the full artifact directory (default `${MOM_HARNESS_ARTIFACT_ROOT:-${TMPDIR:-/tmp}/mom-performance-artifacts}`), not just the summary JSON. `mom_harness.py compare` verifies matching workload contracts, build identity, CPU affinity, and run parameters before running process-cluster bootstrap comparisons, rejecting mismatched runs instead of producing misleading deltas.
