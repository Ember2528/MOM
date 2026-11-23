from __future__ import annotations

import argparse
from contextlib import nullcontext, redirect_stdout
import io
import os
import signal
from pathlib import Path
import sys
import subprocess
import tempfile
import unittest
from unittest.mock import patch


HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import artifacts
import process_campaigns
import validation


class ValidationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        (self.root / "global.cfg").write_text("# fixture\n", encoding="utf-8")
        parser = argparse.ArgumentParser()
        validation.configure_parser(parser)
        self.arguments = parser.parse_args([
            "--luajit-openmw", str(self.root / "jit/openmw"),
            "--luau-openmw", str(self.root / "luau/openmw"),
            "--global-config", str(self.root / "global.cfg"),
            "--lua", sys.executable,
            "--workdir", str(self.root / "check"), "--timeout", "1.5",
        ])
        self.commands: list[list[str]] = []
        self.catalog = validation.scenario_inventory.ScenarioCatalog(
            {}, {"all": ["one", "two"], "smoke": ["one"]}, {"one": [], "two": []}, [],
        )
        self.identity = patch.object(validation.openmw, "binary_identity", side_effect=lambda path: {
            "path": str(path), "sha256": ("a" if Path(path).parent.name == "jit" else "b") * 64,
            "size": 1, "version": "OpenMW", "buildId": None,
        })
        self.identity.start()
        self.addCleanup(self.identity.stop)
        for patcher in (
            patch.object(validation.scenario_inventory, "load_catalog", return_value=self.catalog),
            patch.object(validation.process, "VirtualDisplay", return_value=nullcontext(":123")),
            patch.object(validation.process_campaigns, "validate_campaign_artifacts",
                         side_effect=process_campaigns.validate_campaign_result),
        ):
            patcher.start()
            self.addCleanup(patcher.stop)

    def fake_process(self, command: list[str], **options: object) -> dict[str, object]:
        self.commands.append(command)
        if "process_campaigns.py" in command[1]:
            self.assertIsNone(options["timeout_seconds"])
        else:
            self.assertEqual(options["timeout_seconds"], self.arguments.timeout)
        stdout = options["stdout_path"]
        assert isinstance(stdout, Path)
        stdout.parent.mkdir(parents=True, exist_ok=True)
        stdout.write_text("MOM pure contract tests passed: 815 case(s)\n", encoding="utf-8")
        if "--openmw" in command:
            assert options["environment"]["DISPLAY"] == ":123"
        run = Path(command[command.index("--workdir") + 1]) if "--workdir" in command else None
        if "--openmw" in command and "standalone.py" in command[1]:
            (run / "config").mkdir(parents=True)
            runtime = "Lua 5.1" if "/jit/" in command[command.index("--openmw") + 1] else "Luau"
            (run / "config/openmw.log").write_text(
                f"prefix MOM pure runtime: {runtime}\n"
                "prefix MOM pure contract tests passed: 815 case(s)\n"
                "prefix MOM_PURE_RESULT:passed\n", encoding="utf-8",
            )
        elif "process_campaigns.py" in command[1]:
            run.mkdir(parents=True)
            selected = [command[i + 1] for i, value in enumerate(command) if value == "--campaign"]
            campaigns = ([process_campaigns.CAMPAIGN_BY_ID[item] for item in selected]
                         if selected else process_campaigns.CAMPAIGNS)
            artifacts.write_json(run / "result.json", {
                "schemaVersion": 2, "kind": "mom.process-campaign.result", "status": "passed",
                "workdir": str(run), "campaigns": [
                    {"id": campaign.id, "status": "passed", "phases": [
                        f"{campaign.id}/{phase.id}.json" for phase in campaign.phases
                    ]} for campaign in campaigns
                ],
            })
        elif "--result-file" in command:
            run.mkdir(parents=True)
            selected = [command[i + 1] for i, value in enumerate(command) if value == "--scenario"]
            artifacts.write_json(run / "result.json", {
                "schemaVersion": 1, "kind": "mom.correctness.result", "status": "passed",
                "passed": len(selected), "failed": 0, "total": len(selected), "openmwStatus": 0,
                "scenarios": selected, "scenarioResults": [
                    {"id": name, "status": "passed", "frames": 1} for name in selected
                ], "workdir": str(run), "log": str(run / "openmw.log"),
            })
        return {"command": command, "returnCode": 0, "timedOut": False}

    def result(self) -> dict[str, object]:
        return artifacts.load_json(self.arguments.workdir / "result.json")

    def test_engine_identity_fixture_ignores_ancestor_names(self) -> None:
        ancestor = self.root / "jit-containing-parent"
        luau = validation.openmw.binary_identity(ancestor / "luau/openmw")
        luajit = validation.openmw.binary_identity(ancestor / "jit/openmw")
        self.assertEqual(luau["sha256"], "b" * 64)
        self.assertEqual(luajit["sha256"], "a" * 64)

    def test_complete_matrix_uses_explicit_engines_and_validates_receipts(self) -> None:
        with patch.object(validation.process, "run_process", side_effect=self.fake_process), \
                patch.dict(os.environ, {"MOM_HARNESS_BUILD_OPENMW": "1"}):
            self.assertEqual(validation.run(self.arguments), 0)
        result = self.result()
        self.assertEqual(result["status"], "passed")
        self.assertEqual(len(result["checks"]), 10)
        self.assertEqual(set(result["engines"]), {"luajit", "luau"})
        self.assertEqual([row["cases"] for row in result["checks"] if "cases" in row], [815] * 6)
        for command in self.commands:
            if "--openmw" in command and "standalone.py" not in command[1]:
                self.assertIn("--no-build-openmw", command)
                self.assertNotIn("--build-openmw", command)
            if "process_campaigns.py" in command[1]:
                self.assertEqual(command[command.index("--phase-timeout") + 1], "2")
        native_workdirs = [command[command.index("--workdir") + 1]
                           for command in self.commands if "--workdir" in command]
        self.assertEqual(len(native_workdirs), len(set(native_workdirs)))

    def test_quick_runs_luau_smoke_and_restart_with_explicit_coverage(self) -> None:
        parser = argparse.ArgumentParser()
        validation.configure_quick_parser(parser)
        args = parser.parse_args([
            "--luau-openmw", str(self.root / "luau/openmw"), "--lua", sys.executable,
            "--global-config", str(self.root / "global.cfg"),
            "--workdir", str(self.root / "quick"), "--timeout", "1.5",
        ])
        output = io.StringIO()
        with (patch.object(validation.process, "run_process", side_effect=self.fake_process),
              redirect_stdout(output)):
            self.assertEqual(validation.run_quick(args), 0)
        self.assertIn('Quick check: passed', output.getvalue())
        result = artifacts.load_json(args.workdir / "result.json")
        self.assertEqual([row['id'] for row in result['checks']],
            ['luau/pure-normal', 'luau/correctness', 'luau/campaigns'])
        self.assertEqual(result['coverage'], {'profile': 'quick', 'runtimes': ['luau'],
            'pure': 'normal', 'scenarios': ['one'], 'campaigns': ['nested_attach_restart']})
        self.assertEqual(set(result['engines']), {'luau'})

    def test_quick_rejects_unknown_campaign_before_any_work(self) -> None:
        parser = argparse.ArgumentParser()
        validation.configure_quick_parser(parser)
        args = parser.parse_args(['--luau-openmw', str(self.root / 'luau/openmw'),
            '--lua', sys.executable, '--global-config', str(self.root / 'global.cfg'),
            '--workdir', str(self.root / 'quick'), '--campaign', 'unknown'])
        with self.assertRaisesRegex(validation.ValidationError, 'known and unique'):
            validation.run_quick(args)
        self.assertFalse(args.workdir.exists())

    def test_quick_accepts_targeted_scenarios_and_campaigns(self) -> None:
        parser = argparse.ArgumentParser()
        validation.configure_quick_parser(parser)
        args = parser.parse_args(['--luau-openmw', str(self.root / 'luau/openmw'),
            '--lua', sys.executable, '--global-config', str(self.root / 'global.cfg'),
            '--workdir', str(self.root / 'quick'), '--timeout', '1.5',
            '--scenario', 'two', '--campaign', 'provider_unavailable_restart',
            '--campaign', 'nested_attach_restart'])
        with patch.object(validation.process, 'run_process', side_effect=self.fake_process):
            self.assertEqual(validation.run_quick(args), 0)
        coverage = artifacts.load_json(args.workdir / 'result.json')['coverage']
        self.assertEqual(coverage['scenarios'], ['two'])
        self.assertEqual(coverage['campaigns'], ['provider_unavailable_restart', 'nested_attach_restart'])

    def test_quick_fails_if_a_selected_campaign_is_missing(self) -> None:
        parser = argparse.ArgumentParser()
        validation.configure_quick_parser(parser)
        args = parser.parse_args(['--luau-openmw', str(self.root / 'luau/openmw'),
            '--lua', sys.executable, '--global-config', str(self.root / 'global.cfg'),
            '--workdir', str(self.root / 'quick'), '--timeout', '1.5'])
        def incomplete(command: list[str], **options: object) -> dict[str, object]:
            record = self.fake_process(command, **options)
            if 'process_campaigns.py' in command[1]:
                path = Path(command[command.index('--workdir') + 1]) / 'result.json'
                result = artifacts.load_json(path)
                result['campaigns'] = []
                artifacts.write_json(path, result)
            return record
        with patch.object(validation.process, 'run_process', side_effect=incomplete):
            self.assertEqual(validation.run_quick(args), 1)
        self.assertIn('complete campaign selection',
            artifacts.load_json(args.workdir / 'result.json')['checks'][-1]['error'])

    def test_process_failure_does_not_skip_other_runtime_checks(self) -> None:
        def fail_first(command: list[str], **options: object) -> dict[str, object]:
            record = self.fake_process(command, **options)
            if len(self.commands) == 1:
                record["returnCode"] = 3
            return record
        with patch.object(validation.process, "run_process", side_effect=fail_first):
            self.assertEqual(validation.run(self.arguments), 1)
        checks = self.result()["checks"]
        self.assertEqual(len(checks), 10)
        self.assertIn("status 3", checks[0]["error"])
        self.assertEqual(checks[-1]["status"], "passed")

    def test_progress_is_saved_before_each_check_starts(self) -> None:
        def inspect_progress(command: list[str], **options: object) -> dict[str, object]:
            result = self.result()
            self.assertEqual(result["status"], "running")
            self.assertEqual(len(result["checks"]), len(self.commands) + 1)
            self.assertEqual(result["checks"][-1]["status"], "running")
            self.assertTrue(all(row["status"] == "passed" for row in result["checks"][:-1]))
            return self.fake_process(command, **options)
        with patch.object(validation.process, "run_process", side_effect=inspect_progress):
            self.assertEqual(validation.run(self.arguments), 0)
        self.assertEqual(self.result()["status"], "passed")

    def test_interruption_saves_completed_and_active_checks(self) -> None:
        write_json = validation.artifacts.write_json

        def save_with_repeated_signals(path: Path, value: dict[str, object]) -> None:
            if value.get("status") == "cancelled":
                self.assertEqual(signal.getsignal(signal.SIGINT), signal.SIG_IGN)
                self.assertEqual(signal.getsignal(signal.SIGTERM), signal.SIG_IGN)
                os.kill(os.getpid(), signal.SIGINT)
                os.kill(os.getpid(), signal.SIGTERM)
            write_json(path, value)

        def interrupt_second(command: list[str], **options: object) -> dict[str, object]:
            if self.commands:
                raise KeyboardInterrupt("fixture interrupted")
            return self.fake_process(command, **options)
        with (patch.object(validation.process, "run_process", side_effect=interrupt_second),
              patch.object(validation.artifacts, "write_json", side_effect=save_with_repeated_signals)):
            with self.assertRaisesRegex(KeyboardInterrupt, "fixture interrupted"):
                validation.run(self.arguments)
        result = self.result()
        self.assertEqual(result["schemaVersion"], 2)
        self.assertEqual(result["status"], "cancelled")
        self.assertEqual(result["error"], "fixture interrupted")
        self.assertEqual(set(result["engines"]), {"luajit", "luau"})
        self.assertEqual([row["status"] for row in result["checks"]], ["passed", "cancelled"])
        self.assertEqual(result["checks"][0]["cases"], 815)
        self.assertIn("stdout", result["checks"][1])

    def test_unexpected_failure_saves_available_process_evidence(self) -> None:
        verify = validation._verify_result

        def fail_second(*args: object, **kwargs: object) -> dict[str, object]:
            if len(self.commands) == 2:
                raise RuntimeError("fixture verification failed")
            return verify(*args, **kwargs)

        with (patch.object(validation.process, "run_process", side_effect=self.fake_process),
              patch.object(validation, "_verify_result", side_effect=fail_second)):
            with self.assertRaisesRegex(RuntimeError, "fixture verification failed"):
                validation.run(self.arguments)
        result = self.result()
        self.assertEqual(result["status"], "failed")
        self.assertEqual([row["status"] for row in result["checks"]], ["passed", "failed"])
        self.assertEqual(result["checks"][1]["process"]["returnCode"], 0)
        self.assertEqual(result["checks"][1]["error"], "fixture verification failed")

    def test_timeout_with_success_exit_is_still_a_failure(self) -> None:
        def timed_out(command: list[str], **options: object) -> dict[str, object]:
            record = self.fake_process(command, **options)
            if len(self.commands) == 1:
                record["timedOut"] = True
            return record
        with patch.object(validation.process, "run_process", side_effect=timed_out):
            self.assertEqual(validation.run(self.arguments), 1)
        self.assertEqual(self.result()["checks"][0]["error"], "process timed out")

    def test_native_runtime_mismatch_cannot_claim_a_second_runtime(self) -> None:
        def wrong_runtime(command: list[str], **options: object) -> dict[str, object]:
            record = self.fake_process(command, **options)
            if "--openmw" in command and "standalone.py" in command[1]:
                path = Path(command[command.index("--workdir") + 1]) / "config/openmw.log"
                path.write_text(path.read_text().replace("runtime: Luau", "runtime: Lua 5.1"))
            return record
        with patch.object(validation.process, "run_process", side_effect=wrong_runtime):
            self.assertEqual(validation.run(self.arguments), 1)
        self.assertIn("expected native luau", self.result()["checks"][6]["error"])

    def test_zero_exit_does_not_accept_incomplete_correctness_selection(self) -> None:
        def incomplete(command: list[str], **options: object) -> dict[str, object]:
            record = self.fake_process(command, **options)
            if "--result-file" in command:
                path = Path(command[command.index("--result-file") + 1])
                result = artifacts.load_json(path)
                result.update(passed=1, total=1, scenarios=["one"],
                              scenarioResults=result["scenarioResults"][:1])
                artifacts.write_json(path, result)
            return record
        with patch.object(validation.process, "run_process", side_effect=incomplete):
            self.assertEqual(validation.run(self.arguments), 1)
        self.assertIn("complete scenario selection", self.result()["checks"][4]["error"])

    def test_zero_exit_does_not_accept_incomplete_campaign_selection(self) -> None:
        def incomplete(command: list[str], **options: object) -> dict[str, object]:
            record = self.fake_process(command, **options)
            if "process_campaigns.py" in command[1]:
                path = Path(command[command.index("--workdir") + 1]) / "result.json"
                result = artifacts.load_json(path)
                result["campaigns"] = result["campaigns"][:1]
                artifacts.write_json(path, result)
            return record
        with patch.object(validation.process, "run_process", side_effect=incomplete):
            self.assertEqual(validation.run(self.arguments), 1)
        self.assertIn("complete campaign selection", self.result()["checks"][5]["error"])

    def test_duplicate_binaries_are_rejected_before_starting_runs(self) -> None:
        self.arguments.luau_openmw = self.arguments.luajit_openmw
        with self.assertRaisesRegex(validation.ValidationError, "different OpenMW"):
            validation.run(self.arguments)
        self.assertFalse(self.arguments.workdir.exists())

    def test_preflight_failures_are_command_errors(self) -> None:
        with patch.object(validation.openmw, "binary_identity", side_effect=FileNotFoundError("missing engine")):
            with self.assertRaisesRegex(validation.ValidationError, "missing engine"):
                validation.run(self.arguments)
        self.arguments.workdir = Path("/tmp")
        with self.assertRaisesRegex(validation.ValidationError, "unsafe workdir"):
            validation.run(self.arguments)

    def test_relative_inputs_are_resolved_before_child_working_directory_changes(self) -> None:
        executable = self.root / "lua"
        executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
        executable.chmod(0o755)
        self.arguments.lua = "./lua"
        self.arguments.global_config = Path("global.cfg")
        original = Path.cwd()
        try:
            os.chdir(self.root)
            with patch.object(validation.process, "run_process", side_effect=self.fake_process):
                self.assertEqual(validation.run(self.arguments), 0)
        finally:
            os.chdir(original)
        for command in self.commands:
            if "--lua" in command:
                self.assertEqual(command[command.index("--lua") + 1], str(executable))
            if "--global-config" in command:
                self.assertEqual(command[command.index("--global-config") + 1], str(self.root / "global.cfg"))

    def test_display_failure_starts_no_checks(self) -> None:
        with (patch.object(validation.process, "VirtualDisplay", side_effect=validation.process.ProcessError("no display")),
              patch.object(validation.process, "run_process") as run):
            with self.assertRaisesRegex(validation.process.ProcessError, "no display"):
                validation.run(self.arguments)
            run.assert_not_called()
        self.assertEqual(self.result()["status"], "failed")
        self.assertEqual(self.result()["checks"], [])

    def test_missing_engine_cli_has_no_traceback(self) -> None:
        completed = subprocess.run([
            sys.executable, str(HOST_ROOT / "mom_harness.py"), "check",
            "--luajit-openmw", str(self.root / "missing-engine"),
            "--luau-openmw", str(self.root / "missing-luau-engine"),
        ], capture_output=True, text=True, check=False, timeout=10)
        self.assertEqual(completed.returncode, 2)
        self.assertIn("ERROR:", completed.stderr)
        self.assertNotIn("Traceback", completed.stderr)

    def test_pure_summary_requires_positive_unique_completion(self) -> None:
        for log in ("", "MOM pure contract tests passed: 0 case(s)",
                    "MOM pure contract tests passed: 1 case(s)\n" * 2):
            with self.subTest(log=log), self.assertRaises(validation.ValidationError):
                validation._pure_cases(log)


if __name__ == "__main__":
    unittest.main()
