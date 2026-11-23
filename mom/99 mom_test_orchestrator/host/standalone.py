"""Run pure contracts on LuaJIT or the harness-owned OpenMW runtime.

OpenMW's Luau target has its own runtime bindings. A stock Luau CLI is
therefore not an equivalent execution lane.
The native lane snapshots source bytes, then loads each original module with
openmw.util.loadCode. Only test package/loadfile and source-file IO are supplied.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

import launch
import process


HARNESS_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = HARNESS_ROOT.parent.parent
RESULT_MARKER = "MOM_PURE_RESULT:"


def native_result_passed(status: int, log: str) -> bool:
    receipts = [line.split(RESULT_MARKER, 1)[1].strip()
                for line in log.splitlines() if RESULT_MARKER in line]
    return status == 0 and receipts == ["passed"]


def lua_string(value: str) -> str:
    # Fixed-width decimal escapes also preserve CRLF and prevent a following
    # digit from becoming part of an escape. No source text becomes host code.
    escaped = []
    for character in value:
        if character in ('"', "\\"):
            escaped.append("\\" + character)
        elif ord(character) < 32 or ord(character) == 127:
            escaped.append(f"\\{ord(character):03d}")
        else:
            escaped.append(character)
    return '"' + "".join(escaped) + '"'


def source_snapshot(repository: Path) -> tuple[dict[str, str], dict[str, str]]:
    sources: dict[str, str] = {}
    modules: dict[str, str] = {}
    for directory in (repository / "mom/00 OpenMW", repository / "mom/99 mom_test_orchestrator"):
        for path in sorted(directory.rglob("*.lua")):
            absolute = str(path)
            sources[absolute] = path.read_bytes().decode("utf-8")
            name = path.relative_to(directory).with_suffix("").as_posix().replace("/", ".")
            modules.setdefault(name, absolute)
    manifest = repository / "mom/00 OpenMW/mom.omwscripts"
    sources[str(manifest)] = manifest.read_bytes().decode("utf-8")
    return sources, modules


def native_script(repository: Path, *, stress: bool = False, stress_only: bool = False) -> str:
    sources, modules = source_snapshot(repository)
    snapshot = "local sources = {\n" + "".join(
        f"[{lua_string(path)}] = {lua_string(source)},\n" for path, source in sources.items()
    ) + "}\nlocal modules = {\n" + "".join(
        f"[{lua_string(name)}] = {lua_string(path)},\n" for name, path in modules.items()
    ) + "}\n"
    bootstrap = (HARNESS_ROOT / "pure/native_bootstrap.lua").read_text(encoding="utf-8")
    arguments = [str(repository)] + (["--stress-only"] if stress_only else ["--stress"] if stress else [])
    return snapshot + "local arguments = {" + ",".join(map(lua_string, arguments)) + "}\n" + bootstrap


def run_native(arguments: argparse.Namespace) -> int:
    binary = launch._resolve_executable(arguments.openmw)
    workdir = launch.prepare_workdir(arguments.workdir)
    generated = workdir / "generated-data"
    script = generated / "scripts/mom_test_orchestrator/pure_native.lua"
    script.parent.mkdir(parents=True, exist_ok=True)
    script.write_text(native_script(arguments.repo_root, stress=arguments.stress, stress_only=arguments.stress_only), encoding="utf-8")
    (generated / "mom_pure.omwscripts").write_text(
        "GLOBAL: scripts/mom_test_orchestrator/pure_native.lua\n", encoding="utf-8"
    )
    global_config = launch.resolve_global_config(arguments.global_config)
    base = launch.resolve_base_config(arguments.openmw_base_config, str(binary))
    config = workdir / "config/openmw.cfg"
    launch.write_config(config, base_config=base,
                        morrowind_data=launch.find_morrowind_data_dir(global_config),
                        user_data=workdir / "userdata", generated_data=generated,
                        script_content=("mom_pure.omwscripts",))
    (workdir / "config/settings.cfg").write_text(
        "[Lua]\nunsafe stdlib access = true\nexecution time limit per call = 0\n"
        "instruction limit per call = 0\n"
        "memory limit = 0\n", encoding="utf-8"
    )
    command = [str(binary), "--config", str(workdir / "config"), "--replace=config",
               "--user-data", str(workdir / "userdata")]
    completed = run_process(command, arguments.timeout)
    if completed["timedOut"]:
        return 124
    log = (workdir / "config/openmw.log").read_text(encoding="utf-8", errors="replace")
    if native_result_passed(int(completed["returnCode"]), log):
        return 0
    print(f"Pure native contracts failed; see {workdir / 'config/openmw.log'}", file=sys.stderr)
    return 1


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description=__doc__)
    value.add_argument("--lua", default=os.environ.get("LUA", "luajit"))
    value.add_argument("--repo-root", type=Path, default=REPOSITORY_ROOT)
    scale = value.add_mutually_exclusive_group()
    scale.add_argument("--stress", action="store_true")
    scale.add_argument("--stress-only", action="store_true", help="run only the tagged scaled cases")
    value.add_argument("--openmw", type=Path, help="run in this harness-owned OpenMW runtime")
    value.add_argument("--openmw-base-config", type=Path)
    value.add_argument("--global-config", type=Path)
    value.add_argument("--workdir", type=Path, default=launch.default_workdir("pure"))
    value.add_argument("--timeout", type=float, default=300)
    return value


def run_process(command: list[str], timeout_seconds: float) -> dict[str, object]:
    return process.run_process(
        command,
        cwd=REPOSITORY_ROOT,
        environment=dict(os.environ),
        stdout_path=None,
        stderr_path=None,
        timeout_seconds=timeout_seconds,
        termination_grace_seconds=5,
    )


def main() -> int:
    arguments = parser().parse_args()
    arguments.repo_root = arguments.repo_root.resolve(strict=True)
    if arguments.openmw is not None:
        return run_native(arguments)
    executable = shutil.which(arguments.lua)
    if executable is None:
        raise ValueError(f"Lua executable is unavailable: {arguments.lua}")
    if "luau" in Path(executable).name.lower():
        raise ValueError("Use --openmw with the harness-owned Luau engine; stock Luau omits OpenMW's runtime bindings")
    command = [executable, str(HARNESS_ROOT / "pure/run.lua"), str(arguments.repo_root)]
    if arguments.stress_only:
        command.append("--stress-only")
    elif arguments.stress:
        command.append("--stress")
    completed = run_process(command, arguments.timeout)
    return 124 if completed["timedOut"] else int(completed["returnCode"])


if __name__ == "__main__":
    try:
        with process.cancellation_signals():
            raise SystemExit(main())
    except KeyboardInterrupt as error:
        print(f"Pure contracts cancelled: {error}", file=sys.stderr)
        raise SystemExit(128 + getattr(error, "signum", 2))
    except (ValueError, OSError, subprocess.SubprocessError, launch.LaunchError,
            process.ProcessError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1)
