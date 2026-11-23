# Preparing a release

Run this procedure from the intended release commit. Retain the generated
receipts and record both supported engine identities. A previous revision's
successful run is useful history, but it does not validate the candidate.

## 1. Check sources and package selection

```sh
git status --short
git diff --check
python3 -m unittest discover -s "mom/99 mom_test_orchestrator/host/tests"
"mom/99 mom_test_orchestrator/run_pure_tests.sh"
python3 tools/release.py
```

Use a clean tree for final evidence. Check that documentation examples compile,
links resolve, and the archive contains the public docs and intended runtime
files. [`tools/release_manifest.txt`](../../tools/release_manifest.txt) selects
release inputs. The builder removes the repository's leading `mom/` prefix,
uses deterministic ZIP metadata, and audits exact membership and source bytes.

## 2. Validate both engines

Use patched LuaJIT and Luau OpenMW executables with the matching resources,
vanilla master files, and a new work directory:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" check \
  --luajit-openmw /absolute/path/to/luajit-build/openmw \
  --luau-openmw /absolute/path/to/luau-build/openmw \
  --workdir /tmp/mom-release-correctness-UNIQUE
```

Require the combined result to pass. This includes normal and stress contracts,
world scenarios, and real-save restart campaigns on both runtimes. Keep the
individual engine logs, phase receipts, save handoffs, and combined result.
Check the recorded coverage and native runtime markers; investigate missing or
cancelled work rather than counting a partial run as a pass.

Compile the public examples with each selected engine:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" examples \
  --openmw /absolute/path/to/luajit-build/openmw
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" examples \
  --openmw /absolute/path/to/luau-build/openmw
```

The check uses vanilla masters and preserves the YAML bytes. Content-gated
variants can be inactive; test optional compatibility patches separately with
their required mods. This check establishes compilation, while the world
scenarios and manual route establish physical behavior.

Every native example is compiled in both contexts through read-only adapters;
the check never executes the content plan or writes a lifecycle status. For
changes to content compilation or startup, also run these focused native gates
on each engine using new work directories:

```sh
python3 "mom/99 mom_test_orchestrator/host/content_backend_gate.py" \
  --openmw /absolute/path/to/openmw --workdir /tmp/mom-content-backend-UNIQUE
python3 "mom/99 mom_test_orchestrator/host/content_lifecycle.py" \
  --openmw /absolute/path/to/openmw --workdir /tmp/mom-content-lifecycle-UNIQUE
```

The backend gate covers native fields, copy/staging/rollback and list semantics.
The lifecycle gate enables actual production entry points and checks mixed
sources, reset, Lua reload, two saved games, later overrides, failed inputs,
and independent GLOBAL/LOAD configuration changes. The ordinary correctness
matrix includes a mixed-file scenario and a fresh-save persistence campaign.

## 3. Record performance

Check the workload projection, then collect all three modes with the `release`
profile on a controlled host. Choose an actual available CPU set and an
explicit patched engine for embedded/integration runs:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" catalog --check

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode standalone --profile release --lua luajit --cpu-set CPU_LIST \
  --output /tmp/mom-release-standalone.json

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode embedded --profile release --openmw /absolute/path/to/openmw \
  --cpu-set CPU_LIST --output /tmp/mom-release-embedded.json

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode integration --profile release --openmw /absolute/path/to/openmw \
  --cpu-set CPU_LIST --output /tmp/mom-release-integration.json
```

Run `mom_harness.py validate PATH` on each summary and preserve its complete
artifact directory. Require workload assertions and applicable budgets to
pass. For changed hot paths, also retain a compatible `standard` before/after
comparison. Report its measured result, including inconclusive or incompatible
results. Re-establish a baseline when workload meaning or instrumentation
changes. See the [performance workflow](README.md#performance).

## 4. Inspect an ordinary install

Extract the candidate package into a separate data directory. In an isolated
ordinary gameplay profile, enable vanilla masters, MOM, and the vanilla-data
example from the [author guide](../../mom/docs/MOD_AUTHOR_GUIDE.md). Keep the
harness data directory out of this profile.

At the example's stated location, check the visible result, leave and revisit,
then save, exit OpenMW, load the save, and revisit again. Check that output
counts remain stable and supported changes persist or revert as described.
Call `I.MOM.selfcheck()` and inspect the MOM log entries. Exercise the install
on both supported engines and record each build and data order.

The automated Balmora fixtures belong to the harness's isolated data root;
they are not installed by the public examples directory. Use a focused world
scenario when investigating those cases.

`bash tools/smoke_profile.sh --log /absolute/path/to/openmw.log` checks bootstrap,
selfcheck, and failure entries in the chosen ordinary-profile log. It does not
verify visual behavior or replace the restart suite.

## 5. Build the final archive and retain the record

```sh
python3 tools/release.py --build /tmp/mom-release.zip
python3 tools/release.py --audit /tmp/mom-release.zip
```

Record the commit, clean-tree state, engine/build identities, platform and game
data, correctness receipt, performance artifacts and comparisons, package audit,
manual smoke result, and any remaining known issue. Publish only the audited
archive produced from those sources.
