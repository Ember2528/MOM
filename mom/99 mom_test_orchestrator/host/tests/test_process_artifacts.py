from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import tempfile
import unittest

HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import artifacts
import process


class ProcessAndArtifactTests(unittest.TestCase):
    def process_record(self) -> dict:
        return {
            "command": ["/bin/true"],
            "cwd": "/tmp",
            "startedAtUtc": "2026-01-01T00:00:00Z",
            "durationSeconds": 0.01,
            "returnCode": 0,
            "timedOut": False,
            "cpuAffinity": {
                "requested": None,
                "effective": "0-3",
                "scope": "process_group",
            },
        }

    def test_cpu_set_round_trip(self) -> None:
        self.assertEqual(process.parse_cpu_set("0-2,5,7-8"), {0, 1, 2, 5, 7, 8})
        self.assertEqual(process.format_cpu_set({0, 1, 2, 5, 7, 8}), "0-2,5,7-8")
        with self.assertRaises(process.ProcessError):
            process.parse_cpu_set("2-1")

    def test_timeout_terminates_process_group(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            record = process.run_process(
                [sys.executable, "-c", "import time; time.sleep(10)"],
                cwd=root,
                environment=dict(os.environ),
                stdout_path=root / "stdout",
                stderr_path=root / "stderr",
                timeout_seconds=0.05,
            )
            self.assertTrue(record["timedOut"])
            self.assertNotEqual(record["returnCode"], 0)

    def test_process_output_can_share_one_log(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output = root / "combined.log"
            record = process.run_process(
                [
                    sys.executable,
                    "-c",
                    "import sys; print('stdout'); print('stderr', file=sys.stderr)",
                ],
                cwd=root,
                environment=dict(os.environ),
                stdout_path=output,
                stderr_path=None,
                timeout_seconds=5,
            )

            self.assertEqual(record["returnCode"], 0)
            self.assertEqual(set(output.read_text(encoding="utf-8").splitlines()), {
                "stdout",
                "stderr",
            })

    def test_artifact_finalization_is_content_addressed(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repository = base / "repository"
            repository.mkdir()
            run = artifacts.ArtifactRun(base / "artifacts", repository)
            specification_id = run.write_specification({"schemaVersion": 1, "value": "spec"})
            artifacts.write_json(run.staging / "results" / "summary.json", {
                "kind": "mom.performance.summary",
                "status": "passed",
            })
            destination = run.finalize({
                "status": "passed",
                "startedAtUtc": "2026-01-01T00:00:00Z",
                "finishedAtUtc": "2026-01-01T00:00:01Z",
                "processes": [self.process_record()],
                "preparationProcesses": [],
                "nativeCaptures": [],
            })
            receipt = json.loads((destination / "run.json").read_text(encoding="utf-8"))
            self.assertEqual(receipt["runId"], destination.name)
            self.assertEqual(receipt["specificationId"], specification_id)
            self.assertFalse(any(base.glob("artifacts/.staging-*")))
            self.assertEqual(
                artifacts.validate_run_directory(destination)["runId"],
                destination.name,
            )

            with (destination / "results" / "summary.json").open(
                "a", encoding="utf-8"
            ) as stream:
                stream.write(" ")
            with self.assertRaisesRegex(artifacts.ArtifactError, "manifest"):
                artifacts.validate_run_directory(destination)

            with self.assertRaises(artifacts.ArtifactError):
                artifacts.ArtifactRun(repository / "nested", repository)

    def test_failed_artifact_can_retain_failed_preparation_process(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repository = base / "repository"
            repository.mkdir()
            run = artifacts.ArtifactRun(base / "artifacts", repository)
            run.write_specification({"schemaVersion": 1, "value": "spec"})
            failed_preparation = self.process_record()
            failed_preparation["returnCode"] = 2
            destination = run.finalize({
                "status": "failed",
                "startedAtUtc": "2026-01-01T00:00:00Z",
                "finishedAtUtc": "2026-01-01T00:00:01Z",
                "error": {"type": "FixtureError", "message": "prepare failed"},
                "processes": [],
                "preparationProcesses": [failed_preparation],
                "nativeCaptures": [],
            })
            self.assertEqual(
                artifacts.validate_run_directory(destination)["status"],
                "failed",
            )

    def test_identical_payloads_share_one_canonical_object(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repository = base / "repository"
            repository.mkdir()
            run = artifacts.ArtifactRun(base / "artifacts", repository)
            run.write_specification({"schemaVersion": 1, "value": "spec"})
            payload = b"identical retained evidence\n"
            first = run.staging / "config" / "run-000" / "openmw.cfg"
            second = run.staging / "config" / "run-001" / "openmw.cfg"
            first.parent.mkdir(parents=True)
            second.parent.mkdir(parents=True)
            first.write_bytes(payload)
            second.write_bytes(payload)
            artifacts.write_json(
                run.staging / "results" / "summary.json",
                {"kind": "mom.performance.summary", "status": "passed"},
            )
            destination = run.finalize({
                "status": "passed",
                "startedAtUtc": "2026-01-01T00:00:00Z",
                "finishedAtUtc": "2026-01-01T00:00:01Z",
                "processes": [self.process_record()],
                "preparationProcesses": [],
                "nativeCaptures": [],
            })
            receipt = artifacts.validate_run_directory(destination)
            config_entries = [
                entry
                for entry in receipt["artifacts"]
                if entry["path"].endswith("openmw.cfg")
            ]
            self.assertEqual(len(config_entries), 2)
            self.assertEqual(
                {entry["object"] for entry in config_entries},
                {config_entries[0]["object"]},
            )
            self.assertFalse(
                (destination / config_entries[0]["path"]).exists()
            )
            objects = [
                path
                for path in (base / "artifacts" / "objects").rglob("*")
                if path.is_file()
            ]
            self.assertEqual(len(objects), 1)
            self.assertEqual(objects[0].read_bytes(), payload)

            objects[0].write_bytes(b"corrupt")
            with self.assertRaisesRegex(
                artifacts.ArtifactError,
                "canonical object",
            ):
                artifacts.validate_run_directory(destination)

    def test_artifact_finalization_rejects_invalid_process_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repository = base / "repository"
            repository.mkdir()
            run = artifacts.ArtifactRun(base / "artifacts", repository)
            run.write_specification({"schemaVersion": 1, "value": "spec"})
            failed_process = self.process_record()
            failed_process["returnCode"] = 7
            with self.assertRaisesRegex(
                artifacts.ArtifactError,
                "completed run record contains an unsuccessful process",
            ):
                run.finalize({
                    "status": "passed",
                    "startedAtUtc": "2026-01-01T00:00:00Z",
                    "finishedAtUtc": "2026-01-01T00:00:01Z",
                    "processes": [failed_process],
                    "preparationProcesses": [],
                    "nativeCaptures": [],
                })


if __name__ == "__main__":
    unittest.main()
