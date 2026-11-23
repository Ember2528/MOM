from __future__ import annotations

import copy
import sys
from pathlib import Path
import tempfile
import unittest

HOST_ROOT = Path(__file__).resolve().parents[1]
HARNESS_ROOT = HOST_ROOT.parent
sys.path.insert(0, str(HOST_ROOT))

import results


CATALOG, _PROFILES, BUDGETS = results.load_contracts(HARNESS_ROOT / "performance")
FAKE_EXECUTABLE_SHA256 = "0" * 64
FAKE_RUNTIME = {
    "lua": "fake",
    "jit": {"available": False},
    "executableSha256": FAKE_EXECUTABLE_SHA256,
}
FAKE_MEMORY_RUNTIME = results.memory_runtime_identity(FAKE_RUNTIME)


def fake_raw(
    identifier: str = "idle_tick",
    samples: list[float] | None = None,
    mode: str = "standalone",
    memory_evidence: bool = True,
    memory_case_before_kb: float = 1,
    memory_setup_before_kb: float = 1,
    memory_timed_before_kb: float = 1,
    memory_after_kb: float = 2,
    memory_retained_kb: float = 1,
    runtime: dict = FAKE_RUNTIME,
) -> dict:
    samples = samples or [0.01]
    definition = results.catalog_by_id(CATALOG)[identifier]
    checksum = "stable"
    rows = []
    for elapsed in samples:
        row = {
            "elapsedSeconds": elapsed,
            "operations": definition["operations"],
            "checksum": checksum,
            "valid": elapsed >= definition["minimumSampleSeconds"],
        }
        if memory_evidence:
            row.update({
                "gcCaseBefore": {
                    "memoryKb": memory_case_before_kb,
                    "running": True,
                },
                "gcSetupBefore": {
                    "memoryKb": memory_setup_before_kb,
                    "running": True,
                },
                "gcBefore": {
                    "memoryKb": memory_timed_before_kb,
                    "running": True,
                },
                "gcAfter": {"memoryKb": memory_after_kb, "running": True},
                "gcRetained": {"memoryKb": memory_retained_kb, "running": True},
            })
        rows.append(row)
    return {
        "schemaVersion": 5,
        "kind": "mom.performance.raw",
        "status": "passed",
        "mode": mode,
        "clock": "process_cpu" if mode == "standalone" else "monotonic_wall",
        "memoryEvidence": memory_evidence,
        "capturedAtUtc": "2026-01-01T00:00:00Z",
        "runtime": runtime,
        "warmupsPerCase": 1,
        "samplesPerCase": len(samples),
        "results": [{
            "id": identifier,
            "version": definition["version"],
            "category": definition["category"],
            "unit": "microseconds_per_operation",
            "operations": definition["operations"],
            "minimumSampleSeconds": definition["minimumSampleSeconds"],
            "gcPolicy": definition["gcPolicy"],
            "semantics": definition["semantics"],
            "detail": {},
            "status": "passed",
            "checksum": checksum,
            "samples": rows,
        }],
    }


def fake_allocation(
    identifier: str = "idle_tick",
    *,
    allocated_kb: float = 1,
    retained_kb: float = 0,
    checksum: str = "stable",
    runtime: dict = FAKE_RUNTIME,
) -> dict:
    definition = results.catalog_by_id(CATALOG)[identifier]
    before = 10
    return {
        "schemaVersion": 1,
        "kind": "mom.performance.allocation",
        "status": "passed",
        "mode": "standalone",
        "capturedAtUtc": "2026-01-01T00:00:00Z",
        "runtime": runtime,
        "warmupsPerCase": 1,
        "samplesPerCase": 1,
        "result": {
            "id": identifier,
            "version": definition["version"],
            "category": definition["category"],
            "unit": "kilobytes_per_timed_body",
            "operations": definition["operations"],
            "gcPolicy": definition["gcPolicy"],
            "semantics": definition["semantics"],
            "detail": {},
            "status": "passed",
            "checksum": checksum,
            "samples": [{
                "operations": definition["operations"],
                "checksum": checksum,
                "gcBefore": {"memoryKb": before, "running": True},
                "gcStoppedAfter": {
                    "memoryKb": before + allocated_kb,
                    "running": False,
                },
                "gcRetained": {
                    "memoryKb": before + retained_kb,
                    "running": True,
                },
            }],
        },
    }


