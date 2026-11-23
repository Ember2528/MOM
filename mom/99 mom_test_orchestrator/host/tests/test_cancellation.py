from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock


HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import process


def alive(pid: int) -> bool:
    try:
        status = Path(f"/proc/{pid}/stat").read_text(encoding="ascii")
    except FileNotFoundError:
        return False
    return status.rsplit(")", 1)[1].split()[0] != "Z"


def wait_for_file(path: Path, owner: subprocess.Popen[bytes]) -> dict[str, int]:
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if path.is_file():
            try:
                return json.loads(path.read_text(encoding="ascii"))
            except json.JSONDecodeError:
                pass
        if owner.poll() is not None:
            raise AssertionError(f"controller exited before its child started: {owner.returncode}")
        time.sleep(0.01)
    raise AssertionError("child did not start")


class CancellationTests(unittest.TestCase):
    def assert_stopped(self, *pids: int) -> None:
        deadline = time.monotonic() + 2
        while time.monotonic() < deadline and any(alive(pid) for pid in pids):
            time.sleep(0.01)
        self.assertFalse([pid for pid in pids if alive(pid)], "child processes survived cancellation")

    @staticmethod
    def cleanup(owner: subprocess.Popen[bytes], pids: list[int]) -> None:
        for pid in [owner.pid, *pids]:
            try:
                os.killpg(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        owner.wait(timeout=5)

    def test_signals_cancel_and_reap_owned_group_and_restore_handlers(self) -> None:
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                ready = root / "ready.json"
                leaf = root / "leaf.py"
                leaf.write_text(
                    "import json, os, signal, sys, time\n"
                    "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                    "with open(sys.argv[1], 'w') as stream:\n"
                    "    json.dump({'pid': os.getpid()}, stream)\n"
                    "time.sleep(60)\n",
                    encoding="utf-8",
                )
                controller = root / "controller.py"
                controller.write_text(
                    "import os, signal, sys\nfrom pathlib import Path\n"
                    f"sys.path.insert(0, {str(HOST_ROOT)!r})\nimport process\n"
                    "original = [signal.getsignal(n) for n in (signal.SIGINT, signal.SIGTERM)]\n"
                    "try:\n"
                    f"    process.run_process([sys.executable, {str(leaf)!r}, {str(ready)!r}],\n"
                    f"        cwd=Path({str(root)!r}), environment=dict(os.environ),\n"
                    "        stdout_path=None, stderr_path=None, timeout_seconds=None,\n"
                    "        termination_grace_seconds=0.2)\n"
                    "except process.ProcessCancelled as exc:\n"
                    "    assert original == [signal.getsignal(n) for n in (signal.SIGINT, signal.SIGTERM)]\n"
                    "    raise SystemExit(128 + exc.signum)\n",
                    encoding="utf-8",
                )
                with (root / "host.log").open("wb") as log:
                    owner = subprocess.Popen([sys.executable, str(controller)],
                                             stdout=log, stderr=subprocess.STDOUT,
                                             start_new_session=True)
                    pids: list[int] = []
                    try:
                        pids.append(wait_for_file(ready, owner)["pid"])
                        os.kill(owner.pid, signum)
                        time.sleep(0.05)
                        # Repeated terminal/parent cancellation must not interrupt cleanup.
                        os.kill(owner.pid, signum)
                        self.assertEqual(owner.wait(timeout=5), 128 + signum)
                        self.assert_stopped(*pids)
                    finally:
                        self.cleanup(owner, pids)

    def test_timeout_finishes_descendants_after_group_leader_exits(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / "ready.json"
            script = root / "parent.py"
            script.write_text(
                "import json, os, subprocess, sys, time\n"
                "leaf = subprocess.Popen([sys.executable, '-c',\n"
                "    'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'])\n"
                "time.sleep(0.1)\n"
                "with open(sys.argv[1], 'w') as stream:\n"
                "    json.dump({'pid': os.getpid(), 'leaf': leaf.pid}, stream)\n"
                "time.sleep(60)\n",
                encoding="utf-8",
            )
            pids: list[int] = []
            try:
                record = process.run_process(
                    [sys.executable, str(script), str(ready)], cwd=root,
                    environment=dict(os.environ), stdout_path=root / "host.log",
                    stderr_path=None, timeout_seconds=0.5,
                    termination_grace_seconds=0.2,
                )
                children = json.loads(ready.read_text(encoding="ascii"))
                pids.extend(children.values())
                self.assertTrue(record["timedOut"])
                self.assertEqual(record["returnCode"], -signal.SIGTERM)
                self.assert_stopped(*pids)
            finally:
                for pid in pids:
                    try:
                        os.kill(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    def test_non_signal_exception_also_cleans_up_started_child(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            original_popen = subprocess.Popen
            children: list[subprocess.Popen[bytes]] = []

            def start(*args: object, **kwargs: object) -> subprocess.Popen[bytes]:
                child = original_popen(*args, **kwargs)
                children.append(child)
                return child

            with (
                mock.patch.object(process.subprocess, "Popen", side_effect=start),
                mock.patch.object(process, "effective_cpu_set", side_effect=SystemExit(7)),
                self.assertRaises(SystemExit),
            ):
                process.run_process(
                    [sys.executable, "-c", "import time; time.sleep(60)"], cwd=root,
                    environment=dict(os.environ), stdout_path=root / "host.log",
                    stderr_path=None, timeout_seconds=None,
                )
            self.assertEqual(len(children), 1)
            self.assertIsNotNone(children[0].poll())
            self.assert_stopped(children[0].pid)

    def test_signal_during_spawn_is_deferred_until_child_has_an_owner(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / "mask.json"
            script = root / "child.py"
            script.write_text(
                "import json, signal, sys, time\n"
                "with open(sys.argv[1], 'w') as stream:\n"
                "    json.dump({'mask': sorted(signal.pthread_sigmask(signal.SIG_BLOCK, []))}, stream)\n"
                "time.sleep(60)\n",
                encoding="utf-8",
            )
            original_popen = subprocess.Popen
            children: list[subprocess.Popen[bytes]] = []
            original_handlers = [signal.getsignal(n) for n in (signal.SIGINT, signal.SIGTERM)]

            def start(*args: object, **kwargs: object) -> subprocess.Popen[bytes]:
                child = original_popen(*args, **kwargs)
                children.append(child)
                wait_for_file(ready, child)
                # This is exactly the gap before run_process has assigned its
                # Popen result. Its temporary mask defers the raising handler.
                os.kill(os.getpid(), signal.SIGTERM)
                return child

            with (
                mock.patch.object(process.subprocess, "Popen", side_effect=start),
                self.assertRaises(process.ProcessCancelled),
            ):
                process.run_process(
                    [sys.executable, str(script), str(ready)], cwd=root,
                    environment=dict(os.environ), stdout_path=root / "host.log",
                    stderr_path=None, timeout_seconds=None,
                )
            self.assertEqual(original_handlers, [signal.getsignal(n) for n in (signal.SIGINT, signal.SIGTERM)])
            mask = json.loads(ready.read_text(encoding="ascii"))["mask"]
            self.assertNotIn(signal.SIGINT, mask)
            self.assertNotIn(signal.SIGTERM, mask)
            self.assertIsNotNone(children[0].poll())
            self.assert_stopped(children[0].pid)

    def test_campaign_cancellation_reaches_phase_and_engine_sessions(self) -> None:
        if shutil.which("lua") is None:
            self.skipTest("system Lua is unavailable")
        for signum in (signal.SIGINT, signal.SIGTERM):
            with self.subTest(signal=signum), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                ready = root / "engine.json"
                resources = root / "resources"
                (resources / "vfs-mw").mkdir(parents=True)
                base_config = root / "base.cfg"
                base_config.write_text(f'resources="{resources}"\n', encoding="utf-8")
                data = root / "data"
                data.mkdir()
                for name in ("Morrowind.esm", "Tribunal.esm", "Bloodmoon.esm"):
                    (data / name).write_bytes(b"test")
                global_config = root / "global.cfg"
                global_config.write_text(f'data="{data}"\n', encoding="utf-8")
                engine = root / "openmw"
                engine.write_text(
                    f"#!{sys.executable}\nimport json, os, signal, time\n"
                    # Exercise the hard-kill path beneath both owning controllers.
                    + ("signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                       if signum == signal.SIGTERM else "")
                    + f"with open({str(ready)!r}, 'w') as stream:\n"
                    "    json.dump({'pid': os.getpid(), 'phase': os.getppid(),\n"
                    "               'group': os.getpgrp()}, stream)\n"
                    "time.sleep(60)\n",
                    encoding="utf-8",
                )
                engine.chmod(0o755)
                with (root / "campaign.log").open("wb") as log:
                    owner = subprocess.Popen([
                        sys.executable, str(HOST_ROOT / "process_campaigns.py"),
                        "--campaign", "reversible_restart", "--workdir", str(root / "work"),
                        "--openmw", str(engine), "--no-build-openmw",
                        "--global-config", str(global_config),
                        "--openmw-base-config", str(base_config),
                    ], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                    pids: list[int] = []
                    try:
                        started = wait_for_file(ready, owner)
                        pids.extend([started["pid"], started["phase"]])
                        self.assertEqual(started["group"], started["pid"])
                        self.assertEqual(os.getpgid(started["phase"]), started["phase"])
                        self.assertNotEqual(started["phase"], owner.pid)
                        os.kill(owner.pid, signum)
                        self.assertEqual(owner.wait(timeout=12), 128 + signum)
                        self.assert_stopped(*pids)
                    finally:
                        self.cleanup(owner, pids)

    def test_direct_standalone_cancellation_reaps_interpreter(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ready = root / "interpreter.json"
            interpreter = root / "lua"
            interpreter.write_text(
                f"#!{sys.executable}\nimport json, os, time\n"
                f"with open({str(ready)!r}, 'w') as stream:\n"
                "    json.dump({'pid': os.getpid()}, stream)\n"
                "time.sleep(60)\n",
                encoding="utf-8",
            )
            interpreter.chmod(0o755)
            with (root / "host.log").open("wb") as log:
                owner = subprocess.Popen([
                    sys.executable, str(HOST_ROOT / "standalone.py"), "--lua", str(interpreter),
                ], stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
                pids: list[int] = []
                try:
                    pids.append(wait_for_file(ready, owner)["pid"])
                    os.kill(owner.pid, signal.SIGTERM)
                    self.assertEqual(owner.wait(timeout=7), 143)
                    self.assert_stopped(*pids)
                finally:
                    self.cleanup(owner, pids)

    def test_virtual_display_cleans_up_when_enter_is_interrupted(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            display = process.VirtualDisplay(root / "display.log", force=True)
            child: subprocess.Popen[bytes] | None = None

            def start() -> str:
                nonlocal child
                display._log = display.log_path.open("wb")
                child = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(60)"],
                                         start_new_session=True)
                display.child = child
                raise KeyboardInterrupt

            with mock.patch.object(display, "_start", side_effect=start), self.assertRaises(KeyboardInterrupt):
                display.__enter__()
            self.assertIsNone(display.child)
            self.assertIsNone(display._log)
            self.assertIsNotNone(child)
            self.assertIsNotNone(child.poll())
            self.assert_stopped(child.pid)


if __name__ == "__main__":
    unittest.main()
