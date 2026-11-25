# Developer Guide

Core mod code lives in `mom/00 OpenMW/`; the test harness, fixtures, and benchmark controller live in `mom/99 mom_test_orchestrator/`. Run all commands below from the repository root.

- [Architecture](ARCHITECTURE.md) — module boundaries, compile pipeline, runtime tick loop, and ledger v1 design
- [Extensions](EXTENSIONS.md) — implementing custom Action, Guard, and Compatibility Lua modules
- [Release Procedure](RELEASE.md) — full pre-release checklist and archive packaging
- [Test Harness Guide](<../../mom/99 mom_test_orchestrator/README.md>) — engine builds, workdirs, and test structure
- [User & Author Docs](../../mom/README.md) — public docs bundled into releases

---

## Fast Local Checks (No OpenMW Required)

Requires Python 3 and LuaJIT:

```sh
# 1. Pure Lua contract & architecture fitness tests (add --stress or --stress-only)
"mom/99 mom_test_orchestrator/run_pure_tests.sh"

# 2. Python host/harness unit tests
python3 -m unittest discover -s "mom/99 mom_test_orchestrator/host/tests"

# 3. Release ZIP audit
python3 tools/release.py
```

---

## Supported OpenMW Builds

MOM targets both **LuaJIT OpenMW** and **Luau OpenMW (`clockwork-alpha`)**. World tests require vanilla `Morrowind.esm`, `Tribunal.esm`, and `Bloodmoon.esm` readable through your OpenMW config (override with `--global-config`), plus Xvfb for headless runs.

To build a patched OpenMW executable with the harness collector patch (needed for native pure retention/benchmark lanes; stock binaries still run world scenarios):

```sh
"mom/99 mom_test_orchestrator/harness_lib/build_openmw.sh" \
  --result-file /tmp/mom-built-engine.txt
```

Set `MOM_HARNESS_OPENMW_SOURCE_URL` and `MOM_HARNESS_OPENMW_SOURCE_REF` to build another branch (e.g. a LuaJIT checkout). Cached builds live under `${XDG_CACHE_HOME:-$HOME/.cache}/mom-openmw-harness/openmw/`.

Export paths to your two engine binaries for the commands below:

```sh
LUAJIT_OPENMW=/absolute/path/to/luajit-build/openmw
LUAU_OPENMW=/absolute/path/to/luau-build/openmw
```

---

## Running OpenMW Tests

### Native Contract Suite (Inside OpenMW)

```sh
xvfb-run -a "mom/99 mom_test_orchestrator/run_pure_tests.sh" --openmw "$LUAU_OPENMW"
```

### Single World Scenario or Process-Restart Campaign

```sh
# Single world scenario (or --suite smoke / --suite stress)
"mom/99 mom_test_orchestrator/run_harness.sh" \
  --openmw "$LUAU_OPENMW" --scenario starting_transform

# Single between-tick save/load restart campaign (--list to see all)
"mom/99 mom_test_orchestrator/run_process_campaigns.sh" \
  --openmw "$LUAU_OPENMW" --campaign nested_attach_restart
```

### Compile All Shipped Examples & Doc YAML Blocks

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" examples --openmw "$LUAU_OPENMW"
```

Compiles every native YAML under `01 Mod Patches`, `02 Examples`, `04 SSS Conversions`, and every complete `version: 0` fenced YAML block in `mom/docs/*.md` in both LOAD and GLOBAL.

### Combined Quick Check & Full Dual-Runtime Gate

```sh
# Fast Luau iteration check
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" quick-check \
  --luau-openmw "$LUAU_OPENMW"

# Full dual-engine verification (standalone + LuaJIT + Luau: pure, stress, world, campaigns)
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" check \
  --luajit-openmw "$LUAJIT_OPENMW" --luau-openmw "$LUAU_OPENMW"
```

---

## Performance Benchmarks

Three benchmark modes isolate different costs:

| Mode | What it measures | Clock |
| --- | --- | --- |
| `standalone` | Pure Lua algorithms & runtime paths with fake engine services | Process CPU |
| `embedded` | Algorithmic workloads inside OpenMW's Lua VM | Monotonic wall time |
| `integration` | Loaded-world & public-interface operations | Monotonic wall time |

```sh
# List workloads and verify workloads.json matches Lua definitions
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" list
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" catalog --check

# Run a quick standalone check or standard before/after comparison
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode standalone --profile quick --lua luajit --workload idle_tick \
  --output /tmp/mom-quick.json

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode embedded --profile standard --openmw "$LUAU_OPENMW" \
  --workload idle_tick --output /tmp/mom-after.json

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" validate /tmp/mom-after.json
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" compare /tmp/mom-before.json /tmp/mom-after.json
```

See [benchmark conventions](<../../mom/99 mom_test_orchestrator/performance/README.md>) for CPU pinning (`--cpu-set`), `--memory-evidence`, `catalog --write`, and native `perf` profiling.

---

## Adding Tests

- **Deterministic logic & compiler/runtime contracts:** add cases under `mom/99 mom_test_orchestrator/pure/` and register them in [`suite_catalog.lua`](<../../mom/99 mom_test_orchestrator/pure/suite_catalog.lua>).
- **In-engine world behavior:** add a scenario under `scripts/mom_test_orchestrator/scenarios/` and register it in [`scenario_inventory.lua`](<../../mom/99 mom_test_orchestrator/scripts/mom_test_orchestrator/scenario_inventory.lua>).
- **Save/load & process-restart persistence:** add a campaign to [`process_campaigns.py`](<../../mom/99 mom_test_orchestrator/host/process_campaigns.py>).
- **Architecture boundaries:** [`architecture_fitness_cases.lua`](<../../mom/99 mom_test_orchestrator/pure/architecture_fitness_cases.lua>) automatically enforces module acyclicity, static reachability, and layer isolation (e.g., `runtime/` must never import `actions/`, `guards/`, `compat/`, or `openmw.*`).
