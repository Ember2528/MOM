from __future__ import annotations

from contextlib import ExitStack, contextmanager
import os
from pathlib import Path
import shutil
import signal
import subprocess
import threading
import time
from typing import Any, Iterator


class ProcessError(RuntimeError):
    pass


class ProcessCancelled(KeyboardInterrupt):
    def __init__(self, signum: int):
        self.signum = signum
        super().__init__(f"cancelled by {signal.Signals(signum).name}")


@contextmanager
def _signal_handler(handler: Any) -> Iterator[None]:
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    previous = {
        signum: signal.signal(signum, handler)
        for signum in (signal.SIGINT, signal.SIGTERM)
    }
    try:
        yield
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)


@contextmanager
def cancellation_signals() -> Iterator[None]:
    """Let process owners unwind and clean up on terminal or parent signals."""
    def cancel(signum: int, _frame: object) -> None:
        raise ProcessCancelled(signum)

    with _signal_handler(cancel):
        yield


@contextmanager
def ignore_cancellation() -> Iterator[None]:
    """Finish bounded cleanup or atomic result saving despite repeated signals."""
    with _signal_handler(signal.SIG_IGN):
        yield


def _stop_process_group(child: subprocess.Popen[bytes], *, grace_seconds: float = 5) -> int:
    # The group may still contain descendants after its leader exits. Always
    # finish the group, including children that ignored the graceful signal.
    with ignore_cancellation():
        try:
            os.killpg(child.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            return_code = child.wait(timeout=grace_seconds)
        except subprocess.TimeoutExpired:
            return_code = None
        finally:
            try:
                os.killpg(child.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if return_code is None:
            return_code = child.wait(timeout=5)
        return return_code


def parse_cpu_set(value: str | None) -> set[int] | None:
    if value is None:
        return None
    result: set[int] = set()
    for token in value.split(","):
        parts = token.split("-", 1)
        if not all(part.isdecimal() for part in parts):
            raise ProcessError(f"invalid CPU set: {value}")
        first = int(parts[0])
        last = int(parts[-1])
        if last < first:
            raise ProcessError(f"descending CPU range: {token}")
        result.update(range(first, last + 1))
    if not result:
        raise ProcessError("CPU set cannot be empty")
    return result


def format_cpu_set(values: set[int]) -> str:
    ordered = sorted(values)
    if not ordered:
        raise ProcessError("CPU set cannot be empty")
    ranges: list[str] = []
    first = last = ordered[0]
    for value in ordered[1:]:
        if value == last + 1:
            last = value
            continue
        ranges.append(str(first) if first == last else f"{first}-{last}")
        first = last = value
    ranges.append(str(first) if first == last else f"{first}-{last}")
    return ",".join(ranges)


def effective_cpu_set(pid: int) -> str | None:
    try:
        for line in Path(f"/proc/{pid}/status").read_text(encoding="utf-8").splitlines():
            if line.startswith("Cpus_allowed_list:"):
                return line.split(":", 1)[1].strip()
    except OSError:
        return None
    return None


def run_process(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    stdout_path: Path | None,
    stderr_path: Path | None,
    timeout_seconds: float | None,
    cpu_set: set[int] | None = None,
    termination_grace_seconds: float = 15,
) -> dict[str, Any]:
    if not command:
        raise ProcessError("process command cannot be empty")
    if stdout_path is not None:
        stdout_path.parent.mkdir(parents=True, exist_ok=True)
    if stderr_path is not None:
        stderr_path.parent.mkdir(parents=True, exist_ok=True)

    def configure_child() -> None:
        os.setsid()
        if cpu_set is not None:
            os.sched_setaffinity(0, cpu_set)
        signal.pthread_sigmask(signal.SIG_SETMASK, parent_signal_mask)

    started_utc = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    started = time.monotonic()
    timed_out = False
    with cancellation_signals(), ExitStack() as streams:
        stdout = streams.enter_context(stdout_path.open("wb")) if stdout_path is not None else None
        stderr = (
            streams.enter_context(stderr_path.open("wb"))
            if stderr_path is not None
            else subprocess.STDOUT
        )
        child = None
        try:
            # A cancellation between fork and Popen returning must not lose the
            # only reference to a newly independent process group. The child
            # restores its inherited mask before exec; the parent restores it
            # only once this ownership/cleanup block has the child reference.
            parent_signal_mask = signal.pthread_sigmask(
                signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM},
            )
            try:
                try:
                    child = subprocess.Popen(
                        command,
                        cwd=cwd,
                        env=environment,
                        stdout=stdout,
                        stderr=stderr,
                        preexec_fn=configure_child,
                    )
                except (OSError, subprocess.SubprocessError) as exc:
                    raise ProcessError(f"cannot start {command[0]}: {exc}") from exc
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, parent_signal_mask)
            effective = effective_cpu_set(child.pid)
            return_code = child.wait(timeout=timeout_seconds)
        except subprocess.TimeoutExpired:
            timed_out = True
            return_code = _stop_process_group(child, grace_seconds=termination_grace_seconds)
        except BaseException:
            if child is not None:
                _stop_process_group(child, grace_seconds=termination_grace_seconds)
            raise
    return {
        "command": command,
        "cwd": str(cwd.resolve()),
        "startedAtUtc": started_utc,
        "durationSeconds": time.monotonic() - started,
        "returnCode": return_code,
        "timedOut": timed_out,
        "cpuAffinity": {
            "requested": format_cpu_set(cpu_set) if cpu_set is not None else None,
            "effective": effective,
            "scope": "process_group",
        },
    }


class VirtualDisplay:
    def __init__(self, log_path: Path, *, force: bool = False):
        self.log_path = log_path
        self.force = force
        self.child: subprocess.Popen[bytes] | None = None
        self.display = os.environ.get("DISPLAY") if not force else None
        self._log = None

    def __enter__(self) -> str:
        try:
            return self._start()
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def _start(self) -> str:
        if self.display:
            return self.display
        executable = shutil.which("Xvfb")
        if executable is None:
            raise ProcessError("DISPLAY is unset and Xvfb is unavailable")
        self.log_path.parent.mkdir(parents=True, exist_ok=True)
        self._log = self.log_path.open("wb")
        for number in range(90, 200):
            socket = Path(f"/tmp/.X11-unix/X{number}")
            if socket.exists():
                continue
            display = f":{number}"
            parent_signal_mask = signal.pthread_sigmask(
                signal.SIG_BLOCK, {signal.SIGINT, signal.SIGTERM},
            )
            try:
                self.child = subprocess.Popen(
                    [executable, display, "-screen", "0", "1280x720x24", "-nolisten", "tcp"],
                    stdout=self._log,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                    preexec_fn=lambda: signal.pthread_sigmask(
                        signal.SIG_SETMASK, parent_signal_mask,
                    ),
                )
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, parent_signal_mask)
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                if socket.exists():
                    self.display = display
                    return display
                if self.child.poll() is not None:
                    break
                time.sleep(0.05)
            self._stop()
        raise ProcessError("could not allocate an Xvfb display")

    def _stop(self) -> None:
        if self.child is not None:
            _stop_process_group(self.child, grace_seconds=3)
        self.child = None

    def __exit__(self, _kind: object, _value: object, _traceback: object) -> None:
        self._stop()
        if self._log is not None:
            self._log.close()
            self._log = None