def summary(
    samples: list[float],
    *,
    cpu: str = "cpu",
    memory_evidence: bool = True,
    budgets: dict | None = None,
    memory_case_before_kb: float = 1,
    memory_setup_before_kb: float = 1,
    memory_timed_before_kb: float = 1,
    memory_after_kb: float = 2,
    memory_retained_kb: float = 1,
    runtime: dict = FAKE_RUNTIME,
    allocation_result: dict | None = None,
) -> dict:
    budgets = budgets or BUDGETS
    process_count = 3 if len(samples) >= 9 and len(samples) % 3 == 0 else 1
    per_process = len(samples) // process_count
    raw_runs = [
        fake_raw(
            samples=samples[index:index + per_process],
            memory_evidence=memory_evidence,
            memory_case_before_kb=memory_case_before_kb,
            memory_setup_before_kb=memory_setup_before_kb,
            memory_timed_before_kb=memory_timed_before_kb,
            memory_after_kb=memory_after_kb,
            memory_retained_kb=memory_retained_kb,
            runtime=runtime,
        )
        for index in range(0, len(samples), per_process)
    ]
    for raw in raw_runs:
        results.validate_raw_result(raw, CATALOG)
    value = results.summarize_raw_results(
        raw_runs,
        [results.catalog_by_id(CATALOG)["idle_tick"]],
        budgets,
        profile="test",
        allocation_results=(
            [allocation_result] if allocation_result is not None else []
        ),
        comparability={
            "cpuModel": cpu,
            "cpuGovernors": ["performance"],
            "cpuAffinity": "0",
            "kernel": "test",
            "machine": "test",
            "lua": "Lua test",
            "luaExecutableSha256": runtime.get("executableSha256"),
            "jitAvailable": False,
            "jitEnabled": None,
            "jitVersion": None,
            "jitArchitecture": None,
            "selectedWorkloadContractSha256": "0" * 64,
            "openmwSha256": None,
            "openmwBuildId": None,
            "openmwSourceRef": None,
            "openmwBuildType": None,
            "gameData": None,
            "runParameters": {
                "processes": process_count,
                "samplesPerProcess": per_process,
                "warmupsPerProcess": 1,
                "memoryEvidence": memory_evidence,
            },
            "nativeCampaign": None,
        },
    )
    results.validate_summary(value, CATALOG, budgets)
    return value


