from __future__ import annotations

import copy
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HOST_ROOT = Path(__file__).resolve().parents[1]
HARNESS_ROOT = HOST_ROOT.parent
sys.path.insert(0, str(HOST_ROOT))

import artifacts
import mom_harness
import openmw
import process
import results


CATALOG, _PROFILES, BUDGETS = results.load_contracts(HARNESS_ROOT / "performance")


class MomHarnessTests(unittest.TestCase):
    def test_benchmark_build_selection_reaches_engine_preparation(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            arguments = self.embedded_arguments(root / "artifacts")
            arguments.build_openmw = True
            arguments.openmw_source = root / "source"
            artifact = artifacts.ArtifactRun(root / "artifacts", mom_harness.REPOSITORY_ROOT)
            with mock.patch.object(openmw, "prepare_embedded", side_effect=openmw.OpenMWError("stop")) as prepare:
                with self.assertRaisesRegex(openmw.OpenMWError, "stop"):
                    mom_harness.run_embedded_process(
                        index=0, identifiers=["idle_tick"],
                        profile={"samplesPerProcess": 3, "warmupsPerProcess": 1, "memoryEvidence": False},
                        artifact=artifact, arguments=arguments, cpu_set=None,
                        process_records=[], prepare_records=[],
                    )
            self.assertTrue(prepare.call_args.kwargs["build_openmw"])
            self.assertEqual(prepare.call_args.kwargs["source_directory"], root / "source")
        arguments = mom_harness.parser().parse_args(["run", "--mode", "embedded", "--build-openmw"])
        self.assertTrue(arguments.build_openmw)
        arguments = mom_harness.parser().parse_args(["run", "--build-openmw"])
        with self.assertRaisesRegex(mom_harness.HarnessError, "require embedded or integration"):
            mom_harness.run_experiment(arguments)

    def test_workload_id_width_expands_for_long_identifiers(self) -> None:
        self.assertEqual(
            mom_harness.workload_id_width([
                {"id": "short"},
                {"id": "x" * 43},
            ]),
            43,
        )
        self.assertEqual(
            mom_harness.workload_id_width([{"id": "short"}]),
            31,
        )

    def test_summary_prints_memory_maxima_and_limits(self) -> None:
        row = {
            "id": "memory_case",
            "status": "passed",
            "statisticsMicros": {"median": 1.5},
            "budgetMicros": 2,
            "memoryAfterStatisticsKb": {"maximum": 12.5},
            "memoryRetainedStatisticsKb": {"maximum": 3.5},
            "budgetMemoryAllocatedKb": 16,
            "budgetMemoryRetainedKb": 4,
            "allocationProbe": {
                "status": "passed",
                "memoryAllocatedDeltaKb": 11.5,
            },
        }
        with mock.patch("builtins.print") as printer:
            mom_harness.print_summary({
                "status": "passed",
                "workloads": [row],
            })
        rendered = printer.call_args_list[0].args[0]
        self.assertIn("allocated=11.5/<=16.0", rendered)
        self.assertIn("footprint-after=12.5/telemetry", rendered)
        self.assertIn("footprint-retained=3.5/<=4.0 KB", rendered)

    def embedded_arguments(self, artifact_root: Path) -> object:
        return mom_harness.parser().parse_args([
            "run",
            "--mode", "embedded",
            "--profile", "quick",
            "--workload", "idle_tick",
            "--artifact-root", str(artifact_root),
            "--timeout", "1",
            "--prepare-timeout", "1",
        ])

    def finalized_run(self, artifact_root: Path) -> tuple[Path, dict]:
        runs = list((artifact_root / "runs").iterdir())
        self.assertEqual(len(runs), 1)
        return runs[0], artifacts.validate_run_directory(runs[0])

    def test_failed_preparation_retains_process_evidence(self) -> None:
        emitted: list[dict] = []

        def fail_preparation(command: list[str], **options: object) -> dict:
            stdout_path = options["stdout_path"]
            stderr_path = options["stderr_path"]
            assert isinstance(stdout_path, Path)
            assert isinstance(stderr_path, Path)
            stdout_path.write_text("preparation stdout\n", encoding="utf-8")
            stderr_path.write_text("preparation timed out\n", encoding="utf-8")
            record = {
                "command": command,
                "cwd": str(Path(options["cwd"]).resolve()),
                "startedAtUtc": "2026-07-26T00:00:00Z",
                "durationSeconds": 1.25,
                "returnCode": -15,
                "timedOut": True,
                "cpuAffinity": {
                    "requested": None,
                    "effective": "2",
                    "scope": "process_group",
                },
            }
            emitted.append(record)
            return record

        with tempfile.TemporaryDirectory() as directory:
            artifact_root = Path(directory) / "artifacts"
            with mock.patch.object(process, "run_process", side_effect=fail_preparation):
                with self.assertRaisesRegex(
                    openmw.OpenMWError,
                    "preparation failed",
                ):
                    mom_harness.run_experiment(
                        self.embedded_arguments(artifact_root)
                    )

            run_directory, receipt = self.finalized_run(artifact_root)
            self.assertEqual(receipt["status"], "failed")
            self.assertEqual(receipt["processes"], [])
            self.assertEqual(receipt["preparationProcesses"], emitted)
            retained = receipt["preparationProcesses"][0]
            self.assertEqual(retained["returnCode"], -15)
            self.assertIs(retained["timedOut"], True)
            self.assertEqual(
                retained["cpuAffinity"],
                {
                    "requested": None,
                    "effective": "2",
                    "scope": "process_group",
                },
            )
            manifest = {entry["path"] for entry in receipt["artifacts"]}
            self.assertIn("logs/prepare-000.stdout.txt", manifest)
            self.assertIn("logs/prepare-000.stderr.txt", manifest)
            self.assertEqual(
                artifacts.resolve_run_artifact(
                    run_directory,
                    receipt,
                    "logs/prepare-000.stderr.txt",
                ).read_text(
                    encoding="utf-8"
                ),
                "preparation timed out\n",
            )

    def test_post_run_failure_retains_execution_process_evidence(self) -> None:
        preparation = {
            "command": ["/fixture/prepare"],
            "cwd": str(HARNESS_ROOT),
            "startedAtUtc": "2026-07-26T00:00:00Z",
            "durationSeconds": 0.25,
            "returnCode": 0,
            "timedOut": False,
            "cpuAffinity": {
                "requested": None,
                "effective": "3",
                "scope": "process_group",
            },
        }
        execution = {
            "command": ["/fixture/openmw"],
            "cwd": str(mom_harness.REPOSITORY_ROOT),
            "startedAtUtc": "2026-07-26T00:00:01Z",
            "durationSeconds": 0.75,
            "returnCode": 0,
            "timedOut": False,
            "cpuAffinity": {
                "requested": None,
                "effective": "3",
                "scope": "process_group",
            },
        }

        def prepare(**options: object) -> tuple[dict, dict]:
            callback = options["record_process"]
            assert callable(callback)
            callback(preparation)
            work = Path(options["work_directory"])
            return {
                "command": execution["command"],
                "openmw": {"binary": execution["command"][0]},
                "paths": {
                    "config": str(work / "openmw.cfg"),
                    "settings": str(work / "settings.cfg"),
                    "runOptions": str(work / "run_options.lua"),
                    "log": str(work / "openmw.log"),
                    "result": str(options["raw_result"]),
                },
            }, preparation

        def run_embedded(_launch: dict, **options: object) -> dict:
            stdout_path = options["stdout_path"]
            stderr_path = options["stderr_path"]
            assert isinstance(stdout_path, Path)
            assert isinstance(stderr_path, Path)
            stdout_path.write_text("execution stdout\n", encoding="utf-8")
            stderr_path.write_text("execution stderr\n", encoding="utf-8")
            return execution

        with tempfile.TemporaryDirectory() as directory:
            artifact_root = Path(directory) / "artifacts"
            with (
                mock.patch.object(openmw, "prepare_embedded", side_effect=prepare),
                mock.patch.object(openmw, "run_embedded", side_effect=run_embedded),
                mock.patch.object(
                    openmw,
                    "retain_log",
                    side_effect=openmw.OpenMWError("fixture retention failed"),
                ),
            ):
                with self.assertRaisesRegex(
                    openmw.OpenMWError,
                    "retention failed",
                ):
                    mom_harness.run_experiment(
                        self.embedded_arguments(artifact_root)
                    )

            _run_directory, receipt = self.finalized_run(artifact_root)
            self.assertEqual(receipt["status"], "failed")
            self.assertEqual(receipt["preparationProcesses"], [preparation])
            self.assertEqual(receipt["processes"], [execution])
            retained = receipt["processes"][0]
            self.assertEqual(retained["returnCode"], 0)
            self.assertIs(retained["timedOut"], False)
            self.assertEqual(retained["cpuAffinity"], execution["cpuAffinity"])
            manifest = {entry["path"] for entry in receipt["artifacts"]}
            self.assertIn("logs/process-000.stdout.txt", manifest)
            self.assertIn("logs/process-000.stderr.txt", manifest)

    def test_standalone_exit_reports_publication_not_workload_status(self) -> None:
        lua = shutil.which("lua")
        if lua is None:
            self.skipTest("Lua executable is unavailable")
        modules = {
            "scripts/mom_test_orchestrator/performance/cases/algorithmic.lua":
                "return {}\n",
            "scripts/mom_test_orchestrator/performance/runner.lua": """
local M = {}
function M.new()
  return {
    runAll = function()
      return {status = 'failed', results = {}}
    end,
  }
end
return M
""",
            "scripts/mom_test_orchestrator/performance/unsafe_runtime.lua":
                "return {standalone = function() return {} end}\n",
            "scripts/mom_test_orchestrator/performance/protocol.lua": """
local M = {}
function M.write(_, path)
  local file = assert(io.open(path, 'wb'))
  assert(file:write('{"status":"failed"}\\n'))
  assert(file:close())
end
return M
""",
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            module_root = root / "mom" / "99 mom_test_orchestrator"
            for relative, source in modules.items():
                destination = module_root / relative
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_text(source, encoding="utf-8")
            result_path = root / "raw.json"
            completed = subprocess.run(
                [
                    lua,
                    str(HARNESS_ROOT / "performance" / "standalone.lua"),
                    str(root),
                    str(result_path),
                    "1",
                    "0",
                    "0",
                    "0" * 64,
                    "fixture",
                ],
                cwd=root,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            self.assertEqual(
                json.loads(result_path.read_text(encoding="utf-8"))["status"],
                "failed",
            )

    def test_allocation_entrypoint_rejects_batched_workloads(self) -> None:
        lua = shutil.which("lua")
        if lua is None:
            self.skipTest("Lua executable is unavailable")
        executable = Path(lua).resolve(strict=True)
        with tempfile.TemporaryDirectory() as directory:
            result_path = Path(directory) / "allocation.json"
            completed = subprocess.run(
                [
                    str(executable),
                    str(HARNESS_ROOT / "performance" / "allocation.lua"),
                    str(mom_harness.REPOSITORY_ROOT),
                    str(result_path),
                    artifacts.sha256_file(executable),
                    "idle_tick",
                    "broad_loaded_cell_audit",
                ],
                cwd=mom_harness.REPOSITORY_ROOT,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=10,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("exactly one workload", completed.stderr)
            self.assertFalse(result_path.exists())

    def test_process_success_is_required_even_when_a_result_exists(self) -> None:
        record = {"timedOut": False, "returnCode": 0}
        mom_harness.require_successful_process(record, label="fixture")
        record["returnCode"] = 23
        with self.assertRaisesRegex(mom_harness.HarnessError, "status 23"):
            mom_harness.require_successful_process(record, label="fixture")
        record["timedOut"] = True
        with self.assertRaisesRegex(mom_harness.HarnessError, "timed out"):
            mom_harness.require_successful_process(record, label="fixture")

    def test_experiment_groups_batch_each_replicate_and_escape_fresh_processes(
        self,
    ) -> None:
        by_id = results.catalog_by_id(CATALOG)
        regular = copy.deepcopy(by_id["idle_tick"])
        second = copy.deepcopy(by_id["static_cell_queue"])
        third = copy.deepcopy(by_id["event_fanout"])
        fresh = copy.deepcopy(by_id["ledger_roundtrip_10k"])
        fresh["requiresFreshProcess"] = True
        profile = {
            "processes": 4,
            "samplesPerProcess": 1,
            "warmupsPerProcess": 0,
            "memoryEvidence": False,
        }
        groups = mom_harness.experiment_groups(
            [regular, fresh, second, third],
            profile,
        )
        self.assertEqual(groups, [
            ["idle_tick", "static_cell_queue", "event_fanout"],
            ["ledger_roundtrip_10k"],
            ["static_cell_queue", "event_fanout", "idle_tick"],
            ["ledger_roundtrip_10k"],
            ["event_fanout", "idle_tick", "static_cell_queue"],
            ["ledger_roundtrip_10k"],
            ["idle_tick", "static_cell_queue", "event_fanout"],
            ["ledger_roundtrip_10k"],
        ])
        occurrences = {
            identifier: sum(identifier in group for group in groups)
            for identifier in (
                "idle_tick",
                "static_cell_queue",
                "event_fanout",
                "ledger_roundtrip_10k",
            )
        }
        self.assertEqual(occurrences, {
            "idle_tick": 4,
            "static_cell_queue": 4,
            "event_fanout": 4,
            "ledger_roundtrip_10k": 4,
        })

    def test_memory_evidence_isolates_every_workload_process(self) -> None:
        by_id = results.catalog_by_id(CATALOG)
        selected = [
            copy.deepcopy(by_id["idle_tick"]),
            copy.deepcopy(by_id["static_cell_queue"]),
            copy.deepcopy(by_id["event_fanout"]),
        ]
        selected[1]["requiresFreshProcess"] = True
        groups = mom_harness.experiment_groups(selected, {
            "processes": 2,
            "samplesPerProcess": 1,
            "warmupsPerProcess": 0,
            "memoryEvidence": True,
        })
        self.assertEqual(groups, [
            ["idle_tick"],
            ["static_cell_queue"],
            ["event_fanout"],
            ["idle_tick"],
            ["static_cell_queue"],
            ["event_fanout"],
        ])

    def test_allocation_probes_are_exact_runtime_budgeted_and_never_batched(
        self,
    ) -> None:
        allocated_ids = [
            "cold_runtime_bootstrap_256",
            "broad_loaded_cell_audit",
            "operation_journal_cycle",
        ]
        selected = results.select_workloads(
            CATALOG,
            allocated_ids
            + ["state_large_claim_component", "ledger_roundtrip_10k"],
            "standalone",
        )
        runtime = {
            "lua": "Lua 5.5",
            "jit": {"available": False},
            "executableSha256": (
                "a901fc8fe16f09d9a8d2e23947cc847c"
                "e1fc09fa6e0cb89ceec23d4566869d30"
            ),
        }
        profile = {
            "processes": 4,
            "samplesPerProcess": 8,
            "warmupsPerProcess": 2,
            "memoryEvidence": True,
        }
        self.assertEqual(
            mom_harness.allocation_probe_identifiers(
                selected,
                "standalone",
                profile,
                BUDGETS,
                runtime,
            ),
            allocated_ids,
        )
        self.assertNotIn(
            "state_large_claim_component",
            mom_harness.allocation_probe_identifiers(
                selected,
                "standalone",
                profile,
                BUDGETS,
                runtime,
            ),
        )
        timing_only = {**profile, "memoryEvidence": False}
        self.assertEqual(
            mom_harness.allocation_probe_identifiers(
                selected,
                "standalone",
                timing_only,
                BUDGETS,
                runtime,
            ),
            [],
        )
        other_binary = {**runtime, "executableSha256": "1" * 64}
        self.assertEqual(
            mom_harness.allocation_probe_identifiers(
                selected,
                "standalone",
                profile,
                BUDGETS,
                other_binary,
            ),
            [],
        )

    def test_direct_performance_shell_path_is_not_public(self) -> None:
        completed = subprocess.run(
            [str(HARNESS_ROOT / "run_harness.sh"), "--performance"],
            cwd=HARNESS_ROOT,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=10,
        )
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("host/mom_harness.py", completed.stderr)

    def copied_contract_root(
        self,
        root: Path,
        workloads: list[dict],
    ) -> None:
        sources = {
            source
            for workload in workloads
            for source in workload["contractSources"]
        }
        sources.update(mom_harness.MODE_ENTRYPOINT_SOURCES.values())
        sources.add(mom_harness.ALLOCATION_ENTRYPOINT_SOURCE)
        sources.add(mom_harness.ALLOCATION_PROBE_SOURCE)
        for source in sources:
            destination = root / source
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(HARNESS_ROOT / source, destination)

    def test_selected_workload_identity_ignores_unselected_catalog_changes(self) -> None:
        selected = results.select_workloads(CATALOG, ["idle_tick"], "standalone")
        baseline = mom_harness.selected_workload_contract_identity(
            selected,
            "standalone",
            BUDGETS,
        )

        changed_catalog = copy.deepcopy(CATALOG)
        changed_catalog["workloads"][0]["version"] += 1
        unchanged_selection = results.select_workloads(
            changed_catalog,
            ["idle_tick"],
            "standalone",
        )
        self.assertEqual(
            baseline,
            mom_harness.selected_workload_contract_identity(
                unchanged_selection,
                "standalone",
                BUDGETS,
            ),
        )

    def test_selected_workload_identity_tracks_selected_contract_and_budget(self) -> None:
        selected = results.select_workloads(CATALOG, ["idle_tick"], "standalone")
        baseline = mom_harness.selected_workload_contract_identity(
            selected,
            "standalone",
            BUDGETS,
        )

        changed_selection = copy.deepcopy(selected)
        changed_selection[0]["version"] += 1
        self.assertNotEqual(
            baseline,
            mom_harness.selected_workload_contract_identity(
                changed_selection,
                "standalone",
                BUDGETS,
            ),
        )

        changed_budgets = copy.deepcopy(BUDGETS)
        changed_budgets["absoluteMicros"]["process_cpu"]["idle_tick"] += 1
        self.assertNotEqual(
            baseline,
            mom_harness.selected_workload_contract_identity(
                selected,
                "standalone",
                changed_budgets,
            ),
        )

        changed_budgets = copy.deepcopy(BUDGETS)
        changed_budgets["absoluteMemoryKb"]["standalone"][
            "test-runtime"
        ] = {"allocated": {}, "retained": {"idle_tick": 1}}
        self.assertNotEqual(
            baseline,
            mom_harness.selected_workload_contract_identity(
                selected,
                "standalone",
                changed_budgets,
            ),
        )

        changed_budgets = copy.deepcopy(BUDGETS)
        changed_budgets["absoluteMemoryKb"]["embedded"][
            "test-runtime"
        ] = {"allocated": {}, "retained": {"idle_tick": 1}}
        self.assertEqual(
            baseline,
            mom_harness.selected_workload_contract_identity(
                selected,
                "standalone",
                changed_budgets,
            ),
        )

    def test_selected_implementation_changes_identity_but_unrelated_module_does_not(
        self,
    ) -> None:
        selected = results.select_workloads(CATALOG, ["idle_tick"], "standalone")
        unrelated = results.select_workloads(
            CATALOG,
            ["static_cell_queue"],
            "standalone",
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.copied_contract_root(root, selected + unrelated)
            baseline = mom_harness.selected_workload_contract_identity(
                selected,
                "standalone",
                BUDGETS,
                root,
            )

            unrelated_source = next(
                source
                for source in unrelated[0]["contractSources"]
                if source not in selected[0]["contractSources"]
            )
            with (root / unrelated_source).open("a", encoding="utf-8") as stream:
                stream.write("\n-- unrelated test change\n")
            self.assertEqual(
                baseline,
                mom_harness.selected_workload_contract_identity(
                    selected,
                    "standalone",
                    BUDGETS,
                    root,
                ),
            )

            selected_source = next(
                source
                for source in selected[0]["contractSources"]
                if source.endswith("/cases/algorithmic/runtime.lua")
            )
            with (root / selected_source).open("a", encoding="utf-8") as stream:
                stream.write("\n-- selected test change\n")
            self.assertNotEqual(
                baseline,
                mom_harness.selected_workload_contract_identity(
                    selected,
                    "standalone",
                    BUDGETS,
                    root,
                ),
            )

    def test_mode_entrypoint_changes_only_applicable_identities(self) -> None:
        selections = {
            "standalone": results.select_workloads(
                CATALOG, ["idle_tick"], "standalone"
            ),
            "embedded": results.select_workloads(
                CATALOG, ["idle_tick"], "embedded"
            ),
            "integration": results.select_workloads(
                CATALOG, ["integration_selfcheck"], "integration"
            ),
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.copied_contract_root(
                root,
                [
                    workload
                    for selection in selections.values()
                    for workload in selection
                ],
            )

            def identities() -> dict[str, str]:
                return {
                    mode: mom_harness.selected_workload_contract_identity(
                        selection,
                        mode,
                        BUDGETS,
                        root,
                    )
                    for mode, selection in selections.items()
                }

            baseline = identities()
            standalone_entrypoint = (
                root / mom_harness.MODE_ENTRYPOINT_SOURCES["standalone"]
            )
            with standalone_entrypoint.open("a", encoding="utf-8") as stream:
                stream.write("\n-- standalone entrypoint test change\n")
            changed = identities()
            self.assertNotEqual(baseline["standalone"], changed["standalone"])
            self.assertEqual(baseline["embedded"], changed["embedded"])
            self.assertEqual(baseline["integration"], changed["integration"])

            shutil.copy2(
                HARNESS_ROOT / mom_harness.MODE_ENTRYPOINT_SOURCES["standalone"],
                standalone_entrypoint,
            )
            engine_entrypoint = (
                root / mom_harness.MODE_ENTRYPOINT_SOURCES["embedded"]
            )
            with engine_entrypoint.open("a", encoding="utf-8") as stream:
                stream.write("\n-- engine entrypoint test change\n")
            changed = identities()
            self.assertEqual(baseline["standalone"], changed["standalone"])
            self.assertNotEqual(baseline["embedded"], changed["embedded"])
            self.assertNotEqual(baseline["integration"], changed["integration"])


if __name__ == "__main__":
    unittest.main()
