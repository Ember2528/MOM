# Benchmark conventions

Use a benchmark to answer a specific cost question. Start with the smallest
workload that exercises the changed path, then broaden coverage when the
result or change calls for it. Commands for collecting and comparing runs are
in the [developer guide](../../../docs/mom/README.md#performance).

## Pick a measurement

`standalone` runs algorithms with fake engine services and measures process CPU
time. `embedded` runs those workloads through OpenMW's compiler and runtime,
using monotonic wall time. `integration` measures selected loaded-world or
public-interface operations, also using wall time. Compare results within the
same lane and engine.

Use `quick` to check the pipeline or investigate a workload, `standard` for a
before/after experiment, and `release` for broader candidate evidence. `memory`
collects separate heap diagnostics; `profile` collects a long single-workload
run for native profiling. The actual process, warmup and sample counts live in
[profiles.json](profiles.json); CLI overrides are recorded in the run.

A small pipeline check is:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode standalone --profile quick --lua luajit --workload idle_tick \
  --output /tmp/mom-idle.json
```

Omitting `--workload` selects every workload for the lane, including expensive
scale cases. Repeat the option to select several. A release run requires a
clean tree and an explicit available CPU set; `--allow-dirty` records an
exception. Keep other work off the measured CPUs when collecting evidence.

## Workloads and timing boundaries

The Lua definitions under
[`performance/cases/`](../scripts/mom_test_orchestrator/performance/cases/)
own workload meaning. [workloads.json](workloads.json) is a generated projection
for the host. Run `mom_harness.py catalog --check` after changes; use
`catalog --write` after intentionally changing a definition.

Each case declares its identity/version, supported modes, operation count,
minimum sample duration, GC policy, semantics, and relevant source files. Its
`execute(measure, options)` function builds the fixture and calls `measure`
exactly once around the work being timed. It returns the same scalar checksum
as the measured body. Assertions must establish that the intended work
actually occurred.

Fixture setup outside `measure` is untimed. Work needed to perform the real
operation belongs inside the body; moving it outside changes the question.
Change the workload version when the measured work or setup boundary changes.
Changing production code is the subject of a comparison and does not by itself
require a new workload version.

The [runner](../scripts/mom_test_orchestrator/performance/runner.lua) checks
checksums across samples and marks samples below their timing floor invalid.
The host rejects missing, duplicate or inconsistent results. Timing replicates
batch ordinary selected cases, rotating their starting order; a case marked
`requiresFreshProcess` stays in its own process. Memory runs isolate every
workload in a separate process for every replicate.

## Heap evidence

Memory instrumentation changes the execution environment. Compare matching
memory runs and keep them separate from ordinary timing results.

The runner fully collects and records five boundaries:

- `gcCaseBefore`: before the case's warmups and fixture setup;
- `gcSetupBefore`: before each measured invocation's setup;
- `gcBefore`: immediately before the timed body;
- `gcAfter`: immediately after the body, before an extra collection;
- `gcRetained`: after a full collection following the body.

These distinguish setup cost, transient body growth and retained growth.
Summary `after` and `retained` footprints use the case-lifetime baseline and
include setup. `gcAfter` is telemetry; the fully collected case-lifetime
`retained` footprint is the retained-memory budget input. Interpret a footprint
in the context of its boundary, rather than treating it as cumulative allocated
bytes.

Selected calibrated standalone workloads also have a stopped-GC allocation
probe. It runs in a fresh process with one warmup and one sample, stops the
collector only around the measured body, and restarts it through protected
cleanup. Its `allocated` value is net heap growth with GC stopped. Synchronous
frees and table resizing still affect that value; it is not an allocator byte
counter. Unbudgeted workloads do not run this probe.

Absolute memory calibrations in [budgets.json](budgets.json) include the exact
Lua executable hash. An uncalibrated runtime retains measurements without
inheriting another executable's limits. Embedded absolute heap limits require
their own calibration.

## Comparison and evidence

Retain the complete artifact directory, including specifications, raw samples,
configuration, logs, engine identity and object manifest. The host writes a
summary for convenience; the full run allows corruption and missing evidence
to be detected later.

The comparator checks selected workload contracts, runtime/build identity,
host/CPU settings, affinity and run parameters before comparing. It uses
process-cluster bootstrap estimates so multiple samples from one process are
not treated as independent process launches. Results report a pass, failure,
regression or inconclusive evidence under the configured thresholds, or reject
an incompatible comparison. An incompatible or inconclusive result does not
prove preservation.

A quick smoke run validates the collection pipeline. A performance claim needs
controlled compatible runs with enough independent processes. Record any
measurement change with a fresh baseline; do not reuse a historical median
whose workload or instrumentation has changed.
