from __future__ import annotations

import argparse
from contextlib import ExitStack, nullcontext
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch


HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import artifacts
import validation


PURE_IDS = ["standalone/normal", "standalone/stress", "luajit/pure-normal",
            "luajit/pure-stress", "luau/pure-normal", "luau/pure-stress"]


class PureCountParityTests(unittest.TestCase):
    def run_matrix(
        self, counts: list[int], *, fail_first: bool = False,
    ) -> tuple[int, dict[str, object], list[list[str]]]:
        with tempfile.TemporaryDirectory() as temporary, ExitStack() as stack:
            root = Path(temporary)
            global_config = root / "global.cfg"
            global_config.write_text("# fixture\n", encoding="utf-8")
            parser = argparse.ArgumentParser()
            validation.configure_parser(parser)
            arguments = parser.parse_args([
                "--luajit-openmw", str(root / "jit/openmw"),
                "--luau-openmw", str(root / "luau/openmw"),
                "--global-config", str(global_config), "--lua", sys.executable,
                "--workdir", str(root / "check"),
            ])
            commands: list[list[str]] = []

            def run_process(command: list[str], **options: object) -> dict[str, object]:
                commands.append(command)
                return {"returnCode": 3 if fail_first and len(commands) == 1 else 0,
                        "timedOut": False}

            cases = iter(counts)

            def verify_result(kind: str, **options: object) -> dict[str, object]:
                return {"cases": next(cases)} if kind == "pure" else {}

            catalog = validation.scenario_inventory.ScenarioCatalog(
                {}, {"all": ["one"]}, {"one": []}, [],
            )
            stack.enter_context(patch.object(validation.openmw, "binary_identity", side_effect=lambda path: {
                "path": str(path), "sha256": ("a" if Path(path).parent.name == "jit" else "b") * 64,
                "size": 1, "version": "OpenMW", "buildId": None,
            }))
            stack.enter_context(patch.object(validation.scenario_inventory, "load_catalog", return_value=catalog))
            stack.enter_context(patch.object(validation.process, "VirtualDisplay", return_value=nullcontext(":123")))
            stack.enter_context(patch.object(validation.process, "run_process", side_effect=run_process))
            stack.enter_context(patch.object(validation, "_verify_result", side_effect=verify_result))
            status = validation.run(arguments)
            result = artifacts.load_json(arguments.workdir / "result.json")
            return status, result, commands

    def test_equal_counts_pass_without_fixing_suite_size(self) -> None:
        for count in (1, 815, 1200):
            with self.subTest(count=count):
                status, result, commands = self.run_matrix([count] * 6)
                self.assertEqual(status, 0)
                self.assertEqual(result["status"], "passed")
                self.assertEqual(len(commands), 10)
                self.assertEqual([row["cases"] for row in result["checks"] if "cases" in row],
                                 [count] * 6)

    def test_distinct_normal_and_stress_counts_pass(self) -> None:
        counts = [815, 4, 815, 4, 815, 4]
        status, result, commands = self.run_matrix(counts)
        self.assertEqual(status, 0)
        pure = [row for row in result["checks"] if "cases" in row]
        self.assertEqual([row["cases"] for row in pure], counts)
        self.assertEqual([row["profile"] for row in pure], ["normal", "stress"] * 3)
        stress_commands = [command for command in commands if "--stress-only" in command]
        self.assertEqual(len(stress_commands), 3)
        self.assertFalse(any("--stress" in command for command in commands))

    def test_different_count_in_either_profile_fails_and_retains_evidence(self) -> None:
        for index, identifier in enumerate(PURE_IDS):
            with self.subTest(identifier=identifier):
                counts = [815, 4, 815, 4, 815, 4]
                counts[index] += 1
                status, result, commands = self.run_matrix(counts)
                self.assertEqual(status, 1)
                self.assertEqual(result["status"], "failed")
                self.assertEqual(len(commands), 10)
                pure = [row for row in result["checks"] if "cases" in row]
                self.assertEqual([row["id"] for row in pure], PURE_IDS)
                self.assertEqual([row["cases"] for row in pure], counts)
                for group in (pure[::2], pure[1::2]):
                    baseline = group[0]
                    self.assertEqual(baseline["status"], "passed")
                    for row in group[1:]:
                        if row["cases"] == baseline["cases"]:
                            self.assertEqual(row["status"], "passed")
                        else:
                            self.assertEqual(row["status"], "failed")
                            self.assertIn(f"expected {baseline['cases']} from {baseline['id']}", row["error"])
                            self.assertIn(f"observed {row['cases']} in {row['id']}", row["error"])
                            self.assertEqual(row["process"]["returnCode"], 0)

    def test_process_failure_does_not_supply_a_count_baseline(self) -> None:
        status, result, commands = self.run_matrix([1200] * 5, fail_first=True)
        self.assertEqual(status, 1)
        self.assertEqual(len(commands), 10)
        first, *remaining = result["checks"]
        self.assertNotIn("cases", first)
        self.assertIn("status 3", first["error"])
        self.assertTrue(all(row["status"] == "passed" for row in remaining))
        self.assertEqual([row["cases"] for row in remaining if "cases" in row], [1200] * 5)

    def test_running_row_cannot_be_its_own_count_baseline(self) -> None:
        previous = {"id": "standalone/normal", "status": "passed", "cases": 815}
        row = {"id": "luajit/pure-normal", "status": "running", "cases": 1}
        with self.assertRaisesRegex(validation.ValidationError,
                                    "expected 815 from standalone/normal; observed 1 in luajit/pure-normal"):
            validation._verify_pure_count([previous, row], row)


if __name__ == "__main__":
    unittest.main()
