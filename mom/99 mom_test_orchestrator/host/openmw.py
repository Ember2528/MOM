from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
from typing import Any, Callable

import artifacts
import launch
import process
import results


class OpenMWError(RuntimeError):
    pass


def _build_metadata_object(value: object, fields: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict) or set(value) != fields:
        raise ValueError(f"{label} has an unsupported shape")
    return value


def _build_metadata_string(value: object, label: str, *, nullable: bool = False) -> None:
    if nullable and value is None:
        return
    if not isinstance(value, str) or not value:
        raise ValueError(f"{label} must be a nonempty string" + (" or null" if nullable else ""))


def _build_metadata_digest(value: object, length: int, label: str) -> None:
    if not isinstance(value, str) or re.fullmatch(rf"[0-9a-f]{{{length}}}", value) is None:
        raise ValueError(f"{label} must be a lowercase {length}-character hexadecimal digest")


def _validate_build_metadata(value: object) -> dict[str, Any]:
    metadata = _build_metadata_object(value, {
        "schemaVersion", "kind", "source", "patches", "build", "binary", "buildKey",
    }, "build metadata")
    if type(metadata["schemaVersion"]) is not int or metadata["schemaVersion"] != 1:
        raise ValueError("build metadata schemaVersion must be 1")
    if metadata["kind"] != "mom.openmw-build":
        raise ValueError("build metadata kind is unsupported")
    source = _build_metadata_object(metadata["source"], {
        "url", "ref", "commit", "mode",
    }, "source")
    _build_metadata_string(source["url"], "source.url", nullable=True)
    _build_metadata_string(source["ref"], "source.ref")
    _build_metadata_digest(source["commit"], 40, "source.commit")
    if source["mode"] not in ("managed", "explicit"):
        raise ValueError("source.mode must be managed or explicit")
    patches = metadata["patches"]
    if not isinstance(patches, list):
        raise ValueError("patches must be an array")
    for index, value in enumerate(patches):
        label = f"patches[{index}]"
        patch = _build_metadata_object(value, {"name", "sha256"}, label)
        _build_metadata_string(patch["name"], f"{label}.name")
        _build_metadata_digest(patch["sha256"], 64, f"{label}.sha256")
    build = _build_metadata_object(metadata["build"], {
        "type", "cmakeOptions", "cmake", "cCompiler", "cxxCompiler", "environment",
    }, "build")
    _build_metadata_string(build["type"], "build.type")
    if not isinstance(build["cmakeOptions"], list) or not all(
        isinstance(option, str) and option for option in build["cmakeOptions"]
    ):
        raise ValueError("build.cmakeOptions must be an array of nonempty strings")
    for name in ("cmake", "cCompiler", "cxxCompiler"):
        command = _build_metadata_object(build[name], {
            "command", "path", "version",
        }, f"build.{name}")
        _build_metadata_string(command["command"], f"build.{name}.command")
        for field in ("path", "version"):
            _build_metadata_string(command[field], f"build.{name}.{field}", nullable=True)
    environment = _build_metadata_object(build["environment"], {
        "CMAKE_GENERATOR", "CFLAGS", "CXXFLAGS", "LDFLAGS",
    }, "build.environment")
    if any(value is not None and not isinstance(value, str) for value in environment.values()):
        raise ValueError("build.environment values must be strings or null")
    binary = _build_metadata_object(metadata["binary"], {"sha256", "size"}, "binary")
    _build_metadata_digest(binary["sha256"], 64, "binary.sha256")
    if type(binary["size"]) is not int or binary["size"] < 0:
        raise ValueError("binary.size must be a non-negative integer")
    _build_metadata_digest(metadata["buildKey"], 64, "buildKey")
    inputs = {key: value for key, value in metadata.items() if key not in {"binary", "buildKey"}}
    encoded = (json.dumps(inputs, sort_keys=True, indent=2) + "\n").encode("utf-8")
    if metadata["buildKey"] != hashlib.sha256(encoded).hexdigest():
        raise ValueError("buildKey does not match the recorded build inputs")
    return metadata


def _engine_build_metadata(
    binary: Path,
    *,
    executable_sha256: str | None = None,
) -> dict[str, Any] | None:
    path = binary.parent / "mom-build-identity.json"
    try:
        path.lstat()
    except FileNotFoundError:
        return None
    except OSError as exc:
        raise OpenMWError(f"cannot inspect OpenMW build metadata {path}: {exc}") from exc
    try:
        metadata = _validate_build_metadata(results.load_json(path))
        expected = metadata["binary"]
        if expected["size"] != binary.stat().st_size or expected["sha256"] != (
            executable_sha256 or artifacts.sha256_file(binary)
        ):
            raise ValueError("metadata binary identity does not match the executable")
    except (OSError, ValueError) as exc:
        raise OpenMWError(f"invalid OpenMW build metadata {path}: {exc}") from exc
    return metadata


def engine_build_metadata(binary: Path) -> dict[str, Any] | None:
    """Read executable-bound builder records; source facts come from the builder."""
    return _engine_build_metadata(binary.resolve(strict=True))


