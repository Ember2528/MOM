#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import platform
import shutil
import signal
import subprocess
import sys
import time
from typing import Any

HOST_ROOT = Path(__file__).resolve().parent
if str(HOST_ROOT) not in sys.path:
    sys.path.insert(0, str(HOST_ROOT))

import artifacts
import examples
import openmw
import perf_capture
import process
import results
import validation


HARNESS_ROOT = HOST_ROOT.parent
REPOSITORY_ROOT = HARNESS_ROOT.parent.parent
PERFORMANCE_ROOT = HARNESS_ROOT / "performance"
DEFAULT_ARTIFACT_ROOT = Path(
    os.environ.get("MOM_HARNESS_ARTIFACT_ROOT", f"{os.environ.get('TMPDIR', '/tmp')}/mom-performance-artifacts")
)
TIMING_CONTRACT_VERSION = 2
MODE_ENTRYPOINT_SOURCES = {
    "standalone": "performance/standalone.lua",
    "embedded": "scripts/mom_test_orchestrator/performance/engine_entrypoint.lua",
    "integration": "scripts/mom_test_orchestrator/performance/engine_entrypoint.lua",
}
ALLOCATION_ENTRYPOINT_SOURCE = "performance/allocation.lua"
ALLOCATION_PROBE_SOURCE = (
    "scripts/mom_test_orchestrator/performance/allocation_probe.lua"
)


class HarnessError(RuntimeError):
    pass


def command_output(command: list[str]) -> str | None:
    try:
        completed = subprocess.run(
            command,
            cwd=REPOSITORY_ROOT,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.SubprocessError):
        return None
    return completed.stdout.strip() if completed.returncode == 0 else None


def git_identity() -> dict[str, Any]:
    status = command_output(["git", "status", "--porcelain=v1"])
    return {
        "commit": command_output(["git", "rev-parse", "HEAD"]),
        "branch": command_output(["git", "branch", "--show-current"]),
        "dirty": bool(status),
    }


