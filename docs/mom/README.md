# Developing MOM

The production mod is in `mom/00 OpenMW/`. The separate test mod and its Python
controller are in `mom/99 mom_test_orchestrator/`. Run the commands below from
the repository root.

Use [Architecture](ARCHITECTURE.md) to find the code that owns a behavior,
[Extensions](EXTENSIONS.md) to implement a family, and [Release](RELEASE.md) when
preparing an archive. User-facing behavior and YAML syntax belong
in the [public documentation](../../mom/README.md).

The [compiler architecture](ARCHITECTURE.md#from-openmw-callbacks-to-an-active-plan)
describes automatic LOAD/GLOBAL placement.

## Local checks

Python 3 and LuaJIT cover the fast checks without launching OpenMW:

```sh
python3 -m unittest discover -s "mom/99 mom_test_orchestrator/host/tests"
"mom/99 mom_test_orchestrator/run_pure_tests.sh"
python3 tools/release.py
```

The Python tests protect launching, process ownership, results, artifacts,
statistics, and packaging. Pure Lua tests exercise compilation, scheduling,
recovery, persistence, and action behavior with small fake engine fixtures.
Pass `--stress` for normal tests plus larger fixtures, or `--stress-only` for
just the scale-sensitive cases. Use `--lua /path/to/luajit` to choose LuaJIT.

## Engines and game data

MOM supports LuaJIT OpenMW and the Luau port on OursCodeur's
`clockwork-alpha` branch. Keep a known executable for each engine. The native
contract lane requires the matching harness collector patch; an ordinary
system OpenMW binary can still run world scenarios. A stock Luau CLI does not
exercise the OpenMW bindings.

World tests need vanilla `Morrowind.esm`, `Tribunal.esm`, and `Bloodmoon.esm` in
one data directory readable through your OpenMW config. Use `--global-config`
for another config. Engine builds need CMake, a supported build tool, and OpenMW
development dependencies. Host automation uses Linux/POSIX process groups and
`flock` for cache ownership. Headless engine runs need Xvfb; the combined check starts it when
`DISPLAY` is unset. Scenario catalog loading also needs a Lua executable.

Build an owned engine explicitly when needed:

```sh
"mom/99 mom_test_orchestrator/harness_lib/build_openmw.sh" \
  --result-file /tmp/mom-built-engine.txt
```

The builder defaults to `https://gitlab.com/OursCodeur/openmw.git`, branch
`clockwork-alpha`. `MOM_HARNESS_OPENMW_SOURCE_URL` and
`MOM_HARNESS_OPENMW_SOURCE_REF` select another source, such as a LuaJIT checkout.
Caches live below
`${XDG_CACHE_HOME:-$HOME/.cache}/mom-openmw-harness/openmw/`. Owned builds retain
matching engine resources, patch and build identity. See the
[harness guide](<../../mom/99 mom_test_orchestrator/README.md>) for build options.

Set paths to your two patched engines before using the remaining examples:

```sh
LUAJIT_OPENMW=/absolute/path/to/luajit-build/openmw
LUAU_OPENMW=/absolute/path/to/luau-build/openmw
```

## Native contracts, world scenarios, and restarts

Run the same contract tests through the Luau engine's compiler and bindings:

```sh
xvfb-run -a "mom/99 mom_test_orchestrator/run_pure_tests.sh" \
  --openmw "$LUAU_OPENMW"
```

This lane snapshots original module bytes and uses `openmw.util.loadCode` with
test-only source loading. Its collector patch permits real full collections
for retention tests. Ordinary world and restart scenarios use the normal
sandbox.

Run a focused world scenario or a restart campaign:

```sh
"mom/99 mom_test_orchestrator/run_harness.sh" \
  --openmw "$LUAU_OPENMW" --scenario starting_transform

"mom/99 mom_test_orchestrator/run_process_campaigns.sh" \
  --openmw "$LUAU_OPENMW" --campaign nested_attach_restart
```

Use `--suite smoke` for a small world suite. A campaign launches separate engine
processes and passes a real save between them. Its receipts retain save hashes,
logs, commands, and phase results. Both kinds of run stage just their selected
fixtures in an isolated data directory.

Check the shipped native configurations and complete public examples through
the real startup compiler:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" examples \
  --openmw "$LUAU_OPENMW"
```

This compile-only check enables no MOM runtime and changes no game objects.
It uses vanilla masters; variants requiring other plugins may be inactive.
It reports the accepted action counts and original source locations. Run it
with both engines when changing the public reference or shipped examples.

For a shorter development check:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" quick-check \
  --luau-openmw "$LUAU_OPENMW"
```

For complete correctness coverage on both supported engines:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" check \
  --luajit-openmw "$LUAJIT_OPENMW" --luau-openmw "$LUAU_OPENMW"
```

The complete check runs standalone LuaJIT contracts, native normal and stress
contracts, every world scenario, and every restart campaign. It checks runtime
markers and cross-runtime case counts. Inspect the combined `result.json` and
its individual receipts; a launch by itself does not establish success.

Each run retains its work directory. Use a new destination for `--workdir`
when selecting one explicitly. Treat saves, logs, generated configs, and JSON
receipts as evidence until you choose to remove them.

## Performance

Choose the lane that measures the behavior being changed:

| Mode | Measures | Clock |
| --- | --- | --- |
| `standalone` | Algorithms and runtime paths with fake engine services | Process CPU |
| `embedded` | Algorithmic workloads inside OpenMW | Monotonic wall time |
| `integration` | Loaded-world and public-interface workloads | Monotonic wall time |

List workloads and verify the generated host catalog:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" list
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" catalog --check
```

Start with a quick run, then use `standard` for a before/after comparison:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode standalone --profile quick --lua luajit --workload idle_tick \
  --output /tmp/mom-quick.json

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode embedded --profile standard --openmw "$LUAU_OPENMW" \
  --workload idle_tick --output /tmp/mom-after.json

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" validate \
  /tmp/mom-after.json
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" compare \
  /tmp/mom-before.json /tmp/mom-after.json
```

Use the same engine, host, CPU affinity, profile, selected workloads, and memory
settings on both sides. `--cpu-set` pins processes to a CPU set available on
your machine. Timing-only and `--memory-evidence` experiments have different
contracts; capture memory in separate matching diagnostic runs. `compare`
reports incompatible identities instead of comparing unlike experiments, and
an inconclusive result does not establish performance preservation.

The executable Lua workload definitions own the work and timing boundaries.
[`workloads.json`](<../../mom/99 mom_test_orchestrator/performance/workloads.json>)
is their generated host projection; regenerate it with `catalog` after an
intentional workload change (`catalog --write`). Profiles and budgets live
alongside it. A workload
change that alters measured work needs a new workload version and baseline.
The host resamples process clusters as well as samples, so retain full runs
rather than just reported medians.

Artifacts default to
`${MOM_HARNESS_ARTIFACT_ROOT:-${TMPDIR:-/tmp}/mom-performance-artifacts}`.
Content-addressed run directories retain specifications, samples, identities,
logs, and manifests. `validate` accepts a summary file or a complete run
directory. Native profiling adds `--native-campaign record`, `stat-core`,
`stat-cache`, or `wall-control` to an embedded/integration `profile` run; it
requires the platform's `perf` facilities and helps explain a measured cost.

## Making a change

Protect the observable behavior or failure boundary being changed. Use pure
tests for deterministic rules, engine scenarios for physical world behavior,
and campaigns for process-loss recovery. Add scenarios to
[`scenario_inventory.lua`](<../../mom/99 mom_test_orchestrator/scripts/mom_test_orchestrator/scenario_inventory.lua>);
add restart sequences to
[`process_campaigns.py`](<../../mom/99 mom_test_orchestrator/host/process_campaigns.py>).
These catalogs supply selections and coverage inventories.
