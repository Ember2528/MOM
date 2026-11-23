from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import time
from typing import Any, Sequence
import uuid

import artifacts
import correctness
import process
import scenario_inventory


HOST_ROOT = Path(__file__).resolve().parent
HARNESS_ROOT = HOST_ROOT.parent
PACKAGE_ROOT = HARNESS_ROOT.parent
REPOSITORY_ROOT = PACKAGE_ROOT.parent
MOM_DATA_DIR = PACKAGE_ROOT / "00 OpenMW"
HARNESS_DATA_DIR = HARNESS_ROOT
BUILD_ENTRYPOINT = HARNESS_ROOT / "harness_lib" / "build_openmw.sh"
WORKDIR_MARKER = ".mom_harness_workdir"
IDENTIFIER_PATTERN = re.compile(r"^[A-Za-z0-9_.:-]+$")
DEFAULT_SOURCE_URL = "https://gitlab.com/OursCodeur/openmw.git"
DEFAULT_SOURCE_REF = "clockwork-alpha"


class LaunchError(RuntimeError):
    pass


@dataclass(frozen=True)
class HarnessCommand:
    mode: str
    work_directory: Path
    result_file: Path
    scenarios: tuple[str, ...] = ()
    workload_ids: tuple[str, ...] = ()
    samples: int = 1
    warmups: int = 1
    memory_evidence: bool = False
    launch_spec: Path | None = None
    openmw_binary: Path | None = None
    global_config: Path | None = None
    base_config: Path | None = None
    source_directory: Path | None = None
    build_root: Path | None = None
    build_openmw: bool | None = None
    openmw_arguments: tuple[str, ...] = ()


def build_harness_command(
    request: HarnessCommand,
    *,
    harness: Path | None = None,
) -> list[str]:
    if request.mode not in {"correctness", "embedded", "integration"}:
        raise LaunchError(f"unsupported harness mode: {request.mode}")
    if request.mode == "correctness" and request.workload_ids:
        raise LaunchError("correctness launch cannot select performance workloads")
    if request.mode != "correctness" and request.scenarios:
        raise LaunchError("performance launch cannot select correctness scenarios")
    command = [
        str((harness or HARNESS_ROOT / "run_harness.sh").resolve()),
        "--workdir",
        str(request.work_directory.resolve()),
        "--result-file",
        str(request.result_file.resolve()),
    ]
    if request.mode == "correctness":
        for identifier in request.scenarios:
            command.extend(("--scenario", identifier))
    else:
        if request.launch_spec is None:
            raise LaunchError("performance launch requires a launch specification")
        command.extend((
            "--launch-spec",
            str(request.launch_spec.resolve()),
            "--performance-samples",
            str(request.samples),
            "--performance-warmups",
            str(request.warmups),
        ))
        if request.memory_evidence:
            command.append("--performance-memory-evidence")
        option = (
            "--integration-case"
            if request.mode == "integration"
            else "--performance-case"
        )
        if request.workload_ids:
            for identifier in request.workload_ids:
                command.extend((option, identifier))
        else:
            command.append(
                "--integration"
                if request.mode == "integration"
                else "--performance"
            )
    for option, value in (
        ("--openmw", request.openmw_binary),
        ("--global-config", request.global_config),
        ("--openmw-base-config", request.base_config),
        ("--openmw-source", request.source_directory),
        ("--openmw-build-root", request.build_root),
    ):
        if value is not None:
            command.extend((option, str(value.resolve())))
    if request.build_openmw is True:
        command.append("--build-openmw")
    elif request.build_openmw is False:
        command.append("--no-build-openmw")
    if request.openmw_arguments:
        command.append("--")
        command.extend(request.openmw_arguments)
    return command