def cpu_model() -> str:
    try:
        for line in Path("/proc/cpuinfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("model name") and ":" in line:
                return line.split(":", 1)[1].strip()
    except OSError:
        pass
    return platform.processor() or "unknown"


def cpu_governors(cpu_list: str | None) -> list[str]:
    if not cpu_list:
        return ["unknown"]
    cpus = process.parse_cpu_set(cpu_list)
    values: set[str] = set()
    for cpu in cpus or set():
        path = Path(f"/sys/devices/system/cpu/cpu{cpu}/cpufreq/scaling_governor")
        try:
            values.add(path.read_text(encoding="utf-8").strip() or "unknown")
        except OSError:
            values.add("unknown")
    return sorted(values) or ["unknown"]


def file_contract_identity() -> dict[str, str]:
    return {
        "workloadsSha256": artifacts.sha256_file(PERFORMANCE_ROOT / "workloads.json"),
        "profilesSha256": artifacts.sha256_file(PERFORMANCE_ROOT / "profiles.json"),
        "budgetsSha256": artifacts.sha256_file(PERFORMANCE_ROOT / "budgets.json"),
        "harnessTreeSha256": artifacts.tree_digest([
            HARNESS_ROOT / "scripts" / "mom_test_orchestrator" / "performance",
            PERFORMANCE_ROOT,
            HARNESS_ROOT / "run_harness.sh",
            HARNESS_ROOT / "harness_lib" / "build_openmw.sh",
            HARNESS_ROOT / "harness_lib" / "openmw_environment.sh",
            HOST_ROOT / "correctness.py",
            HOST_ROOT / "launch.py",
            HOST_ROOT / "mom_harness.py",
            HOST_ROOT / "openmw.py",
            HOST_ROOT / "process.py",
            HOST_ROOT / "results.py",
            HOST_ROOT / "statistics.py",
            HOST_ROOT / "artifacts.py",
            HOST_ROOT / "perf_capture.py",
        ]),
        "productionTreeSha256": artifacts.tree_digest([
            REPOSITORY_ROOT / "mom" / "00 OpenMW" / "scripts" / "mom"
        ]),
    }


def selected_workload_contract_identity(
    selected: list[dict[str, Any]],
    mode: str,
    budgets: dict[str, Any],
    contract_root: Path = HARNESS_ROOT,
) -> str:
    clock = "process_cpu" if mode == "standalone" else "monotonic_wall"
    clock_budgets = budgets["absoluteMicros"][clock]
    memory_budgets = budgets["absoluteMemoryKb"][mode]
    root = contract_root.resolve(strict=True)
    entrypoint = MODE_ENTRYPOINT_SOURCES.get(mode)
    if entrypoint is None:
        raise HarnessError(f"unsupported workload mode: {mode}")
    source_names = {
        source
        for workload in selected
        for source in workload["contractSources"]
    } | {entrypoint}
    if mode == "standalone":
        source_names.add(ALLOCATION_ENTRYPOINT_SOURCE)
        source_names.add(ALLOCATION_PROBE_SOURCE)
    source_names = sorted(source_names)
    sources = []
    for source in source_names:
        path = (root / source).resolve(strict=True)
        if root not in path.parents:
            raise HarnessError(f"workload contract source escapes the harness: {source}")
        sources.append({
            "path": source,
            "sha256": artifacts.sha256_file(path),
        })
    payload = {
        "schemaVersion": 3,
        "timingContractVersion": TIMING_CONTRACT_VERSION,
        "clock": clock,
        "workloads": selected,
        "sources": sources,
        "absoluteMicros": {
            workload["id"]: clock_budgets[workload["id"]]
            for workload in selected
            if workload["id"] in clock_budgets
        },
        "absoluteMemoryKb": {
            runtime_identity: {
                lane: {
                    workload["id"]: entries[workload["id"]]
                    for workload in selected
                    if workload["id"] in entries
                }
                for lane, entries in lanes.items()
            }
            for runtime_identity, lanes in memory_budgets.items()
        },
    }
    return artifacts.sha256_bytes(artifacts.canonical_json(payload))


def master_file_identity(config_path: Path) -> list[dict[str, Any]]:
    data_directories: list[Path] = []
    for raw in config_path.read_text(encoding="utf-8").splitlines():
        if not raw.startswith("data="):
            continue
        value = raw.split("=", 1)[1].strip()
        if value.startswith('"') and value.endswith('"'):
            value = value[1:-1].replace("&\"", '"').replace("&&", "&")
        data_directories.append(Path(value))
    identities: list[dict[str, Any]] = []
    for name in ("Morrowind.esm", "Tribunal.esm", "Bloodmoon.esm"):
        matches = [directory / name for directory in data_directories if (directory / name).is_file()]
        if not matches:
            raise HarnessError(f"configured game master is missing: {name}")
        path = matches[0].resolve(strict=True)
        identities.append({
            "name": name,
            "size": path.stat().st_size,
            "sha256": artifacts.sha256_file(path),
        })
    return identities


def runtime_comparability(
    raw_results: list[dict[str, Any]],
    process_records: list[dict[str, Any]],
    contract_identity: dict[str, str],
    engine: dict[str, Any] | None,
    game_data: list[dict[str, Any]] | None,
    profile: dict[str, Any],
) -> dict[str, Any]:
    runtime = raw_results[0]["runtime"]
    jit = runtime.get("jit", {})
    affinities = {record["cpuAffinity"]["effective"] for record in process_records}
    if len(affinities) != 1:
        raise HarnessError("effective CPU affinity changed within one experiment")
    affinity = next(iter(affinities))
    return {
        "cpuModel": cpu_model(),
        "cpuGovernors": cpu_governors(affinity),
        "cpuAffinity": affinity,
        "kernel": platform.release(),
        "machine": platform.machine(),
        "lua": runtime.get("lua"),
        "luaExecutableSha256": runtime.get("executableSha256"),
        "jitAvailable": jit.get("available"),
        "jitEnabled": jit.get("enabled"),
        "jitVersion": jit.get("version"),
        "jitArchitecture": jit.get("architecture"),
        "selectedWorkloadContractSha256": contract_identity[
            "selectedWorkloadContractSha256"
        ],
        "openmwSha256": engine.get("identity", {}).get("sha256") if engine else None,
        "openmwBuildId": engine.get("identity", {}).get("buildId") if engine else None,
        "openmwSourceRef": engine.get("sourceRef") if engine else None,
        "openmwBuildType": engine.get("buildType") if engine else None,
        "gameData": game_data,
        "runParameters": profile,
        "nativeCampaign": None,
    }


def profile_options(
    definitions: dict[str, Any], arguments: argparse.Namespace, workload_count: int
) -> dict[str, Any]:
    profile = dict(definitions["profiles"][arguments.profile])
    if arguments.processes is not None:
        profile["processes"] = arguments.processes
    if arguments.samples is not None:
        profile["samplesPerProcess"] = arguments.samples
    if arguments.warmups is not None:
        profile["warmupsPerProcess"] = arguments.warmups
    if arguments.memory_evidence:
        profile["memoryEvidence"] = True
    if profile.get("requiresSingleWorkload") and workload_count != 1:
        raise HarnessError("the profile run profile requires exactly one workload")
    return profile


def experiment_groups(
    selected: list[dict[str, Any]], profile: dict[str, Any]
) -> list[list[str]]:
    if profile["memoryEvidence"]:
        return [
            [item["id"]]
            for _replicate in range(profile["processes"])
            for item in selected
        ]
    batched = [
        item["id"] for item in selected if not item["requiresFreshProcess"]
    ]
    fresh = [
        [item["id"]] for item in selected if item["requiresFreshProcess"]
    ]
    groups: list[list[str]] = []
    for replicate in range(profile["processes"]):
        if batched:
            offset = replicate % len(batched)
            groups.append(batched[offset:] + batched[:offset])
        groups.extend(list(group) for group in fresh)
    return groups


def allocation_probe_identifiers(
    selected: list[dict[str, Any]],
    mode: str,
    profile: dict[str, Any],
    budgets: dict[str, Any],
    runtime: dict[str, Any],
) -> list[str]:
    if mode != "standalone" or not profile["memoryEvidence"]:
        return []
    runtime_identity = results.memory_runtime_identity(runtime)
    lanes = budgets["absoluteMemoryKb"]["standalone"].get(runtime_identity)
    if lanes is None:
        return []
    allocated = lanes["allocated"]
    return [
        workload["id"]
        for workload in selected
        if workload["id"] in allocated
    ]


def specification(
    arguments: argparse.Namespace,
    selected: list[dict[str, Any]],
    profile: dict[str, Any],
    contracts: dict[str, str],
    engine: dict[str, Any] | None,
    game_data: list[dict[str, Any]] | None,
    lua_executable: dict[str, str] | None,
) -> dict[str, Any]:
    return {
        "schemaVersion": 2,
        "kind": "mom.performance.specification",
        "mode": arguments.mode,
        "profile": arguments.profile,
        "profileOptions": profile,
        "workloads": [{"id": item["id"], "version": item["version"]} for item in selected],
        "clock": "process_cpu" if arguments.mode == "standalone" else "monotonic_wall",
        "inputs": contracts,
        "engine": engine,
        "luaExecutable": lua_executable,
        "gameData": game_data,
        "git": git_identity(),
        "requestedAffinity": arguments.cpu_set,
        "nativeCampaign": arguments.native_campaign,
        "environment": {
            key: os.environ.get(key)
            for key in ("LUA", "OPENMW_BIN", "CFLAGS", "CXXFLAGS", "LDFLAGS")
            if os.environ.get(key) is not None
        },
    }


def standalone_lua_identity(arguments: argparse.Namespace) -> dict[str, str]:
    requested = arguments.lua or os.environ.get("LUA", "lua")
    executable = (
        shutil.which(requested)
        if Path(requested).parent == Path(".")
        else str(Path(requested).resolve(strict=True))
    )
    if not executable:
        raise HarnessError(f"Lua executable is unavailable: {requested}")
    path = Path(executable).resolve(strict=True)
    return {
        "path": str(path),
        "sha256": artifacts.sha256_file(path),
    }


def run_standalone_process(
    *,
    index: int,
    identifiers: list[str],
    profile: dict[str, Any],
    artifact: artifacts.ArtifactRun,
    arguments: argparse.Namespace,
    cpu_set: set[int] | None,
    process_records: list[dict[str, Any]],
    lua_executable: dict[str, str],
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    executable = lua_executable["path"]
    if artifacts.sha256_file(Path(executable)) != lua_executable["sha256"]:
        raise HarnessError("Lua executable identity changed before launch")
    raw_path = artifact.staging / "results" / "raw" / f"{index:03d}.json"
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    stdout_path = artifact.staging / "logs" / f"process-{index:03d}.stdout.txt"
    stderr_path = artifact.staging / "logs" / f"process-{index:03d}.stderr.txt"
    command = [
        executable,
        str(PERFORMANCE_ROOT / "standalone.lua"),
        str(REPOSITORY_ROOT),
        str(raw_path),
        str(profile["samplesPerProcess"]),
        str(profile["warmupsPerProcess"]),
        "1" if profile["memoryEvidence"] else "0",
        lua_executable["sha256"],
        *identifiers,
    ]
    record = process.run_process(
        command,
        cwd=REPOSITORY_ROOT,
        environment=dict(os.environ),
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        timeout_seconds=arguments.timeout,
        cpu_set=cpu_set,
    )
    process_records.append(record)
    if artifacts.sha256_file(Path(executable)) != lua_executable["sha256"]:
        raise HarnessError("Lua executable identity changed during launch")
    raw = results.load_json(raw_path) if raw_path.is_file() else None
    return raw, record


def run_allocation_process(
    *,
    index: int,
    identifier: str,
    artifact: artifacts.ArtifactRun,
    arguments: argparse.Namespace,
    cpu_set: set[int] | None,
    process_records: list[dict[str, Any]],
    lua_executable: dict[str, str],
) -> tuple[dict[str, Any] | None, dict[str, Any]]:
    executable = lua_executable["path"]
    if artifacts.sha256_file(Path(executable)) != lua_executable["sha256"]:
        raise HarnessError("Lua executable identity changed before allocation launch")
    raw_path = (
        artifact.staging
        / "results"
        / "allocation"
        / f"{index:03d}.json"
    )
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    stdout_path = (
        artifact.staging / "logs" / f"allocation-{index:03d}.stdout.txt"
    )
    stderr_path = (
        artifact.staging / "logs" / f"allocation-{index:03d}.stderr.txt"
    )
    command = [
        executable,
        str(PERFORMANCE_ROOT / "allocation.lua"),
        str(REPOSITORY_ROOT),
        str(raw_path),
        lua_executable["sha256"],
        identifier,
    ]
    record = process.run_process(
        command,
        cwd=REPOSITORY_ROOT,
        environment=dict(os.environ),
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        timeout_seconds=arguments.timeout,
        cpu_set=cpu_set,
    )
    process_records.append(record)
    if artifacts.sha256_file(Path(executable)) != lua_executable["sha256"]:
        raise HarnessError("Lua executable identity changed during allocation launch")
    raw = results.load_json(raw_path) if raw_path.is_file() else None
    return raw, record


def run_embedded_process(
    *,
    index: int,
    identifiers: list[str],
    profile: dict[str, Any],
    artifact: artifacts.ArtifactRun,
    arguments: argparse.Namespace,
    cpu_set: set[int] | None,
    process_records: list[dict[str, Any]],
    prepare_records: list[dict[str, Any]],
) -> tuple[
    dict[str, Any] | None,
    dict[str, Any],
    dict[str, Any],
    dict[str, Any] | None,
]:
    work = artifact.staging / "work" / f"engine-{index:03d}"
    raw_path = artifact.staging / "results" / "raw" / f"{index:03d}.json"
    raw_path.parent.mkdir(parents=True, exist_ok=True)
    launch_path = work / "launch.json"
    prepare_stdout = artifact.staging / "logs" / f"prepare-{index:03d}.stdout.txt"
    prepare_stderr = artifact.staging / "logs" / f"prepare-{index:03d}.stderr.txt"
    launch, _prepare_record = openmw.prepare_embedded(
        harness_root=HARNESS_ROOT,
        work_directory=work / "profile",
        raw_result=raw_path,
        launch_spec_path=launch_path,
        workload_ids=identifiers,
        lane=arguments.mode,
        samples=profile["samplesPerProcess"],
        warmups=profile["warmupsPerProcess"],
        memory_evidence=profile["memoryEvidence"],
        prepare_stdout=prepare_stdout,
        prepare_stderr=prepare_stderr,
        timeout_seconds=arguments.prepare_timeout,
        openmw_binary=arguments.openmw,
        global_config=arguments.global_config,
        base_config=arguments.openmw_base_config,
        source_directory=arguments.openmw_source,
        build_root=arguments.openmw_build_root,
        build_openmw=arguments.build_openmw,
        record_process=prepare_records.append,
    )
    config_destination = artifact.staging / "config" / f"run-{index:03d}"
    openmw.retain_configuration(launch, config_destination)
    stdout_path = artifact.staging / "logs" / f"process-{index:03d}.stdout.txt"
    stderr_path = artifact.staging / "logs" / f"process-{index:03d}.stderr.txt"
    native_metadata = None
    command_override = None
    if arguments.native_campaign is not None:
        command_override, native_metadata = perf_capture.command(
            arguments.native_campaign,
            list(launch["command"]),
            artifact.staging / "perf" / f"run-{index:03d}",
        )
    record = openmw.run_embedded(
        launch,
        cwd=REPOSITORY_ROOT,
        stdout_path=stdout_path,
        stderr_path=stderr_path,
        xvfb_log=artifact.staging / "logs" / f"xvfb-{index:03d}.txt",
        timeout_seconds=arguments.timeout,
        cpu_set=cpu_set,
        command_override=command_override,
    )
    process_records.append(record)
    if native_metadata is not None:
        native_metadata = perf_capture.postprocess(
            native_metadata, artifact.staging / "perf" / f"run-{index:03d}"
        )
        artifacts.write_json(
            artifact.staging / "perf" / f"run-{index:03d}" / "capture.json",
            native_metadata,
        )
    openmw.retain_log(launch, artifact.staging / "logs" / f"openmw-{index:03d}.log")
    raw = results.load_json(raw_path) if raw_path.is_file() else None
    return raw, record, launch["openmw"], native_metadata


def require_successful_process(
    record: dict[str, Any],
    *,
    label: str,
) -> None:
    if record.get("timedOut") is True:
        raise HarnessError(f"{label} timed out")
    return_code = record.get("returnCode")
    if isinstance(return_code, bool) or not isinstance(return_code, int):
        raise HarnessError(f"{label} returned an invalid process record")
    if return_code != 0:
        raise HarnessError(f"{label} exited with status {return_code}")


def run_experiment(arguments: argparse.Namespace) -> int:
    engine_options = (
        arguments.openmw, arguments.openmw_base_config,
        arguments.openmw_source, arguments.openmw_build_root, arguments.build_openmw,
    )
    if arguments.mode == "standalone" and any(option is not None for option in engine_options):
        raise HarnessError("OpenMW engine options require embedded or integration mode")
    catalog, profiles, budgets = results.load_contracts(PERFORMANCE_ROOT)
    selected = results.select_workloads(catalog, arguments.workload, arguments.mode)
    if arguments.native_campaign is not None and arguments.mode == "standalone":
        raise HarnessError("native campaigns require an OpenMW mode")
    if arguments.native_campaign is not None and len(selected) != 1:
        raise HarnessError("native campaigns require exactly one workload")
    profile = profile_options(profiles, arguments, len(selected))
    git = git_identity()
    if arguments.profile == "release" and git["dirty"] and not arguments.allow_dirty:
        raise HarnessError("release profile requires a clean worktree (or --allow-dirty)")
    cpu_set = process.parse_cpu_set(arguments.cpu_set)
    if arguments.profile == "release" and cpu_set is None:
        raise HarnessError("release profile requires --cpu-set")
    lua_executable = (
        standalone_lua_identity(arguments)
        if arguments.mode == "standalone"
        else None
    )
    artifact = artifacts.ArtifactRun(arguments.artifact_root, REPOSITORY_ROOT)
    raw_results: list[dict[str, Any]] = []
    allocation_results: list[dict[str, Any]] = []
    process_records: list[dict[str, Any]] = []
    prepare_records: list[dict[str, Any]] = []
    native_records: list[dict[str, Any]] = []
    contracts = {
        **file_contract_identity(),
        "selectedWorkloadContractSha256": selected_workload_contract_identity(
            selected,
            arguments.mode,
            budgets,
        ),
    }
    engine: dict[str, Any] | None = None
    game_data: list[dict[str, Any]] | None = None
    started_at = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        groups = experiment_groups(selected, profile)
        for index, identifiers in enumerate(groups):
            if arguments.mode == "standalone":
                if lua_executable is None:
                    raise HarnessError("standalone Lua identity is unavailable")
                raw, record = run_standalone_process(
                    index=index,
                    identifiers=identifiers,
                    profile=profile,
                    artifact=artifact,
                    arguments=arguments,
                    cpu_set=cpu_set,
                    process_records=process_records,
                    lua_executable=lua_executable,
                )
            else:
                (
                    raw, record, current_engine, native_record,
                ) = run_embedded_process(
                    index=index,
                    identifiers=identifiers,
                    profile=profile,
                    artifact=artifact,
                    arguments=arguments,
                    cpu_set=cpu_set,
                    process_records=process_records,
                    prepare_records=prepare_records,
                )
                if native_record is not None:
                    native_records.append(native_record)
                if engine is None:
                    engine = current_engine
                    game_data = master_file_identity(
                        artifact.staging / "config" / "run-000" / "openmw.cfg"
                    )
                elif current_engine != engine:
                    raise HarnessError("OpenMW binary/build identity changed within the experiment")
            require_successful_process(record, label=f"{arguments.mode} process {index}")
            if raw is None:
                raise HarnessError(
                    f"{arguments.mode} process {index} produced no raw result"
                )
            results.validate_raw_result(
                raw,
                catalog,
                expected_mode=arguments.mode,
                expected_ids=identifiers,
                expected_samples=profile["samplesPerProcess"],
                expected_warmups=profile["warmupsPerProcess"],
                expected_memory=profile["memoryEvidence"],
            )
            if (
                arguments.mode == "standalone"
                and raw["runtime"].get("executableSha256")
                != lua_executable["sha256"]
            ):
                raise HarnessError(
                    "raw Lua executable identity differs from the launched binary"
                )
            raw_results.append(raw)
        if arguments.mode == "standalone":
            if lua_executable is None:
                raise HarnessError("standalone Lua identity is unavailable")
            allocation_ids = allocation_probe_identifiers(
                selected,
                arguments.mode,
                profile,
                budgets,
                raw_results[0]["runtime"],
            )
            for offset, identifier in enumerate(allocation_ids):
                index = len(groups) + offset
                raw, record = run_allocation_process(
                    index=index,
                    identifier=identifier,
                    artifact=artifact,
                    arguments=arguments,
                    cpu_set=cpu_set,
                    process_records=process_records,
                    lua_executable=lua_executable,
                )
                require_successful_process(
                    record,
                    label=f"allocation process {identifier}",
                )
                if raw is None:
                    raise HarnessError(
                        f"allocation process {identifier} produced no raw result"
                    )
                results.validate_allocation_result(
                    raw,
                    catalog,
                    expected_id=identifier,
                    expected_runtime=raw_results[0]["runtime"],
                )
                allocation_results.append(raw)
        artifact.write_specification(specification(
            arguments,
            selected,
            profile,
            contracts,
            engine,
            game_data,
            lua_executable,
        ))
        comparability = runtime_comparability(
            raw_results, process_records, contracts, engine, game_data, profile
        )
        comparability["nativeCampaign"] = arguments.native_campaign
        summary = results.summarize_raw_results(
            raw_results,
            selected,
            budgets,
            profile=arguments.profile,
            comparability=comparability,
            allocation_results=allocation_results,
        )
        results.validate_summary(summary, catalog, budgets)
        artifacts.write_json(artifact.staging / "results" / "summary.json", summary)
        run_directory = artifact.finalize({
            "status": summary["status"],
            "startedAtUtc": started_at,
            "finishedAtUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "processes": process_records,
            "preparationProcesses": prepare_records,
            "nativeCaptures": native_records,
        })
    except Exception as exc:
        try:
            if artifact.specification_id is None:
                artifact.write_specification(specification(
                    arguments,
                    selected,
                    profile,
                    contracts,
                    engine,
                    game_data,
                    lua_executable,
                ))
            failed_directory = artifact.finalize({
                "status": "failed",
                "startedAtUtc": started_at,
                "finishedAtUtc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "error": {"type": type(exc).__name__, "message": str(exc)},
                "processes": process_records,
                "preparationProcesses": prepare_records,
                "nativeCaptures": native_records,
            })
            print(f"Failed artifact: {failed_directory}", file=sys.stderr)
        except Exception as artifact_error:
            artifact.abandon()
            print(f"Could not retain failed artifact: {artifact_error}", file=sys.stderr)
        raise

    final_summary = run_directory / "results" / "summary.json"
    if arguments.output is not None:
        artifacts.atomic_write(arguments.output.resolve(), final_summary.read_bytes())
    print_summary(summary)
    print(f"Artifact: {run_directory}")
    if arguments.output is not None:
        print(f"Summary: {arguments.output.resolve()}")
    return 0 if summary["status"] == "passed" else 1


def workload_id_width(
    workloads: list[dict[str, Any]],
    minimum: int = 31,
) -> int:
    return max(
        [minimum, *(len(str(row["id"])) for row in workloads)],
    )


def print_summary(summary: dict[str, Any]) -> None:
    width = workload_id_width(summary["workloads"])
    for row in summary["workloads"]:
        stats = row.get("statisticsMicros")
        value = f"{stats['median']:10.1f} us/op" if stats else "        no samples"
        budget = f" <= {row['budgetMicros']:.1f}" if row.get("budgetMicros") is not None else ""
        memory = ""
        after = row.get("memoryAfterStatisticsKb")
        retained = row.get("memoryRetainedStatisticsKb")
        if after is not None and retained is not None:
            allocated_budget = row.get("budgetMemoryAllocatedKb")
            retained_budget = row.get("budgetMemoryRetainedKb")
            allocated_limit = (
                f"<={allocated_budget:.1f}"
                if allocated_budget is not None
                else "unbudgeted"
            )
            retained_limit = (
                f"<={retained_budget:.1f}"
                if retained_budget is not None
                else "unbudgeted"
            )
            allocation = row.get("allocationProbe")
            if allocation is None:
                allocated_value = "unmeasured"
            elif allocation["status"] == "failed":
                allocated_value = "failed"
            else:
                allocated_value = (
                    f"{allocation['memoryAllocatedDeltaKb']:.1f}"
                )
            memory = (
                f" heap(allocated={allocated_value}/{allocated_limit},"
                f" footprint-after={after['maximum']:.1f}/telemetry,"
                " footprint-retained="
                f"{retained['maximum']:.1f}/{retained_limit} KB)"
            )
        print(
            f"{row['id']:<{width}} {value}{budget}{memory}"
            f" [{row['status']}]"
        )
    print(f"MOM performance status: {summary['status']}")


def command_list(_arguments: argparse.Namespace) -> int:
    catalog, profiles, _budgets = results.load_contracts(PERFORMANCE_ROOT)
    width = workload_id_width(catalog["workloads"])
    for workload in catalog["workloads"]:
        print(
            f"{workload['id']:<{width}} "
            f"v{workload['version']}  {','.join(workload['modes'])}"
        )
    print("Profiles: " + ", ".join(profiles["profiles"]))
    return 0


def command_validate(arguments: argparse.Namespace) -> int:
    catalog, _profiles, budgets = results.load_contracts(PERFORMANCE_ROOT)
    if arguments.path.is_dir():
        artifacts.validate_run_directory(arguments.path)
        summary_path = arguments.path / "results" / "summary.json"
        if summary_path.is_file():
            results.validate_summary(
                results.load_json(summary_path),
                catalog,
                budgets,
            )
        print(f"Valid: {arguments.path}")
        return 0
    value = results.load_json(arguments.path)
    if isinstance(value, dict) and value.get("kind") == "mom.performance.raw":
        results.validate_raw_result(value, catalog)
    elif isinstance(value, dict) and value.get("kind") == "mom.performance.allocation":
        results.validate_allocation_result(value, catalog)
    elif isinstance(value, dict) and value.get("kind") == "mom.performance.summary":
        results.validate_summary(value, catalog, budgets)
    elif isinstance(value, dict) and value.get("kind") == "mom.performance.comparison":
        results.validate_comparison(value)
    else:
        raise HarnessError("file is not a recognized MOM performance artifact")
    print(f"Valid: {arguments.path}")
    return 0


def command_compare(arguments: argparse.Namespace) -> int:
    catalog, _profiles, budgets = results.load_contracts(PERFORMANCE_ROOT)
    comparison = results.compare_summaries(
        results.load_json(arguments.baseline),
        results.load_json(arguments.candidate),
        budgets,
        catalog,
    )
    if arguments.output:
        artifacts.write_json(arguments.output, comparison)
    print(f"Comparison status: {comparison['status']}")
    for mismatch in comparison.get("mismatches", []):
        print(f"not-comparable: {mismatch}")
    width = workload_id_width(comparison["workloads"])
    for row in comparison["workloads"]:
        ratio = row.get("ratio")
        ratio_text = f"{ratio['estimate']:.3f}x [{ratio['lower']:.3f}, {ratio['upper']:.3f}]" if ratio else "n/a"
        print(f"{row['id']:<{width}} {ratio_text:<28} [{row['status']}]")
    return 0 if comparison["status"] == "passed" else 1


def generated_workload_catalog(lua: str | None = None) -> bytes:
    requested = lua or os.environ.get("LUA", "lua")
    executable = (
        shutil.which(requested)
        if Path(requested).parent == Path(".")
        else str(Path(requested).resolve(strict=True))
    )
    if not executable:
        raise HarnessError(f"Lua executable is unavailable: {requested}")
    completed = subprocess.run(
        [
            executable,
            str(PERFORMANCE_ROOT / "catalog.lua"),
            str(REPOSITORY_ROOT),
        ],
        cwd=REPOSITORY_ROOT,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=30,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or f"exit {completed.returncode}"
        raise HarnessError(f"workload catalog generation failed: {detail}")
    try:
        generated = json.loads(completed.stdout)
    except json.JSONDecodeError as exc:
        raise HarnessError(f"workload catalog generator emitted invalid JSON: {exc}") from exc
    results.validate_catalog(generated)
    return completed.stdout.encode("utf-8")


def command_catalog(arguments: argparse.Namespace) -> int:
    destination = PERFORMANCE_ROOT / "workloads.json"
    generated = generated_workload_catalog(arguments.lua)
    if arguments.write:
        artifacts.atomic_write(destination, generated)
        print(f"Updated: {destination}")
        return 0
    if not destination.is_file() or destination.read_bytes() != generated:
        raise HarnessError(
            "generated workload catalog differs; run `mom_harness.py catalog --write`"
        )
    print(f"Current: {destination}")
    return 0


def positive_int(value: str) -> int:
    result = int(value)
    if result <= 0:
        raise argparse.ArgumentTypeError("must be positive")
    return result


def nonnegative_int(value: str) -> int:
    result = int(value)
    if result < 0:
        raise argparse.ArgumentTypeError("must be non-negative")
    return result


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="MOM correctness and performance harness host")
    commands = result.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="run a standalone or embedded performance experiment")
    run.add_argument(
        "--mode", choices=("standalone", "embedded", "integration"), default="standalone"
    )
    run.add_argument(
        "--profile",
        choices=("quick", "standard", "release", "memory", "profile"),
        default="quick",
    )
    run.add_argument("--workload", action="append")
    run.add_argument("--processes", type=positive_int)
    run.add_argument("--samples", type=positive_int)
    run.add_argument("--warmups", type=nonnegative_int)
    run.add_argument(
        "--memory-evidence",
        action="store_true",
        help="capture per-sample GC memory diagnostics",
    )
    run.add_argument("--artifact-root", type=Path, default=DEFAULT_ARTIFACT_ROOT)
    run.add_argument("--output", type=Path)
    run.add_argument("--timeout", type=float, default=300)
    run.add_argument("--prepare-timeout", type=float, default=7200)
    run.add_argument("--cpu-set")
    run.add_argument("--lua")
    run.add_argument("--openmw", type=Path)
    run.add_argument("--global-config", type=Path)
    run.add_argument("--openmw-base-config", type=Path)
    run.add_argument("--openmw-source", type=Path)
    run.add_argument("--openmw-build-root", type=Path)
    engine_build = run.add_mutually_exclusive_group()
    engine_build.add_argument("--build-openmw", dest="build_openmw", action="store_true")
    engine_build.add_argument("--no-build-openmw", dest="build_openmw", action="store_false")
    run.set_defaults(build_openmw=None)
    run.add_argument("--native-campaign", choices=perf_capture.CAMPAIGNS)
    run.add_argument("--allow-dirty", action="store_true")
    run.set_defaults(function=run_experiment)

    check = commands.add_parser(
        "check", help="check contracts, world scenarios and restarts on LuaJIT and Luau",
    )
    validation.configure_parser(check)

    quick_check = commands.add_parser(
        "quick-check", help="run normal native Luau contracts, smoke scenarios and selected restarts",
    )
    validation.configure_quick_parser(quick_check)

    example_check = commands.add_parser(
        "examples", help="compile shipped configurations and complete public examples in OpenMW",
    )
    examples.configure_parser(example_check)
    example_check.set_defaults(function=examples.run)

    listing = commands.add_parser("list", help="list workload and profile IDs")
    listing.set_defaults(function=command_list)
    catalog = commands.add_parser(
        "catalog",
        help="check or regenerate the host workload catalog projection",
    )
    action = catalog.add_mutually_exclusive_group(required=True)
    action.add_argument("--check", action="store_true")
    action.add_argument("--write", action="store_true")
    catalog.add_argument("--lua")
    catalog.set_defaults(function=command_catalog)
    validate = commands.add_parser("validate", help="strictly validate a result artifact")
    validate.add_argument("path", type=Path)
    validate.set_defaults(function=command_validate)
    compare = commands.add_parser("compare", help="compare two compatible summary artifacts")
    compare.add_argument("baseline", type=Path)
    compare.add_argument("candidate", type=Path)
    compare.add_argument("--output", type=Path)
    compare.set_defaults(function=command_compare)
    return result


def main(argv: list[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    timeout = getattr(arguments, "timeout", 1)
    prepare_timeout = getattr(arguments, "prepare_timeout", 1)
    if not all(value > 0 and value < float("inf") for value in (timeout, prepare_timeout)):
        raise HarnessError("timeouts must be positive")
    with process.cancellation_signals():
        return arguments.function(arguments)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt as exc:
        print(f"Cancelled: {str(exc) or 'interrupted'}", file=sys.stderr)
        raise SystemExit(128 + getattr(exc, "signum", signal.SIGINT))
    except (HarnessError, results.ResultError, process.ProcessError,
            artifacts.ArtifactError, openmw.OpenMWError,
            perf_capture.PerfCaptureError, ValueError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        raise SystemExit(2)
