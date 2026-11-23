from __future__ import annotations

from copy import deepcopy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import launch
import openmw


class EngineIdentityTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.binary = self.root / "old-cache-name" / "openmw"
        self.binary.parent.mkdir()
        self.binary.write_bytes(b"fixture executable\n")
        self.binary.chmod(0o755)
        self.metadata_path = self.binary.parent / "mom-build-identity.json"
        self.metadata = {
            "schemaVersion": 1,
            "kind": "mom.openmw-build",
            "source": {
                "url": "https://example.invalid/luajit-openmw.git",
                "ref": "HEAD",
                "commit": "a" * 40,
                "mode": "explicit",
            },
            "patches": [{"name": "collector.patch", "sha256": "b" * 64}],
            "build": {
                "type": "Release",
                "cmakeOptions": ["-DBUILD_TESTING=OFF"],
                "cmake": {"command": "cmake", "path": "/usr/bin/cmake", "version": "cmake 3"},
                "cCompiler": {"command": "cc", "path": None, "version": None},
                "cxxCompiler": {"command": "c++", "path": None, "version": None},
                "environment": {
                    "CMAKE_GENERATOR": None,
                    "CFLAGS": "",
                    "CXXFLAGS": "-O2",
                    "LDFLAGS": None,
                },
            },
        }
        encoded = (json.dumps(self.metadata, sort_keys=True, indent=2) + "\n").encode()
        self.metadata["buildKey"] = hashlib.sha256(encoded).hexdigest()
        self.metadata["binary"] = {
            "sha256": hashlib.sha256(self.binary.read_bytes()).hexdigest(),
            "size": self.binary.stat().st_size,
        }

    def write_metadata(self, metadata: object | None = None) -> None:
        self.metadata_path.write_text(json.dumps(
            self.metadata if metadata is None else metadata,
        ), encoding="utf-8")

    def test_external_or_old_engine_has_no_invented_build_metadata(self) -> None:
        environment = {
            "MOM_HARNESS_OPENMW_SOURCE_REF": "clockwork-alpha",
            "MOM_HARNESS_OPENMW_BUILD_TYPE": "RelWithDebInfo",
        }
        with mock.patch.dict(os.environ, environment):
            self.assertIsNone(openmw.engine_build_metadata(self.binary))
            with (
                mock.patch.object(openmw.shutil, "which", return_value=None),
                mock.patch.object(openmw, "_openmw_version", return_value="fixture OpenMW"),
            ):
                identity = openmw.binary_identity(self.binary)
        self.assertIsNone(identity["buildMetadata"])
        self.assertEqual(identity["sha256"], self.metadata["binary"]["sha256"])
        self.assertEqual(identity["path"], str(self.binary))

    def test_valid_metadata_retains_actual_source_patch_and_build_facts(self) -> None:
        self.write_metadata()
        self.assertEqual(openmw.engine_build_metadata(self.binary), self.metadata)
        with (
            mock.patch.object(openmw.shutil, "which", return_value=None),
            mock.patch.object(openmw, "_openmw_version", return_value="fixture OpenMW"),
        ):
            identity = openmw.binary_identity(self.binary)
        self.assertEqual(identity["buildMetadata"], self.metadata)
        alias = self.root / "openmw-alias"
        alias.symlink_to(self.binary)
        self.assertEqual(openmw.engine_build_metadata(alias), self.metadata)

    def test_builder_sidecar_is_readable_without_environment_attribution(self) -> None:
        for overrides in ({}, {"CC": "", "CXX": ""}):
            with self.subTest(environment=overrides):
                describe = subprocess.run([
                    sys.executable, str(HOST_ROOT / "build_identity.py"),
                    "--source-commit", "c" * 40, "--source-mode", "explicit",
                    "--build-type", "Release", "--cmake-option=-DBUILD_TESTING=OFF",
                ], check=True, stdout=subprocess.PIPE, text=True, timeout=30,
                    env={**os.environ, **overrides})
                bound = subprocess.run([
                    sys.executable, str(HOST_ROOT / "build_identity.py"),
                    "--bind-binary", str(self.binary),
                ], input=describe.stdout, check=True, stdout=subprocess.PIPE, text=True, timeout=30)
                self.metadata_path.write_text(bound.stdout, encoding="utf-8")
                metadata = openmw.engine_build_metadata(self.binary)
                self.assertEqual(metadata, json.loads(bound.stdout))
                self.assertEqual(metadata["source"], {
                    "url": None, "ref": "HEAD", "commit": "c" * 40, "mode": "explicit",
                })
                if overrides:
                    self.assertEqual(metadata["build"]["cCompiler"]["command"], "cc")
                    self.assertEqual(metadata["build"]["cxxCompiler"]["command"], "c++")

    def test_malformed_present_metadata_fails_with_path_and_reason(self) -> None:
        invalid = [
            ({"schemaVersion": 1}, "unsupported shape"),
            ({**self.metadata, "schemaVersion": True}, "schemaVersion"),
            ({**self.metadata, "source": {**self.metadata["source"], "commit": "HEAD"}}, "source.commit"),
            ({**self.metadata, "patches": [{"name": "patch", "sha256": "invalid"}]}, "patches"),
            ({**self.metadata, "build": {**self.metadata["build"], "type": ""}}, "build.type"),
        ]
        for metadata, reason in invalid:
            with self.subTest(reason=reason):
                self.write_metadata(metadata)
                with self.assertRaisesRegex(openmw.OpenMWError, reason) as raised:
                    openmw.engine_build_metadata(self.binary)
                self.assertIn(str(self.metadata_path), str(raised.exception))

    def test_invalid_json_and_duplicate_keys_fail_without_fallback(self) -> None:
        for content in ("{bad JSON", '{"schemaVersion":1,"schemaVersion":1}'):
            with self.subTest(content=content):
                self.metadata_path.write_text(content, encoding="utf-8")
                with self.assertRaisesRegex(openmw.OpenMWError, "invalid OpenMW build metadata"):
                    openmw.engine_build_metadata(self.binary)

    def test_non_file_or_broken_sidecar_is_not_treated_as_absent(self) -> None:
        self.metadata_path.mkdir()
        with self.assertRaisesRegex(openmw.OpenMWError, "invalid OpenMW build metadata"):
            openmw.engine_build_metadata(self.binary)
        self.metadata_path.rmdir()
        self.metadata_path.symlink_to(self.root / "missing.json")
        with self.assertRaisesRegex(openmw.OpenMWError, "invalid OpenMW build metadata"):
            openmw.engine_build_metadata(self.binary)

    def test_replaced_executable_or_changed_build_inputs_reject_stale_metadata(self) -> None:
        self.write_metadata()
        self.binary.write_bytes(b"replaced executable\n")
        with self.assertRaisesRegex(openmw.OpenMWError, "does not match the executable"):
            openmw.engine_build_metadata(self.binary)
        self.binary.write_bytes(b"fixture executable\n")
        changed = deepcopy(self.metadata)
        changed["build"]["type"] = "Debug"
        self.write_metadata(changed)
        with self.assertRaisesRegex(openmw.OpenMWError, "buildKey does not match"):
            openmw.engine_build_metadata(self.binary)

    def prepare(self, build_openmw: bool | None = None) -> dict:
        raw_result = self.root / "raw.json"
        launch_spec = self.root / "launch.json"
        work = self.root / "work"

        def prepare_process(command: list[str], **kwargs: object) -> dict:
            self.assertEqual("--build-openmw" in command, build_openmw is True)
            self.assertEqual("--no-build-openmw" in command, build_openmw is False)
            launch.write_launch_spec(
                output=launch_spec,
                performance_lane="embedded",
                command=[str(self.binary)],
                openmw_binary=str(self.binary),
                harness_owned_build=True,
                source_ref="clockwork-alpha",
                build_type="RelWithDebInfo",
                work_directory=work,
                config=work / "openmw.cfg",
                settings=work / "settings.cfg",
                run_options=work / "run_options.lua",
                log=work / "openmw.log",
                result=raw_result,
            )
            return {"returnCode": 0, "timedOut": False}

        with (
            mock.patch.object(openmw.process, "run_process", side_effect=prepare_process),
            mock.patch.object(openmw.shutil, "which", return_value=None),
            mock.patch.object(openmw, "_openmw_version", return_value="fixture OpenMW"),
        ):
            spec, _ = openmw.prepare_embedded(
                harness_root=HOST_ROOT.parent,
                work_directory=work,
                raw_result=raw_result,
                launch_spec_path=launch_spec,
                workload_ids=["idle_tick"],
                lane="embedded",
                samples=3,
                warmups=1,
                memory_evidence=False,
                prepare_stdout=self.root / "prepare.stdout",
                prepare_stderr=self.root / "prepare.stderr",
                timeout_seconds=30,
                openmw_binary=self.binary,
                build_openmw=build_openmw,
            )
        return spec["openmw"]

    def test_benchmark_preparation_removes_invented_external_engine_defaults(self) -> None:
        with mock.patch.dict(os.environ, {
            "MOM_HARNESS_OPENMW_SOURCE_REF": "clockwork-alpha",
            "MOM_HARNESS_OPENMW_BUILD_TYPE": "RelWithDebInfo",
        }):
            engine = self.prepare(False)
        self.assertFalse(engine["harnessOwnedBuild"])
        self.assertIsNone(engine["sourceRef"])
        self.assertIsNone(engine["buildType"])
        self.assertIsNone(engine["buildKey"])
        self.assertEqual(engine["identity"]["sha256"], self.metadata["binary"]["sha256"])

    def test_benchmark_preparation_uses_verified_metadata_and_actual_commit(self) -> None:
        self.write_metadata()
        engine = self.prepare(True)
        self.assertTrue(engine["harnessOwnedBuild"])
        self.assertEqual(engine["sourceRef"], self.metadata["source"]["commit"])
        self.assertEqual(engine["buildType"], "Release")
        self.assertEqual(engine["buildKey"], self.metadata["buildKey"])
        self.assertEqual(engine["identity"]["buildMetadata"]["patches"], self.metadata["patches"])


if __name__ == "__main__":
    unittest.main()