def write_launch_spec(
    *,
    output: Path,
    performance_lane: str,
    command: list[str],
    openmw_binary: str,
    harness_owned_build: bool,
    source_ref: str | None,
    build_type: str | None,
    work_directory: Path,
    config: Path,
    settings: Path,
    run_options: Path,
    log: Path,
    result: Path,
) -> None:
    if not output.is_absolute():
        raise LaunchError(f"launch spec path must be absolute: {output}")
    value = {
        "schemaVersion": 1,
        "kind": "mom.harness.launch",
        "mode": "performance",
        "performanceLane": performance_lane,
        "command": command,
        "openmw": {
            "binary": openmw_binary,
            "harnessOwnedBuild": harness_owned_build,
            "sourceRef": source_ref,
            "buildType": build_type,
        },
        "paths": {
            "workdir": str(work_directory),
            "config": str(config),
            "settings": str(settings),
            "runOptions": str(run_options),
            "log": str(log),
            "result": str(result),
        },
    }
    validate_launch_spec(value)
    artifacts.write_json(output, value)


def validate_launch_spec(value: object) -> dict[str, Any]:
    fields = {
        "schemaVersion",
        "kind",
        "mode",
        "performanceLane",
        "command",
        "openmw",
        "paths",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise LaunchError(
            "harness launch specification has an unsupported shape"
        )
    if (
        value["schemaVersion"] != 1
        or value["kind"] != "mom.harness.launch"
        or value["mode"] != "performance"
    ):
        raise LaunchError(
            "harness launch specification schema/kind/mode is unsupported"
        )
    if value["performanceLane"] not in {"embedded", "integration"}:
        raise LaunchError(
            "harness launch specification lane is unsupported"
        )
    command = value["command"]
    if (
        not isinstance(command, list)
        or not command
        or not all(isinstance(argument, str) and argument for argument in command)
    ):
        raise LaunchError("harness launch specification command is invalid")
    engine = value["openmw"]
    if (
        not isinstance(engine, dict)
        or set(engine)
        != {"binary", "harnessOwnedBuild", "sourceRef", "buildType"}
        or not isinstance(engine["harnessOwnedBuild"], bool)
        or not isinstance(engine["binary"], str) or not engine["binary"]
        or not all(
            engine[field] is None or (isinstance(engine[field], str) and engine[field])
            for field in ("sourceRef", "buildType")
        )
    ):
        raise LaunchError(
            "harness launch specification OpenMW identity is invalid"
        )
    paths = value["paths"]
    expected_paths = {
        "workdir",
        "config",
        "settings",
        "runOptions",
        "log",
        "result",
    }
    if (
        not isinstance(paths, dict)
        or set(paths) != expected_paths
        or not all(
            isinstance(paths[field], str)
            and paths[field]
            and Path(paths[field]).is_absolute()
            for field in expected_paths
        )
    ):
        raise LaunchError("harness launch specification paths are invalid")
    return value


def _boolean(value: str, label: str) -> bool:
    normalized = value.strip().lower()
    if normalized in {"1", "true", "yes", "on"}:
        return True
    if normalized in {"0", "false", "no", "off", ""}:
        return False
    raise LaunchError(f"invalid {label} value: {value}")


def _decode_openmw_path(value: str) -> str:
    raw = value.strip()
    if not raw.startswith('"'):
        return raw
    out: list[str] = []
    index = 1
    while index < len(raw):
        char = raw[index]
        if char == '"':
            break
        if char == "&" and index + 1 < len(raw):
            index += 1
            char = raw[index]
        out.append(char)
        index += 1
    return "".join(out)


def _quote_openmw_path(path: Path) -> str:
    value = str(path).replace("&", "&&").replace('"', '&"')
    return f'"{value}"'


def _config_paths(path: Path, key: str) -> list[Path]:
    if not path.is_file():
        return []
    values: list[Path] = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        stripped = line.strip()
        prefix = f"{key}="
        if not stripped.startswith(prefix):
            continue
        decoded = _decode_openmw_path(stripped[len(prefix):])
        if not decoded:
            continue
        candidate = Path(decoded)
        if not candidate.is_absolute():
            candidate = path.parent / candidate
        values.append(candidate.resolve())
    return values


def find_morrowind_data_dir(global_config: Path) -> Path:
    for candidate in _config_paths(global_config, "data"):
        if all(
            (candidate / name).is_file()
            for name in ("Morrowind.esm", "Tribunal.esm", "Bloodmoon.esm")
        ):
            return candidate
    raise LaunchError(
        "could not find one global data= path containing Morrowind.esm, "
        f"Tribunal.esm, and Bloodmoon.esm in {global_config}"
    )


def _usable_base_config(path: Path) -> bool:
    return path.is_file() and any(
        (candidate / "vfs-mw").is_dir()
        for candidate in _config_paths(path, "resources")
    )


def _resolve_executable(value: str | Path, *, strict: bool = True) -> Path:
    requested = Path(value)
    if requested.parent == Path("."):
        found = shutil.which(str(value))
        if found is None:
            if strict:
                raise LaunchError(f"OpenMW executable is unavailable: {value}")
            return requested
        requested = Path(found)
    try:
        resolved = requested.resolve(strict=strict)
    except OSError as exc:
        raise LaunchError(f"OpenMW executable is unavailable: {value}") from exc
    if strict and (not resolved.is_file() or not os.access(resolved, os.X_OK)):
        raise LaunchError(f"OpenMW executable is not executable: {resolved}")
    return resolved


def resolve_global_config(explicit: Path | None = None) -> Path:
    if explicit is None:
        configured = os.environ.get("OPENMW_GLOBAL_CONFIG")
        config_home = Path(os.environ.get(
            "XDG_CONFIG_HOME", str(Path.home() / ".config")
        ))
        explicit = Path(configured) if configured else config_home / "openmw/openmw.cfg"
    return explicit.resolve(strict=True)


def resolve_base_config(
    explicit: Path | None,
    openmw_binary: str | Path,
) -> Path:
    if explicit is None and os.environ.get("MOM_HARNESS_OPENMW_BASE_CONFIG"):
        explicit = Path(os.environ["MOM_HARNESS_OPENMW_BASE_CONFIG"])
    if explicit is not None:
        candidate = explicit.resolve(strict=True)
        if not _usable_base_config(candidate):
            raise LaunchError(
                "OpenMW base config has no usable resources= directory: "
                f"{candidate}"
            )
        return candidate
    binary = _resolve_executable(openmw_binary, strict=False)
    candidates = (
        binary.parent / "openmw.cfg",
        binary.parent.parent / "etc" / "openmw" / "openmw.cfg",
        binary.parent.parent.parent / "etc" / "openmw" / "openmw.cfg",
        Path("/etc/openmw/openmw.cfg"),
        Path("/usr/local/etc/openmw/openmw.cfg"),
    )
    for candidate in candidates:
        if _usable_base_config(candidate):
            return candidate.resolve()
    raise LaunchError(
        "could not find clean OpenMW base config with resources= data"
    )


def default_workdir(label: str) -> Path:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    return Path(os.environ.get("TMPDIR", "/tmp")) / (
        f"mom-{label}-{stamp}-{uuid.uuid4().hex[:8]}"
    )


def validate_workdir(path: Path, repository_root: Path = REPOSITORY_ROOT) -> Path:
    if not path.is_absolute():
        raise LaunchError(f"workdir must be absolute: {path}")
    root = path.resolve()
    repository = repository_root.resolve()
    protected = {Path("/"), Path("/tmp"), Path("/var/tmp"), Path.home().resolve()}
    if (root in protected or root == repository or repository in root.parents
            or root in repository.parents):
        raise LaunchError(f"refusing unsafe workdir: {root}")
    return root


def prepare_workdir(
    path: Path,
    repository_root: Path = REPOSITORY_ROOT,
    *,
    marker: str = WORKDIR_MARKER,
) -> Path:
    root = validate_workdir(path, repository_root)
    try:
        root.mkdir(parents=True, exist_ok=False)
    except FileExistsError as exc:
        raise LaunchError(
            f"workdir already exists; choose an unused --workdir to preserve results: {root}"
        ) from exc
    (root / "config").mkdir()
    (root / "userdata" / "data").mkdir(parents=True)
    (root / marker).write_text("", encoding="utf-8")
    return root


def _lua_quote(value: str) -> str:
    if "\n" in value or "\r" in value:
        raise LaunchError("Lua string contains a newline")
    return "'" + value.replace("\\", "\\\\").replace("'", "\\'") + "'"


def write_run_options(
    path: Path,
    *,
    mode: str,
    scenarios: Sequence[str],
    result_file: Path,
    performance_lane: str,
    workloads: Sequence[str],
    samples: int,
    warmups: int,
    memory_evidence: bool,
    start_delay_frames: int,
) -> None:
    for identifier in (*scenarios, *workloads):
        if IDENTIFIER_PATTERN.fullmatch(identifier) is None:
            raise LaunchError(f"invalid harness identifier: {identifier}")
    lines = ["return {", f"  mode = {_lua_quote(mode)},"]
    if scenarios:
        lines.append("  scenarios = {")
        lines.extend(f"    {_lua_quote(item)}," for item in scenarios)
        lines.append("  },")
    else:
        lines.append("  scenarios = nil,")
    if mode == "performance":
        lines.extend((
            "  performance = {",
            f"    resultFile = {_lua_quote(str(result_file))},",
            f"    lane = {_lua_quote(performance_lane)},",
            f"    samples = {samples},",
            f"    warmups = {warmups},",
            f"    memoryEvidence = {str(memory_evidence).lower()},",
            f"    startDelayFrames = {start_delay_frames},",
        ))
        if workloads:
            lines.append("    workloads = {")
            lines.extend(f"      {_lua_quote(item)}," for item in workloads)
            lines.append("    },")
        else:
            lines.append("    workloads = nil,")
        lines.append("  },")
    else:
        lines.append("  performance = nil,")
    lines.append("}")
    artifacts.atomic_write(path, ("\n".join(lines) + "\n").encode("utf-8"))


def _base_config_lines(path: Path) -> list[str]:
    prefixes = ("resources=", "data=", "fallback=", "encoding=")
    lines = []
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line.startswith(prefixes):
            continue
        key, value = line.split("=", 1)
        if key in {"resources", "data"}:
            candidate = Path(_decode_openmw_path(value))
            if not candidate.is_absolute():
                candidate = path.parent / candidate
            line = key + "=" + _quote_openmw_path(candidate.resolve())
        lines.append(line)
    return lines


def write_config(
    path: Path,
    *,
    base_config: Path,
    morrowind_data: Path,
    user_data: Path,
    generated_data: Path,
    script_content: Sequence[str] = (
        "mom.omwscripts", "mom_test_orchestrator.omwscripts"
    ),
) -> None:
    lines = [
        "# Generated by mom_test_orchestrator/host/launch.py. Delete freely.",
        "replace=data",
        "replace=content",
        "replace=fallback-archive",
        "replace=groundcover",
        f"user-data={_quote_openmw_path(user_data)}",
        f"data-local={_quote_openmw_path(user_data / 'data')}",
        *_base_config_lines(base_config),
        "skip-menu=1",
        "new-game=0",
        "no-sound=1",
        f"data={_quote_openmw_path(morrowind_data)}",
        f"data={_quote_openmw_path(MOM_DATA_DIR)}",
        f"data={_quote_openmw_path(HARNESS_DATA_DIR)}",
        f"data={_quote_openmw_path(generated_data)}",
        "fallback-archive=Morrowind.bsa",
        "fallback-archive=Tribunal.bsa",
        "fallback-archive=Bloodmoon.bsa",
        "content=Morrowind.esm",
        "content=Tribunal.esm",
        "content=Bloodmoon.esm",
        *(f"content={name}" for name in script_content),
    ]
    artifacts.atomic_write(path, ("\n".join(lines) + "\n").encode("utf-8"))


def write_settings(path: Path, unsafe_stdlib: bool) -> None:
    if not unsafe_stdlib:
        return
    artifacts.atomic_write(
        path,
        (
            "# Generated by mom_test_orchestrator/host/launch.py. Delete freely.\n"
            "[Lua]\n"
            "unsafe stdlib access = true\n"
        ).encode("utf-8"),
    )


def _build_openmw(
    *,
    work_directory: Path,
    source_url: str,
    source_ref: str,
    source_directory: Path | None,
    patch_directory: Path,
    build_root: Path,
    build_type: str,
    build_jobs: str | None,
) -> Path:
    result = work_directory / "openmw-build-result.txt"
    environment = dict(os.environ)
    environment.update({
        "MOM_HARNESS_OPENMW_SOURCE_URL": source_url,
        "MOM_HARNESS_OPENMW_SOURCE_REF": source_ref,
        "MOM_HARNESS_OPENMW_PATCH_DIR": str(patch_directory),
        "MOM_HARNESS_OPENMW_BUILD_ROOT": str(build_root),
        "MOM_HARNESS_OPENMW_BUILD_TYPE": build_type,
    })
    if source_directory is not None:
        environment["MOM_HARNESS_OPENMW_SOURCE_DIR"] = str(source_directory)
    else:
        environment.pop("MOM_HARNESS_OPENMW_SOURCE_DIR", None)
    if build_jobs is not None:
        environment["MOM_HARNESS_OPENMW_BUILD_JOBS"] = build_jobs
    command = [str(BUILD_ENTRYPOINT), "--result-file", str(result)]
    completed = process.run_process(
        command,
        cwd=HARNESS_ROOT,
        environment=environment,
        stdout_path=None,
        stderr_path=None,
        timeout_seconds=None,
        termination_grace_seconds=5,
    )
    if completed["returnCode"] != 0 or not result.is_file():
        raise LaunchError("harness-owned OpenMW build failed")
    return Path(result.read_text(encoding="utf-8").strip()).resolve(strict=True)


def _positive(value: int, label: str, *, zero: bool = False) -> int:
    if isinstance(value, bool) or value < (0 if zero else 1):
        qualifier = "non-negative" if zero else "positive"
        raise LaunchError(f"{label} must be a {qualifier} integer")
    return value


def _selected_mode(arguments: argparse.Namespace) -> tuple[str, list[str]]:
    embedded = arguments.performance or bool(arguments.performance_case)
    integration = arguments.integration or bool(arguments.integration_case)
    if embedded and integration:
        raise LaunchError(
            "embedded and integration workloads cannot be combined"
        )
    if integration:
        return "integration", list(arguments.integration_case)
    if embedded:
        return "embedded", list(arguments.performance_case)
    return "correctness", []


def _build_policy(build_openmw: bool | None) -> bool:
    if build_openmw is not None:
        return build_openmw
    configured = os.environ.get("MOM_HARNESS_BUILD_OPENMW", "auto")
    if configured.strip().lower() in {"auto", ""}:
        return False
    return _boolean(configured, "MOM_HARNESS_BUILD_OPENMW")


def resolve_openmw_binary(
    openmw: Path | None,
    *,
    work_directory: Path,
    build_openmw: bool | None = None,
    source_directory: Path | None = None,
    build_root: Path | None = None,
    dry_run: bool = False,
) -> Path:
    """Resolve or build once using an already prepared work directory."""
    if not _build_policy(build_openmw):
        if source_directory is not None or build_root is not None:
            raise LaunchError("source/build directory options require --build-openmw")
        return _resolve_executable(
            openmw if openmw is not None else os.environ.get("OPENMW_BIN", "openmw"),
            strict=not dry_run,
        )
    if dry_run:
        raise LaunchError("engine provisioning requires execution; select an existing --openmw for planning")
    source_directory = source_directory or (
        Path(os.environ["MOM_HARNESS_OPENMW_SOURCE_DIR"])
        if os.environ.get("MOM_HARNESS_OPENMW_SOURCE_DIR") else None
    )
    cache_home = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home() / ".cache")))
    build_root = build_root or Path(os.environ.get(
        "MOM_HARNESS_OPENMW_BUILD_ROOT", str(cache_home / "mom-openmw-harness/openmw")
    ))
    return _build_openmw(
        work_directory=work_directory,
        source_url=os.environ.get("MOM_HARNESS_OPENMW_SOURCE_URL", DEFAULT_SOURCE_URL),
        source_ref=os.environ.get("MOM_HARNESS_OPENMW_SOURCE_REF", DEFAULT_SOURCE_REF),
        source_directory=source_directory,
        patch_directory=Path(os.environ.get(
            "MOM_HARNESS_OPENMW_PATCH_DIR", str(HARNESS_ROOT / "openmw_patches")
        )).resolve(),
        build_root=build_root.resolve(),
        build_type=os.environ.get("MOM_HARNESS_OPENMW_BUILD_TYPE", "RelWithDebInfo"),
        build_jobs=os.environ.get("MOM_HARNESS_OPENMW_BUILD_JOBS"),
    )