class ResultTests(unittest.TestCase):
    def test_embedded_raw_accepts_unavailable_utc_and_keeps_other_fields_strict(self) -> None:
        raw = fake_raw(mode="embedded")
        del raw["capturedAtUtc"]
        self.assertIs(raw, results.validate_raw_result(raw, CATALOG))
        raw["capturedAtUtc"] = None
        self.assertIs(raw, results.validate_raw_result(raw, CATALOG))
        for key in ("clock", "runtime", "results"):
            missing = copy.deepcopy(raw)
            del missing[key]
            with self.subTest(key=key), self.assertRaisesRegex(results.ResultError, "shape"):
                results.validate_raw_result(missing, CATALOG)
        raw["unexpected"] = True
        with self.assertRaisesRegex(results.ResultError, "shape"):
            results.validate_raw_result(raw, CATALOG)

    def test_raw_contract_accepts_matching_catalog(self) -> None:
        raw = fake_raw(samples=[0.01, 0.011])
        self.assertIs(raw, results.validate_raw_result(raw, CATALOG))
        with self.assertRaisesRegex(results.ResultError, "warmup"):
            results.validate_raw_result(raw, CATALOG, expected_warmups=2)
        with self.assertRaisesRegex(results.ResultError, "memory evidence"):
            results.validate_raw_result(raw, CATALOG, expected_memory=False)
        missing_binary = copy.deepcopy(raw)
        del missing_binary["runtime"]["executableSha256"]
        with self.assertRaisesRegex(results.ResultError, "executable identity"):
            results.validate_raw_result(missing_binary, CATALOG)

    def test_timing_only_raw_and_summary_omit_memory_samples(self) -> None:
        raw = fake_raw(samples=[0.01, 0.011], memory_evidence=False)
        self.assertIs(raw, results.validate_raw_result(raw, CATALOG))
        self.assertNotIn("gcBefore", raw["results"][0]["samples"][0])
        invalid = copy.deepcopy(raw)
        invalid["results"][0]["samples"][0]["gcBefore"] = {
            "memoryKb": 1,
            "running": True,
        }
        with self.assertRaisesRegex(results.ResultError, "unsupported shape"):
            results.validate_raw_result(invalid, CATALOG)

        value = summary([0.01] * 9, memory_evidence=False)
        row = value["workloads"][0]
        self.assertEqual(row["memoryAfterDeltaKb"], [])
        self.assertEqual(row["memoryRetainedDeltaKb"], [])
        self.assertEqual(row["memorySetupDeltaKb"], [])
        self.assertEqual(row["memoryTimedTransientDeltaKb"], [])
        self.assertEqual(row["memoryTimedRetainedDeltaKb"], [])
        self.assertIsNone(row["memoryAfterStatisticsKb"])
        self.assertIsNone(row["memoryRetainedStatisticsKb"])
        self.assertIsNone(row["memorySetupStatisticsKb"])
        self.assertIsNone(row["memoryTimedTransientStatisticsKb"])
        self.assertIsNone(row["memoryTimedRetainedStatisticsKb"])
        self.assertIs(value, results.validate_summary(value, CATALOG, BUDGETS))

    def test_raw_contract_rejects_metadata_and_checksum_drift(self) -> None:
        raw = fake_raw()
        raw["results"][0]["operations"] += 1
        with self.assertRaisesRegex(results.ResultError, "operations"):
            results.validate_raw_result(raw, CATALOG)
        raw = fake_raw()
        raw["results"][0]["samples"][0]["checksum"] = "different"
        with self.assertRaisesRegex(results.ResultError, "checksum"):
            results.validate_raw_result(raw, CATALOG)

    def test_allocation_contract_validates_identity_checksum_and_gc_state(self) -> None:
        raw = fake_allocation()
        self.assertIs(
            raw,
            results.validate_allocation_result(
                raw,
                CATALOG,
                expected_id="idle_tick",
                expected_runtime=FAKE_RUNTIME,
            ),
        )
        changed_runtime = copy.deepcopy(raw)
        changed_runtime["runtime"]["executableSha256"] = "1" * 64
        with self.assertRaisesRegex(results.ResultError, "timing runtime"):
            results.validate_allocation_result(
                changed_runtime,
                CATALOG,
                expected_runtime=FAKE_RUNTIME,
            )
        changed_checksum = copy.deepcopy(raw)
        changed_checksum["result"]["samples"][0]["checksum"] = "changed"
        with self.assertRaisesRegex(results.ResultError, "checksum"):
            results.validate_allocation_result(changed_checksum, CATALOG)
        running = copy.deepcopy(raw)
        running["result"]["samples"][0]["gcStoppedAfter"]["running"] = True
        with self.assertRaisesRegex(results.ResultError, "collector state"):
            results.validate_allocation_result(running, CATALOG)

    def test_integration_mode_is_distinct_from_embedded(self) -> None:
        identifier = "integration_loaded_cell_scan"
        raw = fake_raw(identifier=identifier, mode="integration")
        self.assertIs(
            raw,
            results.validate_raw_result(
                raw,
                CATALOG,
                expected_mode="integration",
                expected_ids=[identifier],
            ),
        )
        with self.assertRaisesRegex(results.ResultError, "expected embedded"):
            results.validate_raw_result(raw, CATALOG, expected_mode="embedded")
        with self.assertRaisesRegex(results.ResultError, "does not support embedded"):
            results.select_workloads(CATALOG, [identifier], "embedded")

    def test_strict_json_rejects_duplicate_and_nonfinite_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "bad.json"
            path.write_text('{"a":1,"a":2}', encoding="utf-8")
            with self.assertRaisesRegex(results.ResultError, "duplicate"):
                results.load_json(path)
            path.write_text('{"a":NaN}', encoding="utf-8")
            with self.assertRaisesRegex(results.ResultError, "non-finite"):
                results.load_json(path)

    def test_budget_clock_must_apply_to_a_supported_workload_mode(self) -> None:
        invalid = copy.deepcopy(BUDGETS)
        invalid["absoluteMicros"]["process_cpu"]["cold_source_compile"] = 1
        with self.assertRaisesRegex(results.ResultError, "cannot apply"):
            results.validate_budgets(invalid, CATALOG)

        invalid = copy.deepcopy(BUDGETS)
        invalid["absoluteMemoryKb"]["embedded"]["test-runtime"] = {
            "allocated": {},
            "retained": {},
        }
        invalid["absoluteMemoryKb"]["embedded"]["test-runtime"]["retained"][
            "ledger_roundtrip_10k"
        ] = 1
        with self.assertRaisesRegex(results.ResultError, "cannot apply"):
            results.validate_budgets(invalid, CATALOG)

        invalid = copy.deepcopy(BUDGETS)
        invalid["absoluteMemoryKb"]["standalone"][
            "Lua 5.5;jit=none;binary=not-a-sha256"
        ] = {"allocated": {}, "retained": {}}
        with self.assertRaisesRegex(results.ResultError, "binary SHA-256"):
            results.validate_budgets(invalid, CATALOG)

    def test_summary_applies_absolute_budget_to_maximum_sample(self) -> None:
        summarized = summary([0.01, 0.6])
        self.assertEqual(summarized["status"], "failed")
        self.assertEqual(summarized["workloads"][0]["reason"], "absolute_budget_exceeded")
        self.assertIs(summarized, results.validate_summary(summarized, CATALOG, BUDGETS))

    def test_summary_applies_allocated_and_retained_memory_budgets(self) -> None:
        budgets = copy.deepcopy(BUDGETS)
        budgets["absoluteMemoryKb"]["standalone"][FAKE_MEMORY_RUNTIME] = {
            "allocated": {"idle_tick": 0.5},
            "retained": {},
        }
        allocated = summary(
            [0.01],
            budgets=budgets,
            memory_after_kb=1000,
            allocation_result=fake_allocation(allocated_kb=1),
        )
        self.assertEqual(allocated["status"], "failed")
        self.assertEqual(
            allocated["workloads"][0]["reason"],
            "absolute_memory_allocated_budget_exceeded",
        )
        self.assertEqual(
            allocated["workloads"][0]["memoryAfterDeltaKb"],
            [999],
        )

        budgets["absoluteMemoryKb"]["standalone"][FAKE_MEMORY_RUNTIME][
            "allocated"
        ]["idle_tick"] = 2
        after_telemetry = summary(
            [0.01],
            budgets=budgets,
            memory_after_kb=1000,
            allocation_result=fake_allocation(allocated_kb=1),
        )
        self.assertEqual(after_telemetry["status"], "passed")

        budgets["absoluteMemoryKb"]["standalone"][FAKE_MEMORY_RUNTIME][
            "retained"
        ]["idle_tick"] = 0.5
        retained = summary(
            [0.01],
            budgets=budgets,
            memory_retained_kb=2,
            allocation_result=fake_allocation(allocated_kb=1),
        )
        self.assertEqual(retained["status"], "failed")
        self.assertEqual(
            retained["workloads"][0]["reason"],
            "absolute_memory_retained_budget_exceeded",
        )

        timing_only = summary(
            [0.01],
            budgets=budgets,
            memory_evidence=False,
        )
        self.assertEqual(timing_only["status"], "passed")

        with self.assertRaisesRegex(results.ResultError, "missing allocation"):
            summary([0.01], budgets=budgets)

        drift = summary(
            [0.01],
            budgets=budgets,
            allocation_result=fake_allocation(
                allocated_kb=1,
                checksum="changed",
            ),
        )
        self.assertEqual(drift["status"], "failed")
        self.assertEqual(
            drift["workloads"][0]["reason"],
            "allocation_checksum_drift",
        )
        self.assertEqual(drift["allocationProbeCount"], 1)

        failed_probe = fake_allocation()
        failed_probe["status"] = "failed"
        failed_probe["result"]["status"] = "failed"
        del failed_probe["result"]["checksum"]
        failed_probe["result"]["samples"] = []
        failed_probe["result"]["error"] = "synthetic probe failure"
        self.assertIs(
            failed_probe,
            results.validate_allocation_result(failed_probe, CATALOG),
        )
        failed = summary(
            [0.01],
            budgets=budgets,
            allocation_result=failed_probe,
        )
        self.assertEqual(
            failed["workloads"][0]["reason"],
            "allocation_probe_failure",
        )

    def test_memory_budget_is_scoped_to_exact_runtime_identity(self) -> None:
        budgets = copy.deepcopy(BUDGETS)
        budgets["absoluteMemoryKb"]["standalone"][FAKE_MEMORY_RUNTIME] = {
            "allocated": {"idle_tick": 0.5},
            "retained": {"idle_tick": 0.5},
        }
        matched = summary(
            [0.01],
            budgets=budgets,
            allocation_result=fake_allocation(allocated_kb=1),
        )
        self.assertEqual(matched["status"], "failed")

        mismatched_runtime = {
            **FAKE_RUNTIME,
            "executableSha256": "1" * 64,
        }
        value = summary(
            [0.01],
            budgets=budgets,
            runtime=mismatched_runtime,
        )
        row = value["workloads"][0]
        self.assertEqual(value["status"], "passed")
        self.assertIsNone(row["budgetMemoryAllocatedKb"])
        self.assertIsNone(row["budgetMemoryRetainedKb"])

    def test_raw_contract_rejects_a_changing_case_lifetime_baseline(self) -> None:
        raw = fake_raw(samples=[0.01, 0.011])
        raw["results"][0]["samples"][1]["gcCaseBefore"]["memoryKb"] += 1
        with self.assertRaisesRegex(results.ResultError, "case-lifetime baseline"):
            results.validate_raw_result(raw, CATALOG)

    def test_memory_delta_separates_setup_timed_and_case_footprints(self) -> None:
        value = summary(
            [0.01],
            memory_case_before_kb=1,
            memory_setup_before_kb=2,
            memory_timed_before_kb=5,
            memory_after_kb=9,
            memory_retained_kb=7,
        )
        row = value["workloads"][0]
        self.assertEqual(row["memoryAfterDeltaKb"], [8])
        self.assertEqual(row["memoryRetainedDeltaKb"], [6])
        self.assertEqual(row["memorySetupDeltaKb"], [3])
        self.assertEqual(row["memoryTimedTransientDeltaKb"], [4])
        self.assertEqual(row["memoryTimedRetainedDeltaKb"], [2])

    def test_summary_validation_rejects_rewritten_statistics(self) -> None:
        value = summary([0.01, 0.011])
        value["workloads"][0]["statisticsMicros"]["median"] += 1
        with self.assertRaisesRegex(results.ResultError, "statisticsMicros"):
            results.validate_summary(value, CATALOG, BUDGETS)

    def test_summary_validation_recomputes_budget_status_and_process_clusters(self) -> None:
        value = summary([0.01] * 9)
        row = value["workloads"][0]
        self.assertEqual(len(row["processRuns"]), 3)
        self.assertEqual(
            row["samplesMicros"],
            [
                sample
                for run in row["processRuns"]
                for sample in run["samplesMicros"]
            ],
        )

        over_budget = summary([0.6] * 9)
        over_budget["status"] = "passed"
        over_budget["workloads"][0]["status"] = "passed"
        over_budget["workloads"][0]["reason"] = None
        with self.assertRaisesRegex(results.ResultError, "status/reason"):
            results.validate_summary(over_budget, CATALOG, BUDGETS)

    def test_summary_counts_batched_and_fresh_process_groups(self) -> None:
        catalog = copy.deepcopy(CATALOG)
        by_id = results.catalog_by_id(catalog)
        by_id["ledger_output_roundtrip_2k"]["requiresFreshProcess"] = True
        selected = [by_id["idle_tick"], by_id["ledger_output_roundtrip_2k"]]
        raw_runs = []
        for _ in range(2):
            raw_runs.append(fake_raw("idle_tick"))
            raw_runs.append(fake_raw("ledger_output_roundtrip_2k"))
        value = results.summarize_raw_results(
            raw_runs,
            selected,
            BUDGETS,
            profile="test",
            comparability={
                "cpuModel": "cpu",
                "cpuGovernors": ["performance"],
                "cpuAffinity": "0",
                "kernel": "test",
                "machine": "test",
                "lua": "Lua test",
                "luaExecutableSha256": FAKE_EXECUTABLE_SHA256,
                "jitAvailable": False,
                "jitEnabled": None,
                "jitVersion": None,
                "jitArchitecture": None,
                "selectedWorkloadContractSha256": "0" * 64,
                "openmwSha256": None,
                "openmwBuildId": None,
                "openmwSourceRef": None,
                "openmwBuildType": None,
                "gameData": None,
                "runParameters": {
                    "processes": 2,
                    "samplesPerProcess": 1,
                    "warmupsPerProcess": 1,
                    "memoryEvidence": True,
                },
                "nativeCampaign": None,
            },
        )
        self.assertEqual(value["rawRunCount"], 4)
        self.assertIs(value, results.validate_summary(value, catalog, BUDGETS))
        value["rawRunCount"] = 2
        with self.assertRaisesRegex(results.ResultError, "rawRunCount"):
            results.validate_summary(value, catalog, BUDGETS)

    def test_comparison_requires_matching_context_and_sample_floor(self) -> None:
        baseline = summary(
            [0.01] * 9,
            memory_case_before_kb=1,
            memory_setup_before_kb=2,
            memory_timed_before_kb=5,
            memory_after_kb=9,
            memory_retained_kb=7,
        )
        candidate = summary(
            [0.011] * 9,
            memory_case_before_kb=4,
            memory_setup_before_kb=6,
            memory_timed_before_kb=10,
            memory_after_kb=16,
            memory_retained_kb=13,
        )
        comparison = results.compare_summaries(baseline, candidate, BUDGETS, CATALOG)
        self.assertEqual(comparison["schemaVersion"], 3)
        self.assertEqual(comparison["status"], "passed")
        self.assertAlmostEqual(comparison["workloads"][0]["ratio"]["estimate"], 1.1)
        memory = comparison["workloads"][0]["memory"]
        self.assertEqual(memory["status"], "measured")
        self.assertEqual(memory["baselineTimedTransientMedianKb"], 4)
        self.assertEqual(memory["candidateTimedTransientMedianKb"], 6)
        self.assertEqual(memory["timedTransientDifferenceKb"]["estimate"], 2)
        self.assertEqual(memory["baselineTimedRetainedMedianKb"], 2)
        self.assertEqual(memory["candidateTimedRetainedMedianKb"], 3)
        self.assertEqual(memory["timedRetainedDifferenceKb"]["estimate"], 1)
        self.assertNotIn("baselineAfterMedianKb", memory)
        self.assertNotIn("baselineRetainedMedianKb", memory)

        candidate = summary([0.013] * 9)
        comparison = results.compare_summaries(baseline, candidate, BUDGETS, CATALOG)
        self.assertEqual(comparison["status"], "regression")

        comparison = results.compare_summaries(
            summary([0.01] * 3), summary([0.01] * 3), BUDGETS, CATALOG
        )
        self.assertEqual(comparison["status"], "inconclusive")

        comparison = results.compare_summaries(
            baseline, summary([0.011] * 9, cpu="other"), BUDGETS, CATALOG
        )
        self.assertEqual(comparison["status"], "not-comparable")
        self.assertIn("comparability.cpuModel", comparison["mismatches"])

        candidate = summary([0.011] * 9)
        candidate["profile"] = "other"
        comparison = results.compare_summaries(baseline, candidate, BUDGETS, CATALOG)
        self.assertEqual(comparison["status"], "not-comparable")
        self.assertIn("profile", comparison["mismatches"])

        timing_only = results.compare_summaries(
            summary([0.01] * 9, memory_evidence=False),
            summary([0.011] * 9, memory_evidence=False),
            BUDGETS,
            CATALOG,
        )
        memory = timing_only["workloads"][0]["memory"]
        self.assertEqual(memory["status"], "inconclusive")
        self.assertEqual(memory["reason"], "memory_not_captured")


if __name__ == "__main__":
    unittest.main()
