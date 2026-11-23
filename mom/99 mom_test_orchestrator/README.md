# MOM test harness

This is a developer-only OpenMW mod and Python controller. It exercises the
production MOM entrypoint with isolated game data and test fixtures. Do not
enable this directory in an ordinary installation.

For commands and choosing a test lane, use the
[developer guide](../../docs/mom/README.md). For the final release checks, use
the [release procedure](../../docs/mom/RELEASE.md).

## Entry points

Run these from the repository root. Every Python entry point also accepts
`--help`.

| Entry point | Purpose |
| --- | --- |
| `run_pure_tests.sh` | LuaJIT contracts; `--openmw PATH` runs them through OpenMW. |
| `run_harness.sh` | Selected world scenarios in an isolated OpenMW profile. |
| `run_process_campaigns.sh` | Save/load campaigns across fresh processes; `--list` lists them. |
| `host/mom_harness.py quick-check` | Native Luau contracts, smoke scenarios, and a selected restart campaign. |
| `host/mom_harness.py check` | Both engine lanes, normal/stress contracts, world scenarios, and all campaigns. |
| `host/mom_harness.py examples` | Compile complete public examples with the selected engine. |
| `host/mom_harness.py list` | List benchmark workloads and profiles. |
| `host/mom_harness.py run` | Collect a benchmark experiment. |
| `host/mom_harness.py validate` | Validate a result or retained artifact directory. |
| `host/mom_harness.py compare` | Compare compatible benchmark summaries. |
| `harness_lib/build_openmw.sh` | Provision a patched engine explicitly. |

## Selecting an engine

Use `--openmw /absolute/path/to/openmw` or `OPENMW_BIN`. Otherwise the world
launcher resolves `openmw` on `PATH`. Engine provisioning is explicit: use the
builder or `--build-openmw`. `MOM_HARNESS_BUILD_OPENMW=1` also opts into building;
`--no-build-openmw` overrides it. Performance runs normally use a previously
built executable. Benchmark `run` also accepts `--build-openmw` and
`--no-build-openmw`; source/build directory options require build selection.

The native pure suite needs the appropriate collector patch in
`openmw_patches/`; it enables the patched authority for real collection tests.
World and restart runs keep ordinary sandbox settings. Performance runs enable
the harness authority for collection and atomic artifact writing. Patches and
test controllers are excluded from the public mod archive.

The builder defaults to the Luau `clockwork-alpha` source. Its configuration is:

| Environment variable | Selects |
| --- | --- |
| `MOM_HARNESS_OPENMW_SOURCE_URL` | Source repository URL. |
| `MOM_HARNESS_OPENMW_SOURCE_REF` | Branch, tag, or commit to resolve. Pin a commit for reproducible evidence. |
| `MOM_HARNESS_OPENMW_SOURCE_DIR` | Existing source checkout to read at its current HEAD. |
| `MOM_HARNESS_OPENMW_BUILD_ROOT` | External engine cache directory. |
| `MOM_HARNESS_OPENMW_PATCH_DIR` | Explicit patch directory; an empty directory selects no patches. |
| `MOM_HARNESS_OPENMW_BUILD_TYPE` | CMake build type, default `RelWithDebInfo`. |
| `MOM_HARNESS_OPENMW_BUILD_JOBS` | Build parallelism. |

Managed source resolution and builds hold a cache lock. Each keyed build has
matching resources and `mom-build-identity.json`, recording source, patches and
build inputs. An explicit source checkout is read without changing its HEAD or
working files. A launch with a supplied executable records known provenance
from its sidecar; an executable without one has unknown build provenance and
still retains its binary hash in validation/benchmark evidence.

## Configurations and retained runs

The launcher reads a global OpenMW config to find the directory containing
`Morrowind.esm`, `Tribunal.esm`, and `Bloodmoon.esm`. Use `--global-config` or
`OPENMW_GLOBAL_CONFIG` to select it. `XDG_CONFIG_HOME` is respected. Resources
and fallback values come from the executable's matching base config when
available; `--openmw-base-config` or `MOM_HARNESS_OPENMW_BASE_CONFIG` overrides
that choice.

Runs create unique directories under `${TMPDIR:-/tmp}` and print their paths.
An explicit `--workdir` must be a new absolute path outside the repository.
`MOM_HARNESS_WORKDIR` selects the world launcher's path and
`MOM_CAMPAIGN_WORKDIR` selects the campaign controller's path. Reusing one fails
instead of deleting prior evidence. Remove retained runs yourself when their
logs, saves and results are no longer useful.

`run_harness.sh --dry-run` prints a plan without writing a configuration,
deleting files, fetching sources or building an engine. With explicit build
selection it describes the required provisioning; inspect the exact launch
command after selecting a built executable. Arguments after `--` pass through
to OpenMW.

Correctness receipts include the selected scenario IDs, observed results,
engine exit status, log path and work directory. Combined checks checkpoint
`result.json` before and after each step. Cancellation stops and reaps owned
process groups, retains completed evidence, and saves a cancelled result.
SIGINT exits with 130 and SIGTERM with 143.

## Where to change tests

- `pure/` contains fake-engine contracts and their suite catalog. Stress cases
  are explicitly tagged; normal cases use smaller behavior fixtures.
- `scripts/mom_test_orchestrator/scenario_inventory.lua` defines scenario
  groups, suites and fixture requirements. Add a scenario implementation under
  `scenarios/` and declare its fixture files in that inventory.
- `fixtures/data/` holds authored test data. The host stages only the selected
  union; mounting the harness code alone does not activate these patches.
- `host/process_campaigns.py` defines ordered save/load phases and overlays.
  Each successful save becomes the real input to the following engine process.
- `host/tests/` covers launch/configuration behavior, process ownership,
  receipts, artifacts, statistics, catalogs and packaging.
- `performance/` contains generated workload metadata, profiles, budgets and
  standalone launchers. See [benchmark conventions](performance/README.md).

World assertions should observe the intended object or actor effect. A changed
journal count, disappearance, or an old corpse alone does not demonstrate a
successful kill. Restart tests should pass a real save across processes.
Keep expected failure cases distinct from missing or malformed receipts.