def run(arguments: argparse.Namespace) -> int:
    mode, workloads = _selected_mode(arguments)
    catalog = scenario_inventory.load_catalog(HARNESS_ROOT)
    if mode != "correctness" and (arguments.scenario or arguments.suite):
        raise LaunchError("performance workloads cannot select correctness scenarios")
    scenarios = (catalog.select(arguments.scenario, arguments.suite)
                 if mode == "correctness" else [])
    for identifier in (*scenarios, *workloads):
        if IDENTIFIER_PATTERN.fullmatch(identifier) is None:
            raise LaunchError(f"invalid harness identifier: {identifier}")

    arguments.unsafe_stdlib = (
        True if mode != "correctness" else arguments.unsafe_stdlib
    )
    _positive(arguments.performance_samples, "performance samples")
    _positive(
        arguments.performance_warmups,
        "performance warmups",
        zero=True,
    )
    _positive(
        arguments.performance_start_delay,
        "performance start delay",
        zero=True,
    )
    if (
        mode != "correctness"
        and not arguments.dry_run
        and arguments.launch_spec is None
    ):
        raise LaunchError(
            "performance execution is owned by host/mom_harness.py; "
            "direct harness performance runs are unsupported"
        )
    if arguments.launch_spec is not None and mode == "correctness":
        raise LaunchError(
            "launch specs are supported only for performance mode"
        )

    global_config = resolve_global_config(arguments.global_config)
    for required, label in (
        (MOM_DATA_DIR / "mom.omwscripts", "MOM script registration"),
        (
            HARNESS_DATA_DIR / "mom_test_orchestrator.omwscripts",
            "harness script registration",
        ),
    ):
        if not required.exists():
            raise LaunchError(f"{label} missing: {required}")
    morrowind_data = find_morrowind_data_dir(global_config)
    work_directory = validate_workdir(arguments.workdir)
    config_directory = work_directory / "config"
    user_data = work_directory / "userdata"
    generated_data = work_directory / "generated-data"
    config_file = config_directory / "openmw.cfg"
    settings_file = config_directory / "settings.cfg"
    log_file = config_directory / "openmw.log"
    result_file = arguments.result_file or work_directory / "result.json"
    if mode != "correctness" and not result_file.is_absolute():
        raise LaunchError(
            f"performance result path must be absolute: {result_file}"
        )
    result_file = result_file.resolve()

    source_ref = os.environ.get(
        "MOM_HARNESS_OPENMW_SOURCE_REF",
        DEFAULT_SOURCE_REF,
    )
    build_type = os.environ.get(
        "MOM_HARNESS_OPENMW_BUILD_TYPE",
        "RelWithDebInfo",
    )
    build_active = _build_policy(arguments.build_openmw)
    # A plan names provisioning as a separate action. It never invokes the
    # builder, writes a config, or removes an earlier run.
    if arguments.dry_run and build_active:
        print(f"Run directory: {work_directory}")
        print(f"Morrowind data: {morrowind_data}")
        print(f"Engine preparation required: {source_ref} ({build_type})")
        print("Build explicitly, then repeat with --openmw PATH to inspect the exact launch command.")
        if scenarios:
            print(f"Scenario filter: {' '.join(scenarios)}")
        return 0
    if build_active:
        prepare_workdir(work_directory)
    openmw_binary = resolve_openmw_binary(
        arguments.openmw,
        work_directory=work_directory,
        build_openmw=arguments.build_openmw,
        source_directory=arguments.openmw_source,
        build_root=arguments.openmw_build_root,
        dry_run=arguments.dry_run,
    )
    # Imported here because the engine adapter also uses this launcher.
    import openmw

    try:
        build_metadata = (
            openmw.engine_build_metadata(Path(openmw_binary))
            if Path(openmw_binary).is_file() else None
        )
    except openmw.OpenMWError as exc:
        raise LaunchError(str(exc)) from exc
    source_ref = build_metadata["source"]["commit"] if build_metadata else None
    build_type = build_metadata["build"]["type"] if build_metadata else None

    base_config = resolve_base_config(arguments.openmw_base_config, openmw_binary)
    if not arguments.dry_run:
        if not build_active:
            prepare_workdir(work_directory)
        fixture_scenarios = (scenarios if mode == "correctness" else
                             catalog.integration if mode == "integration" else [])
        fixture_paths = catalog.stage(HARNESS_ROOT, generated_data, fixture_scenarios)
        print(f"Staged authored fixtures: {len(fixture_paths)}")

        write_run_options(
            generated_data / "scripts" / "mom_test_orchestrator"
            / "run_options.lua",
            mode="performance" if mode != "correctness" else "correctness",
            scenarios=scenarios,
            result_file=result_file,
            performance_lane=mode if mode != "correctness" else "embedded",
            workloads=workloads,
            samples=arguments.performance_samples,
            warmups=arguments.performance_warmups,
            memory_evidence=arguments.performance_memory_evidence,
            start_delay_frames=arguments.performance_start_delay,
        )
        write_settings(settings_file, arguments.unsafe_stdlib)

        write_config(
            config_file,
            base_config=base_config,
            morrowind_data=morrowind_data,
            user_data=user_data,
            generated_data=generated_data,
        )

    # argparse retains the harness separator; OpenMW would treat every option
    # after it as positional instead of loading the requested save and overlays.
    engine_arguments = arguments.openmw_arguments
    if engine_arguments[:1] == ["--"]:
        engine_arguments = engine_arguments[1:]
    command = [
        str(openmw_binary),
        "--config",
        str(config_directory),
        "--replace=config",
        "--user-data",
        str(user_data),
        *engine_arguments,
    ]
    print(f"Harness config: {config_file}")
    if arguments.unsafe_stdlib:
        print(f"Harness settings: {settings_file}")
    print(f"Harness user data: {user_data}")
    print(f"Harness log: {log_file}")
    print(f"Harness result JSON: {result_file}")
    print(f"Morrowind data: {morrowind_data}")
    print(f"OpenMW base config: {base_config}")
    if scenarios:
        print(f"Scenario filter: {' '.join(scenarios)}")
    if mode != "correctness":
        print("Harness mode: performance")
        print(f"Performance lane: {mode}")
        print(f"Performance cases: {' '.join(workloads) if workloads else 'all'}")
        print(
            "Performance samples/warmups: "
            f"{arguments.performance_samples}/"
            f"{arguments.performance_warmups}"
        )
        print(
            "Performance memory evidence: "
            f"{int(arguments.performance_memory_evidence)}"
        )
    if arguments.dry_run:
        print(f"Command: {shlex.join(command)}")
        return 0
    if arguments.launch_spec is not None:
        write_launch_spec(
            output=arguments.launch_spec,
            performance_lane=mode,
            command=command,
            openmw_binary=str(openmw_binary),
            harness_owned_build=build_metadata is not None,
            source_ref=source_ref,
            build_type=build_type,
            work_directory=work_directory,
            config=config_file,
            settings=settings_file,
            run_options=(
                generated_data / "scripts" / "mom_test_orchestrator"
                / "run_options.lua"
            ),
            log=log_file,
            result=result_file,
        )
        print(f"Harness launch spec: {arguments.launch_spec}")
        return 0

    print("Launching OpenMW harness...", flush=True)
    started = time.perf_counter()
    completed = process.run_process(
        command,
        cwd=REPOSITORY_ROOT,
        environment=dict(os.environ),
        stdout_path=None,
        stderr_path=None,
        timeout_seconds=None,
        termination_grace_seconds=5,
    )
    return_code = int(completed["returnCode"])
    elapsed_seconds = time.perf_counter() - started
    print(f"OpenMW exited: {return_code}")
    result = correctness.build_result(
        log_path=log_file,
        work_directory=work_directory,
        selected_scenarios=scenarios,
        openmw_status=return_code,
        elapsed_seconds=elapsed_seconds,
    )
    artifacts.write_json(result_file, result)
    if result["kind"] == "mom.process-campaign.phase-receipt":
        print(
            "Harness campaign phase receipt: "
            f"status={result['status']} scenario={result['scenario']}"
        )
    else:
        print(
            "Harness result: "
            f"status={result['status']} "
            f"passed={result['passed'] if result['passed'] is not None else 'unknown'} "
            f"failed={result['failed'] if result['failed'] is not None else 'unknown'} "
            f"total={result['total'] if result['total'] is not None else 'unknown'}"
        )
    if return_code != 0:
        return return_code
    if result["status"] == "passed":
        return 0
    print("ERROR: harness did not report a passing result", file=sys.stderr)
    return 1


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="Prepare and launch the MOM OpenMW harness"
    )
    value.add_argument("--dry-run", action="store_true",
                       help="print the launch plan without writing files, building, or launching")
    value.add_argument("--global-config", type=Path)
    value.add_argument("--openmw-base-config", type=Path)
    value.add_argument(
        "--workdir",
        type=Path,
        default=Path(os.environ.get(
            "MOM_HARNESS_WORKDIR",
            str(default_workdir("world")),
        )),
    )
    value.add_argument("--openmw", type=Path)
    build = value.add_mutually_exclusive_group()
    build.add_argument(
        "--build-openmw",
        dest="build_openmw",
        action="store_true",
    )
    build.add_argument(
        "--no-build-openmw",
        dest="build_openmw",
        action="store_false",
    )
    value.set_defaults(build_openmw=None)
    standard = value.add_mutually_exclusive_group()
    standard.add_argument(
        "--unsafe-stdlib",
        dest="unsafe_stdlib",
        action="store_true",
    )
    standard.add_argument(
        "--safe-stdlib",
        dest="unsafe_stdlib",
        action="store_false",
    )
    value.set_defaults(
        unsafe_stdlib=_boolean(
            os.environ.get("MOM_HARNESS_UNSAFE_STDLIB_ACCESS", "0"),
            "MOM_HARNESS_UNSAFE_STDLIB_ACCESS",
        )
    )
    value.add_argument("--openmw-source", type=Path)
    value.add_argument("--openmw-build-root", type=Path)
    value.add_argument("--scenario", action="append", default=[])
    value.add_argument("--suite", action="append", default=[],
                       help="ordinary (default), smoke, stress, or all")
    value.add_argument("--performance", action="store_true")
    value.add_argument("--performance-case", action="append", default=[])
    value.add_argument("--integration", action="store_true")
    value.add_argument("--integration-case", action="append", default=[])
    value.add_argument("--performance-samples", type=int, default=1)
    value.add_argument("--performance-warmups", type=int, default=1)
    value.add_argument(
        "--performance-memory-evidence",
        action="store_true",
    )
    value.add_argument("--performance-start-delay", type=int, default=5)
    value.add_argument("--result-file", type=Path)
    value.add_argument("--launch-spec", type=Path)
    value.add_argument("openmw_arguments", nargs=argparse.REMAINDER)
    return value


def main(argv: Sequence[str] | None = None) -> int:
    try:
        with process.cancellation_signals():
            return run(parser().parse_args(argv))
    except KeyboardInterrupt as exc:
        print(f"OpenMW harness cancelled: {exc}", file=sys.stderr)
        return 128 + getattr(exc, "signum", 2)
    except (
        LaunchError,
        scenario_inventory.ScenarioInventoryError,
        correctness.CorrectnessError,
        process.ProcessError,
        OSError,
        subprocess.SubprocessError,
    ) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
