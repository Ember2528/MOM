from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import correctness
import launch


def log_line(message: str) -> str:
    return f"[00:00:00 I] Global[test.lua]:\t{message}\n"


def result_value(**changes: object) -> dict:
    value = {
        "schemaVersion": 1,
        "kind": "mom.correctness.result",
        "status": "passed",
        "passed": 0,
        "failed": 0,
        "total": 0,
        "openmwStatus": 0,
        "scenarios": [],
        "scenarioResults": [],
        "log": "/tmp/openmw.log",
        "workdir": "/tmp/work",
    }
    value.update(changes)
    return value


class CorrectnessTests(unittest.TestCase):
    def test_elapsed_time_captures_work_without_frames(self) -> None:
        receipt = {"id": "synchronous", "status": "passed", "frames": 0,
                   "elapsedSeconds": 0.75}
        lines = [log_line(correctness.MACHINE_RESULT_MARKER + json.dumps(receipt))]
        self.assertEqual(correctness.parse_scenario_receipts(lines), [receipt])
        value = result_value(elapsedSeconds=1.25)
        self.assertEqual(correctness.validate_result(value)["elapsedSeconds"], 1.25)
        for invalid in (-1, float("inf"), float("nan"), True, "1.5"):
            with self.assertRaises(correctness.CorrectnessError):
                correctness.validate_result(result_value(elapsedSeconds=invalid))
            with self.assertRaises(correctness.CorrectnessError):
                correctness.parse_scenario_receipts([
                    log_line(correctness.MACHINE_RESULT_MARKER
                             + json.dumps(dict(receipt, elapsedSeconds=invalid)))])

    def test_result_loader_rejects_ambiguous_or_invalid_results(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "result.json"
            valid = json.dumps(result_value(), separators=(",", ":"))
            path.write_text(
                valid.replace(
                    '"status":"passed"',
                    '"status":"passed","status":"failed"',
                    1,
                ),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(correctness.CorrectnessError, "duplicate"):
                correctness.load_result(path)

            path.write_text(
                json.dumps(result_value(openmwStatus=True)),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(correctness.CorrectnessError, "integer"):
                correctness.load_result(path)

            path.write_text(json.dumps(result_value()), encoding="utf-8")
            self.assertEqual(correctness.load_result(path)["status"], "passed")

    def test_launch_spec_is_strict_json_with_one_performance_lane(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "launch.json"
            launch.write_launch_spec(
                output=output,
                performance_lane="embedded",
                command=["/tmp/openmw", "--config", "/tmp/config"],
                openmw_binary="/tmp/openmw",
                harness_owned_build=True,
                source_ref="abc",
                build_type="RelWithDebInfo",
                work_directory=root,
                config=root / "openmw.cfg",
                settings=root / "settings.cfg",
                run_options=root / "run_options.lua",
                log=root / "openmw.log",
                result=root / "result.json",
            )

            text = output.read_text(encoding="utf-8")
            value = json.loads(
                text,
                object_pairs_hook=correctness._strict_object,
            )
            self.assertEqual(text.count('"performanceLane"'), 1)
            self.assertEqual(value["command"][1:], ["--config", "/tmp/config"])
            self.assertTrue(value["openmw"]["harnessOwnedBuild"])
            self.assertIs(value, launch.validate_launch_spec(value))

    def test_machine_receipts_and_summary_form_a_passing_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "openmw.log"
            log.write_text(
                log_line(
                    '[MOMTestOrchestrator][INFO] SCENARIO_RESULT '
                    '{"id":"first","status":"passed","frames":12}'
                )
                + log_line(
                    '[MOMTestOrchestrator][INFO] SCENARIO_RESULT '
                    '{"id":"second","status":"failed","frames":9,"error":"nope"}'
                )
                + log_line(
                    "[MOMTestOrchestrator][INFO] RESULT "
                    "status=failed passed=1 failed=1 total=2"
                ),
                encoding="utf-8",
            )

            result = correctness.build_result(
                log_path=log,
                work_directory=root,
                selected_scenarios=["second", "first"],
                openmw_status=0,
            )

            self.assertEqual(result["status"], "failed")
            self.assertEqual(result["scenarioResults"][1]["error"], "nope")
            self.assertEqual((result["passed"], result["failed"], result["total"]), (1, 1, 2))

    def test_human_lines_are_not_machine_correctness_evidence(self) -> None:
        lines = [
            log_line("[MOMTestOrchestrator][INFO] Scenario passed: first (12 frames)").strip(),
            log_line(
                "[MOMTestOrchestrator][ERROR] "
                "Scenario FAILED: second (9 frames): expected value"
            ).strip(),
        ]

        self.assertEqual(correctness.parse_scenario_receipts(lines), [])

    def test_multiple_machine_summaries_are_rejected(self) -> None:
        lines = [
            log_line(
                "[MOMTestOrchestrator][INFO] RESULT "
                "status=passed passed=1 failed=0 total=1"
            ).strip(),
            log_line(
                "[MOMTestOrchestrator][INFO] RESULT "
                "status=passed passed=1 failed=0 total=1"
            ).strip(),
        ]
        with self.assertRaisesRegex(correctness.CorrectnessError, "multiple"):
            correctness.parse_summary(lines)

    def test_missing_summary_is_reported(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "openmw.log"
            log.write_text("OpenMW started\n", encoding="utf-8")

            result = correctness.build_result(
                log_path=log,
                work_directory=root,
                selected_scenarios=[],
                openmw_status=0,
            )

            self.assertEqual(result["status"], "missing")
            self.assertIsNone(result["total"])

    def test_campaign_save_receipt_is_a_dedicated_passing_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "openmw.log"
            log.write_text(
                log_line(
                    '[MOMCampaign][PHASE_RECEIPT] '
                    '{"event":"save_complete",'
                    '"kind":"mom.process-campaign.engine-phase",'
                    '"scenario":"campaign_setup","schemaVersion":1,'
                    '"status":"passed"}'
                ),
                encoding="utf-8",
            )
            result = correctness.build_result(
                log_path=log,
                work_directory=root,
                selected_scenarios=["campaign_setup"],
                openmw_status=0,
            )
            self.assertEqual(
                result["kind"],
                "mom.process-campaign.phase-receipt",
            )
            self.assertEqual(result["status"], "passed")
            self.assertEqual(
                result["engineReceipt"]["event"],
                "save_complete",
            )

            path = root / "result.json"
            path.write_text(json.dumps(result), encoding="utf-8")
            self.assertEqual(
                correctness.load_result(path)["scenario"],
                "campaign_setup",
            )

    def test_campaign_save_receipt_rejects_duplicates_and_mismatch(self) -> None:
        receipt = log_line(
            '[MOMCampaign][PHASE_RECEIPT] '
            '{"event":"save_complete",'
            '"kind":"mom.process-campaign.engine-phase",'
            '"scenario":"campaign_setup","schemaVersion":1,'
            '"status":"passed"}'
        )
        with self.assertRaisesRegex(
            correctness.CorrectnessError,
            "multiple",
        ):
            correctness.parse_campaign_phase_receipt(
                (receipt + receipt).splitlines()
            )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "openmw.log"
            log.write_text(receipt, encoding="utf-8")
            result = correctness.build_result(
                log_path=log,
                work_directory=root,
                selected_scenarios=["campaign_other"],
                openmw_status=0,
            )
            self.assertEqual(result["status"], "invalid")

    def test_failed_openmw_process_takes_precedence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = correctness.build_result(
                log_path=root / "missing.log",
                work_directory=root,
                selected_scenarios=["first"],
                openmw_status=23,
            )

            self.assertEqual(result["status"], "openmw_failed")
            self.assertEqual(result["openmwStatus"], 23)

    def test_invalid_machine_receipt_is_not_embedded_in_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            log = root / "openmw.log"
            log.write_text(
                log_line(
                    '[MOMTestOrchestrator][INFO] SCENARIO_RESULT '
                    '{"id":"first","id":"other","status":"passed","frames":12}'
                )
                + log_line(
                    "[MOMTestOrchestrator][INFO] RESULT "
                    "status=passed passed=1 failed=0 total=1"
                ),
                encoding="utf-8",
            )

            result = correctness.build_result(
                log_path=log,
                work_directory=root,
                selected_scenarios=["first"],
                openmw_status=0,
            )

            self.assertEqual(result["status"], "invalid")
            self.assertEqual(result["scenarioResults"], [])


if __name__ == "__main__":
    unittest.main()
