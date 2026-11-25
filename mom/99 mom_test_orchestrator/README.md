# MOM Test Harness

Developer-only OpenMW test mod and Python controller exercising the production MOM entrypoint in isolated game data directories. **Do not enable this folder in normal gameplay.**

For common developer workflows, see the [developer guide](../../docs/mom/README.md).

---

## Entry Points

Run from the repository root (`--help` prints full CLI options for each tool):

| Command | Purpose |
| --- | --- |
| `run_pure_tests.sh` | Standalone LuaJIT pure contracts (`--stress`, `--stress-only`, or `--openmw PATH` for native VM execution). |
| `run_harness.sh` | Isolated OpenMW world scenarios (`--scenario ID`, `--suite smoke\|stress`, `--dry-run`). |
| `run_process_campaigns.sh` | Multi-process save/load restart campaigns (`--campaign ID`, `--list`). |
| `host/mom_harness.py quick-check` | Fast Luau check: pure contracts, smoke world scenarios, and one restart campaign. |
| `host/mom_harness.py check` | Full dual-engine gate across standalone, LuaJIT, and Luau (pure, stress, world, campaigns). |
| `host/mom_harness.py examples` | Compile all shipped patches and complete `version: 0` YAML blocks in `mom/docs/*.md` in LOAD & GLOBAL. |
| `host/mom_harness.py list\|run\|validate\|compare\|catalog` | Benchmark runner, artifact validation, statistical comparison, and `workloads.json` sync. |
| `host/content_backend_gate.py` / `content_lifecycle.py` | Focused LOAD content-backend and production entrypoint lifecycle checks. |
| `harness_lib/build_openmw.sh` | Build and cache a patched OpenMW executable with matching resources and identity metadata. |

---

## Selecting or Building an Engine

Pass `--openmw /absolute/path/to/openmw` (or set `OPENMW_BIN`); otherwise world runs look up `openmw` on `PATH`.

- **Native pure & benchmark lanes** require the collector patch in `openmw_patches/` (enabling test-only GC/atomic-write hooks; normal world/restart scenarios keep standard sandboxing).
- **Explicit builds:** use `harness_lib/build_openmw.sh` or `--build-openmw` (override `MOM_HARNESS_BUILD_OPENMW=1` with `--no-build-openmw`).

Key build environment variables (defaults to Luau `clockwork-alpha`):

| Variable | Selects |
| --- | --- |
| `MOM_HARNESS_OPENMW_SOURCE_URL` | Git URL for OpenMW source. |
| `MOM_HARNESS_OPENMW_SOURCE_REF` | Branch, tag, or commit hash. |
| `MOM_HARNESS_OPENMW_SOURCE_DIR` | Existing local OpenMW checkout (read-only). |
| `MOM_HARNESS_OPENMW_BUILD_ROOT` | External build cache root. |
| `MOM_HARNESS_OPENMW_PATCH_DIR` | Override patch directory (empty disables patches). |
| `MOM_HARNESS_OPENMW_BUILD_TYPE` / `..._JOBS` | CMake build type (`RelWithDebInfo`) and parallelism. |

---

## Game Data & Work Directories

- Vanilla `Morrowind.esm`, `Tribunal.esm`, and `Bloodmoon.esm` are located via your OpenMW config (override with `--global-config` or `OPENMW_GLOBAL_CONFIG`).
- Each run stages only its required fixtures into a fresh temporary directory under `${TMPDIR:-/tmp}` and preserves logs, configs, saves, and JSON receipts. Passing an existing `--workdir` fails instead of overwriting prior evidence.
- Pressing Ctrl+C / SIGTERM cleanly terminates the entire owned OpenMW process group and records a cancelled receipt (`SIGINT` → 130, `SIGTERM` → 143).

---

## Layout

| Path | Responsibility |
| --- | --- |
| `pure/` | Fake-engine Lua contract, architecture-fitness, and stress suites (`suite_catalog.lua`). |
| `scripts/mom_test_orchestrator/scenarios/` | Real-world OpenMW test scenarios registered in `scenario_inventory.lua`. |
| `fixtures/data/` | Staged YAML test fixtures mounted per scenario selection. |
| `host/process_campaigns.py` | Ordered multi-process save/load campaign definitions and overlays. |
| `host/tests/` | Python `unittest` suite covering launching, process groups, receipts, stats, and packaging. |
| `performance/` | Generated `workloads.json`, `profiles.json`, `budgets.json`, and benchmark launchers (see [performance/README.md](performance/README.md)). |