def _openmw_version(binary: Path) -> str | None:
    try:
        completed = subprocess.run(
            [str(binary), "--version"],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    if completed.returncode != 0:
        return None
    identity_lines = [
        line.split("]", 1)[-1].strip()
        for line in completed.stdout.splitlines()
        if "OpenMW version " in line or "Revision: " in line
    ]
    return "; ".join(identity_lines) or None


def binary_identity(path: Path) -> dict[str, Any]:
    resolved = path.resolve(strict=True)
    if not resolved.is_file() or not os.access(resolved, os.X_OK):
        raise OpenMWError(f"OpenMW binary is not executable: {resolved}")
    build_id = None
    readelf = shutil.which("readelf")
    if readelf:
        try:
            completed = subprocess.run(
                [readelf, "--notes", str(resolved)],
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=30,
            )
            match = re.search(r"\bBuild ID:\s*([0-9a-fA-F]+)\b", completed.stdout)
            if match:
                build_id = match.group(1).lower()
        except (OSError, subprocess.SubprocessError):
            pass
    digest = artifacts.sha256_file(resolved)
    return {
        "path": str(resolved),
        "size": resolved.stat().st_size,
        "sha256": digest,
        "buildId": build_id,
        "version": _openmw_version(resolved),
        "buildMetadata": _engine_build_metadata(resolved, executable_sha256=digest),
    }


def prepare_embedded(
    *,
    harness_root: Path,
    work_directory: Path,
    raw_result: Path,
    launch_spec_path: Path,
    workload_ids: list[str],
    lane: str,
    samples: int,
    warmups: int,
    memory_evidence: bool,
    prepare_stdout: Path,
    prepare_stderr: Path,
    timeout_seconds: float,
    openmw_binary: Path | None = None,
    global_config: Path | None = None,
    base_config: Path | None = None,
    source_directory: Path | None = None,
    build_root: Path | None = None,
    build_openmw: bool | None = None,
    record_process: Callable[[dict[str, Any]], None] | None = None,
) -> tuple[dict[str, Any], dict[str, Any]]:
    command = launch.build_harness_command(launch.HarnessCommand(
        mode=lane,
        work_directory=work_directory,
        result_file=raw_result,
        workload_ids=tuple(workload_ids),
        samples=samples,
        warmups=warmups,
        memory_evidence=memory_evidence,
        launch_spec=launch_spec_path,
        openmw_binary=openmw_binary,
        global_config=global_config,
        base_config=base_config,
        source_directory=source_directory,
        build_root=build_root,
        build_openmw=build_openmw,
    ), harness=harness_root / "run_harness.sh")

    prepare_record = process.run_process(
        command,
        cwd=harness_root,
        environment=dict(os.environ),
        stdout_path=prepare_stdout,
        stderr_path=prepare_stderr,
        timeout_seconds=timeout_seconds,
    )
    if record_process is not None:
        record_process(prepare_record)
    if prepare_record["returnCode"] != 0 or prepare_record["timedOut"]:
        raise OpenMWError("OpenMW harness preparation failed; inspect prepare stderr")
    spec = results.load_json(launch_spec_path)
    try:
        launch.validate_launch_spec(spec)
    except launch.LaunchError as exc:
        raise OpenMWError(str(exc)) from exc
    exact_command = spec.get("command")
    paths = spec.get("paths")
    engine = spec.get("openmw")
    if (
        spec.get("performanceLane") != lane
    ):
        raise OpenMWError("harness launch specification lane is inconsistent")
    binary = Path(exact_command[0]).resolve(strict=True)
    if Path(engine.get("binary", "")).resolve(strict=True) != binary:
        raise OpenMWError("launch specification binary identity is inconsistent")
    if Path(paths.get("result", "")).resolve() != raw_result.resolve():
        raise OpenMWError("launch specification result path is inconsistent")
    engine["identity"] = binary_identity(binary)
    metadata = engine["identity"]["buildMetadata"]
    engine["harnessOwnedBuild"] = metadata is not None
    engine["sourceRef"] = metadata["source"]["commit"] if metadata else None
    engine["buildType"] = metadata["build"]["type"] if metadata else None
    engine["buildKey"] = metadata["buildKey"] if metadata else None
    return spec, prepare_record


def run_embedded(
    launch_spec: dict[str, Any],
    *,
    cwd: Path,
    stdout_path: Path,
    stderr_path: Path,
    xvfb_log: Path,
    timeout_seconds: float,
    cpu_set: set[int] | None,
    command_override: list[str] | None = None,
) -> dict[str, Any]:
    environment = dict(os.environ)
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    with process.VirtualDisplay(xvfb_log) as display:
        environment["DISPLAY"] = display
        return process.run_process(
            command_override or list(launch_spec["command"]),
            cwd=cwd,
            environment=environment,
            stdout_path=stdout_path,
            stderr_path=stderr_path,
            timeout_seconds=timeout_seconds,
            cpu_set=cpu_set,
        )


def retain_configuration(launch_spec: dict[str, Any], destination: Path) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    for key, name in (
        ("config", "openmw.cfg"),
        ("settings", "settings.cfg"),
        ("runOptions", "run_options.lua"),
    ):
        source = Path(launch_spec["paths"][key])
        if source.is_file():
            shutil.copy2(source, destination / name)


def retain_log(launch_spec: dict[str, Any], destination: Path) -> None:
    source = Path(launch_spec["paths"]["log"])
    if source.is_file():
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
