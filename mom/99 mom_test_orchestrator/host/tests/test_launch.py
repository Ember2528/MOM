from __future__ import annotations

from contextlib import redirect_stdout
import io
from pathlib import Path
import os
import shlex
import sys
import tempfile
import unittest
from unittest import mock


HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import launch


class LaunchTests(unittest.TestCase):
    def test_engine_build_requires_explicit_selection(self) -> None:
        with mock.patch.dict(os.environ, {}, clear=True):
            arguments = launch.parser().parse_args([])
            self.assertFalse(launch._build_policy(arguments.build_openmw))
            arguments = launch.parser().parse_args(["--build-openmw"])
            self.assertTrue(launch._build_policy(arguments.build_openmw))
            arguments = launch.parser().parse_args(["--no-build-openmw"])
            self.assertFalse(launch._build_policy(arguments.build_openmw))
        with mock.patch.dict(os.environ, {"MOM_HARNESS_BUILD_OPENMW": "0"}):
            arguments = launch.parser().parse_args([])
            self.assertFalse(launch._build_policy(arguments.build_openmw))

    def test_shared_engine_resolver_uses_one_build_policy_and_source_defaults(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            engine = root / "openmw"
            engine.write_text("", encoding="utf-8")
            engine.chmod(0o755)
            source = root / "source"
            build_root = root / "build"
            environment = {
                "OPENMW_BIN": str(engine),
                "MOM_HARNESS_OPENMW_SOURCE_URL": "https://example.invalid/openmw.git",
                "MOM_HARNESS_OPENMW_SOURCE_REF": "fixed-revision",
                "MOM_HARNESS_OPENMW_SOURCE_DIR": str(source),
                "MOM_HARNESS_OPENMW_BUILD_ROOT": str(build_root),
                "MOM_HARNESS_OPENMW_BUILD_TYPE": "Release",
                "MOM_HARNESS_OPENMW_BUILD_JOBS": "3",
            }
            with (mock.patch.dict(os.environ, environment, clear=True),
                  mock.patch.object(launch, "_build_openmw", return_value=engine) as build):
                self.assertEqual(
                    launch.resolve_openmw_binary(None, work_directory=root), engine
                )
                build.assert_not_called()

                self.assertEqual(launch.resolve_openmw_binary(
                    engine, work_directory=root, build_openmw=True
                ), engine)
                build.assert_called_once()
                options = build.call_args.kwargs
                self.assertEqual(options["source_ref"], "fixed-revision")
                self.assertEqual(options["source_url"], environment["MOM_HARNESS_OPENMW_SOURCE_URL"])
                self.assertEqual(options["source_directory"], source)
                self.assertEqual(options["build_root"], build_root)
                self.assertEqual(options["build_type"], "Release")
                self.assertEqual(options["build_jobs"], "3")
                build.reset_mock()
                with self.assertRaisesRegex(launch.LaunchError, "provisioning requires execution"):
                    launch.resolve_openmw_binary(
                        engine, work_directory=root, build_openmw=True, dry_run=True,
                    )
                build.assert_not_called()

    def test_source_options_cannot_silently_select_an_unrelated_executable(self) -> None:
        for options in ({"source_directory": Path("/opt/source")}, {"build_root": Path("/opt/cache")}):
            with self.subTest(options=options):
                with self.assertRaisesRegex(launch.LaunchError, "require --build-openmw"):
                    launch.resolve_openmw_binary(
                        Path("/opt/unrelated-openmw"), work_directory=Path("/tmp/run"),
                        build_openmw=False, **options,
                    )

    def test_shared_config_resolution_obeys_explicit_and_environment_precedence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            xdg = root / "xdg/openmw/openmw.cfg"
            configured = root / "configured.cfg"
            explicit = root / "explicit.cfg"
            resources = root / "resources"
            (resources / "vfs-mw").mkdir(parents=True)
            for config in (xdg, configured, explicit):
                config.parent.mkdir(parents=True, exist_ok=True)
                config.write_text(f'resources="{resources}"\n', encoding="utf-8")
            with mock.patch.dict(os.environ, {"XDG_CONFIG_HOME": str(root / "xdg")}, clear=True):
                self.assertEqual(launch.resolve_global_config(), xdg)
                os.environ["OPENMW_GLOBAL_CONFIG"] = str(configured)
                self.assertEqual(launch.resolve_global_config(), configured)
                self.assertEqual(launch.resolve_global_config(explicit), explicit)
                os.environ["MOM_HARNESS_OPENMW_BASE_CONFIG"] = str(configured)
                self.assertEqual(launch.resolve_base_config(None, root / "openmw"), configured)
                self.assertEqual(launch.resolve_base_config(explicit, root / "openmw"), explicit)

    def test_one_builder_normalizes_correctness_and_performance_commands(
        self,
    ) -> None:
        correctness = launch.build_harness_command(
            launch.HarnessCommand(
                mode="correctness",
                work_directory=Path("/tmp/work"),
                result_file=Path("/tmp/result.json"),
                scenarios=("one", "two"),
                openmw_binary=Path("/opt/openmw"),
                build_openmw=False,
                openmw_arguments=("--data", "/tmp/fixture"),
            ),
            harness=Path("/tmp/run_harness.sh"),
        )
        self.assertEqual(correctness[:5], [
            "/tmp/run_harness.sh",
            "--workdir",
            "/tmp/work",
            "--result-file",
            "/tmp/result.json",
        ])
        self.assertEqual(
            [
                correctness[index + 1]
                for index, item in enumerate(correctness[:-1])
                if item == "--scenario"
            ],
            ["one", "two"],
        )
        self.assertEqual(
            correctness[-3:],
            ["--", "--data", "/tmp/fixture"],
        )

        performance = launch.build_harness_command(
            launch.HarnessCommand(
                mode="embedded",
                work_directory=Path("/tmp/work"),
                result_file=Path("/tmp/raw.json"),
                workload_ids=("idle_tick", "event_fanout"),
                samples=3,
                warmups=1,
                memory_evidence=True,
                launch_spec=Path("/tmp/launch.json"),
            ),
            harness=Path("/tmp/run_harness.sh"),
        )
        self.assertIn("--launch-spec", performance)
        self.assertIn("--performance-memory-evidence", performance)
        self.assertEqual(
            [
                performance[index + 1]
                for index, item in enumerate(performance[:-1])
                if item == "--performance-case"
            ],
            ["idle_tick", "event_fanout"],
        )

    def test_owned_build_uses_its_matching_resources_after_building(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            engine = root / "built-engine"
            resources = engine / "resources"
            (resources / "vfs-mw").mkdir(parents=True)
            binary = engine / "openmw"
            binary.write_text("", encoding="utf-8")
            binary.chmod(0o755)
            (engine / "openmw.cfg").write_text(
                "resources=./resources\ndata=./resources/vfs-mw\n",
                encoding="utf-8",
            )
            data = root / "game"
            data.mkdir()
            for name in ("Morrowind.esm", "Tribunal.esm", "Bloodmoon.esm"):
                (data / name).write_bytes(b"test")
            global_config = root / "global.cfg"
            global_config.write_text(f'data="{data}"\n', encoding="utf-8")
            work = root / "work"
            with (mock.patch.dict(os.environ, {}, clear=True),
                  mock.patch.object(launch, "_build_openmw", return_value=binary) as build,
                  mock.patch.object(launch.process, "run_process", return_value={
                      "returnCode": 0, "timedOut": False,
                  }),
                  redirect_stdout(io.StringIO())):
                status = launch.main([
                    "--build-openmw", "--global-config", str(global_config),
                    "--workdir", str(work),
                    "--performance-case", "idle_tick",
                    "--launch-spec", str(root / "launch.json"),
                ])
            self.assertEqual(status, 0)
            build.assert_called_once()
            generated = (work / "config" / "openmw.cfg").read_text(encoding="utf-8")
            self.assertIn(f'resources="{resources}"', generated)
            self.assertIn(f'data="{resources / "vfs-mw"}"', generated)
            self.assertEqual(launch.resolve_base_config(None, binary), engine / "openmw.cfg")

            explicit = root / "explicit.cfg"
            explicit.write_text(f'resources="{resources}"\n', encoding="utf-8")
            self.assertEqual(launch.resolve_base_config(explicit, binary), explicit)

    def test_planning_preserves_existing_runs_and_never_invokes_provisioning(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            data = root / "game"
            data.mkdir()
            for name in ("Morrowind.esm", "Tribunal.esm", "Bloodmoon.esm"):
                (data / name).write_bytes(b"fixture")
            config = root / "global.cfg"
            config.write_text(f'data="{data}"\n', encoding="utf-8")
            resources = root / "resources"
            (resources / "vfs-mw").mkdir(parents=True)
            base = root / "base.cfg"
            base.write_text(f'resources="{resources}"\n', encoding="utf-8")
            work = launch.prepare_workdir(root / "previous")
            evidence = work / "result.json"
            evidence.write_bytes(b"previous result")
            before = {p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()}
            with (mock.patch.object(launch, "_build_openmw") as build,
                  mock.patch.object(launch.process, "run_process") as run,
                  redirect_stdout(io.StringIO())):
                common = ["--dry-run", "--global-config", str(config), "--workdir", str(work)]
                self.assertEqual(launch.main(common + ["--build-openmw"]), 0)
                self.assertEqual(launch.main(common + [
                    "--openmw", "/opt/planned-openmw", "--openmw-base-config", str(base),
                ]), 0)
                absent = root / "planned"
                self.assertEqual(launch.main([
                    "--dry-run", "--build-openmw", "--global-config", str(config),
                    "--workdir", str(absent),
                ]), 0)
                self.assertFalse(absent.exists())
                build.assert_not_called()
                run.assert_not_called()
            self.assertEqual(before, {
                p.relative_to(root): p.read_bytes() for p in root.rglob("*") if p.is_file()
            })

    def test_python_authority_writes_isolated_config_and_options(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            base = root / "base.cfg"
            resources = root / "resources"
            (resources / "vfs-mw").mkdir(parents=True)
            base.write_text(
                f'resources="{resources}"\n'
                'fallback=Water_RippleFrameCount,4\n'
                'content=ignored.omwaddon\n',
                encoding="utf-8",
            )
            data = root / "Morrowind Data Files"
            data.mkdir()
            for name in ("Morrowind.esm", "Tribunal.esm", "Bloodmoon.esm"):
                (data / name).write_bytes(name.encode())
            global_config = root / "global.cfg"
            global_config.write_text(
                f'data="{data}"\n',
                encoding="utf-8",
            )
            work = root / "work"
            prepared = launch.prepare_workdir(work)
            generated = prepared / "generated-data"
            launch.write_config(
                prepared / "config" / "openmw.cfg",
                base_config=base,
                morrowind_data=launch.find_morrowind_data_dir(global_config),
                user_data=prepared / "userdata",
                generated_data=generated,
            )
            launch.write_run_options(
                generated / "scripts" / "mom_test_orchestrator"
                / "run_options.lua",
                mode="correctness",
                scenarios=("scenario",),
                result_file=prepared / "result.json",
                performance_lane="embedded",
                workloads=(),
                samples=1,
                warmups=1,
                memory_evidence=False,
                start_delay_frames=5,
            )
            config = (
                prepared / "config" / "openmw.cfg"
            ).read_text(encoding="utf-8")
            options = (
                generated / "scripts" / "mom_test_orchestrator"
                / "run_options.lua"
            ).read_text(encoding="utf-8")
            self.assertIn(f'resources="{resources}"', config)
            self.assertNotIn("ignored.omwaddon", config)
            self.assertIn("content=mom.omwscripts", config)
            self.assertIn("'scenario'", options)
            self.assertIn("performance = nil", options)

            output = io.StringIO()
            with redirect_stdout(output):
                status = launch.main([
                    "--dry-run", "--no-build-openmw",
                    "--openmw", "/opt/test-openmw",
                    "--global-config", str(global_config),
                    "--openmw-base-config", str(base),
                    "--workdir", str(work),
                    "--", "--data", str(root / "handoff data"),
                    "--load-savegame", str(root / "previous.omwsave"),
                ])
            self.assertEqual(status, 0)
            command_line = next(
                line.removeprefix("Command: ")
                for line in output.getvalue().splitlines()
                if line.startswith("Command: ")
            )
            command = shlex.split(command_line)
            self.assertNotIn("--", command)
            self.assertEqual(command[-4:], [
                "--data", str(root / "handoff data"),
                "--load-savegame", str(root / "previous.omwsave"),
            ])

    def test_workdir_preserves_existing_results_and_rejects_repository(self) -> None:
        with self.assertRaisesRegex(launch.LaunchError, "unsafe"):
            launch.prepare_workdir(launch.REPOSITORY_ROOT)
        with tempfile.TemporaryDirectory() as directory:
            unmarked = Path(directory) / "work"
            unmarked.mkdir()
            with self.assertRaisesRegex(launch.LaunchError, "already exists"):
                launch.prepare_workdir(unmarked)
            marked = launch.prepare_workdir(Path(directory) / "marked")
            (marked / "result.json").write_bytes(b"completed")
            with self.assertRaisesRegex(launch.LaunchError, "already exists"):
                launch.prepare_workdir(marked)
            self.assertEqual((marked / "result.json").read_bytes(), b"completed")
            with self.assertRaisesRegex(launch.LaunchError, "unsafe"):
                launch.prepare_workdir(launch.REPOSITORY_ROOT / "generated")
            first = launch.parser().parse_args([]).workdir
            second = launch.parser().parse_args([]).workdir
            self.assertNotEqual(first, second)
            self.assertFalse(first.exists())
            self.assertFalse(second.exists())


if __name__ == "__main__":
    unittest.main()
