# Release Procedure

Run every step from a clean checkout of the intended release commit and retain receipts outside the repository.

---

## 1. Local Static & Packaging Checks

```sh
git status --short
git diff --check
"mom/99 mom_test_orchestrator/run_pure_tests.sh"
"mom/99 mom_test_orchestrator/run_pure_tests.sh" --stress-only
python3 -m unittest discover -s "mom/99 mom_test_orchestrator/host/tests"
python3 tools/release.py
```

[`tools/release_manifest.txt`](../../tools/release_manifest.txt) controls archive membership. `release.py` strips the leading `mom/` prefix, writes deterministic ZIP metadata, and rejects symlinks, hidden metadata, logs, saves, or bytecode.

---

## 2. Dual-Engine Correctness & Examples

Run against patched **LuaJIT** and **Luau (`clockwork-alpha`)** OpenMW builds using vanilla masters (`Morrowind.esm`, `Tribunal.esm`, `Bloodmoon.esm`):

```sh
LUAJIT_OPENMW=/absolute/path/to/luajit-build/openmw
LUAU_OPENMW=/absolute/path/to/luau-build/openmw

# Complete dual-engine matrix (pure normal/stress, all world scenarios, all restart campaigns)
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" check \
  --luajit-openmw "$LUAJIT_OPENMW" \
  --luau-openmw "$LUAU_OPENMW" \
  --workdir /tmp/mom-release-check-UNIQUE

# Compile all shipped configs and complete doc YAML blocks in LOAD + GLOBAL
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" examples --openmw "$LUAJIT_OPENMW"
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" examples --openmw "$LUAU_OPENMW"
```

When startup compilation or the LOAD backend changed, also run the content backend and production lifecycle gates on both engines:

```sh
python3 "mom/99 mom_test_orchestrator/host/content_backend_gate.py" \
  --openmw "$LUAJIT_OPENMW" --workdir /tmp/mom-backend-luajit-UNIQUE
python3 "mom/99 mom_test_orchestrator/host/content_backend_gate.py" \
  --openmw "$LUAU_OPENMW" --workdir /tmp/mom-backend-luau-UNIQUE

python3 "mom/99 mom_test_orchestrator/host/content_lifecycle.py" \
  --openmw "$LUAJIT_OPENMW" --workdir /tmp/mom-lifecycle-luajit-UNIQUE
python3 "mom/99 mom_test_orchestrator/host/content_lifecycle.py" \
  --openmw "$LUAU_OPENMW" --workdir /tmp/mom-lifecycle-luau-UNIQUE
```

---

## 3. Performance Verification

Verify the workload catalog, then collect `release` profiles pinned to an idle CPU set:

```sh
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" catalog --check

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode standalone --profile release --lua luajit --cpu-set CPU_LIST \
  --output /tmp/mom-release-standalone.json

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode embedded --profile release --openmw "$LUAU_OPENMW" --cpu-set CPU_LIST \
  --output /tmp/mom-release-embedded.json

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" run \
  --mode integration --profile release --openmw "$LUAU_OPENMW" --cpu-set CPU_LIST \
  --output /tmp/mom-release-integration.json

python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" validate /tmp/mom-release-standalone.json
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" validate /tmp/mom-release-embedded.json
python3 "mom/99 mom_test_orchestrator/host/mom_harness.py" validate /tmp/mom-release-integration.json
```

---

## 4. Manual Ordinary-Profile Smoke Check

1. Extract the candidate archive into a clean data directory (without the test harness).
2. Enable vanilla masters, `00 OpenMW` / `mom.omwscripts`, and the tutorial patch from `02 Examples`.
3. Visit Balmora's Eight Plates, verify the placed tapestry, leave and revisit, save, restart OpenMW, reload, and confirm no duplication.
4. Run `I.MOM.selfcheck()` in `luag`, then verify the log:
   ```sh
   bash tools/smoke_profile.sh --log /absolute/path/to/openmw.log
   ```

---

## 5. Build & Audit the Final Release ZIP

```sh
python3 tools/release.py --build /tmp/mom-release.zip
python3 tools/release.py --audit /tmp/mom-release.zip
```

Record the release commit hash, both engine build identities, and pass results in the release notes, and publish only the audited ZIP.
