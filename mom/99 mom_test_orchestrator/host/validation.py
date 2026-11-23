"""Run pure contracts, world scenarios, and campaigns on both OpenMW runtimes."""
from __future__ import annotations

import argparse
import math
import os
from pathlib import Path
import re
import subprocess
import sys
from typing import Any

import artifacts
import correctness
import launch
import openmw
import process
import process_campaigns
import scenario_inventory
import standalone


HARNESS_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = HARNESS_ROOT.parent.parent
PURE_SUMMARY = re.compile(r"MOM pure contract tests passed: ([0-9]+) case\(s\)$")
RUNTIME_MARKER = "MOM pure runtime: "


class ValidationError(ValueError):
    pass


def configure_parser(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--luajit-openmw", type=Path, required=True)
    parser.add_argument("--luau-openmw", type=Path, required=True)
    parser.add_argument("--lua", default="luajit", help="standalone LuaJIT executable")
    parser.add_argument("--global-config", type=Path)
    parser.add_argument("--workdir", type=Path, default=launch.default_workdir("check"))
    parser.add_argument("--timeout", type=float, default=300,
                        help="seconds per pure/correctness run and campaign phase")
    parser.set_defaults(function=run)


def configure_quick_parser(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--luau-openmw", type=Path, required=True)
    parser.add_argument("--lua", default="lua", help="Lua executable for the scenario catalog")
    parser.add_argument("--global-config", type=Path)
    parser.add_argument("--workdir", type=Path, default=launch.default_workdir("quick-check"))
    parser.add_argument("--timeout", type=float, default=300,
                        help="seconds per pure/correctness run and campaign phase")
    parser.add_argument("--scenario", action="append", help="replace smoke scenarios; repeatable")
    parser.add_argument("--campaign", action="append", help="replace the default restart campaign; repeatable")
    parser.set_defaults(function=run_quick)


def _pure_cases(log: str) -> int:
    counts = [int(match.group(1)) for line in log.splitlines()
              if (match := PURE_SUMMARY.search(line))]
    if len(counts) != 1 or counts[0] <= 0:
        raise ValidationError("pure run must emit exactly one nonempty case summary")
    return counts[0]


def _verify_pure_count(checks: list[dict[str, Any]], row: dict[str, Any]) -> None:
    baseline = next((previous for previous in checks
                     if previous is not row and previous["status"] == "passed"
                     and "cases" in previous
                     and previous.get("profile") == row.get("profile")), None)
    if baseline is not None and row["cases"] != baseline["cases"]:
        raise ValidationError(
            f"pure case count mismatch: expected {baseline['cases']} from {baseline['id']}; "
            f"observed {row['cases']} in {row['id']}"
        )


def _verify_result(
    kind: str,
    *,
    workdir: Path,
    stdout_path: Path,
    runtime: str | None,
    scenarios: list[str],
    campaigns: list[str] | None = None,
) -> dict[str, Any]:
    if kind == "pure":
        if runtime is None:
            return {"cases": _pure_cases(stdout_path.read_text(encoding="utf-8", errors="replace"))}
        log = (workdir / "config/openmw.log").read_text(encoding="utf-8", errors="replace")
        if not standalone.native_result_passed(0, log):
            raise ValidationError("native pure run lacks a unique passing receipt")
        versions = [line.split(RUNTIME_MARKER, 1)[1].strip()
                    for line in log.splitlines() if RUNTIME_MARKER in line]
        expected = "Luau" if runtime == "luau" else "Lua 5.1"
        if versions != [expected]:
            raise ValidationError(f"expected native {runtime} runtime {expected!r}; got {versions!r}")
        return {"cases": _pure_cases(log), "runtimeVersion": versions[0]}
    if kind == "correctness":
        result = correctness.load_result(workdir / "result.json")
        if (result["kind"] != "mom.correctness.result" or result["status"] != "passed"
                or result["scenarios"] != scenarios):
            raise ValidationError("native correctness result did not pass the complete scenario selection")
        return {"scenarios": result["total"]}
    result = process_campaigns.validate_campaign_artifacts(
        artifacts.load_json(workdir / "result.json")
    )
    if (result["status"] != "passed"
            or [row["id"] for row in result["campaigns"]]
            != (campaigns if campaigns is not None else
                [campaign.id for campaign in process_campaigns.CAMPAIGNS])):
        raise ValidationError("process campaign result did not pass the complete campaign selection")
    return {"campaigns": len(result["campaigns"]),
            "phases": sum(len(row["phases"]) for row in result["campaigns"])}


def run(arguments: argparse.Namespace) -> int:
    try:
        with process.cancellation_signals():
            return _run(arguments)
    except (OSError, launch.LaunchError, scenario_inventory.ScenarioInventoryError,
            subprocess.SubprocessError) as exc:
        raise ValidationError(str(exc)) from exc


def run_quick(arguments: argparse.Namespace) -> int:
    try:
        with process.cancellation_signals():
            return _run(arguments, quick=True)
    except (OSError, launch.LaunchError, scenario_inventory.ScenarioInventoryError,
            subprocess.SubprocessError) as exc:
        raise ValidationError(str(exc)) from exc


def _run(arguments: argparse.Namespace, *, quick: bool = False) -> int:
    if not math.isfinite(arguments.timeout) or arguments.timeout <= 0:
        raise ValidationError("timeout must be finite and positive")
    engines = {"luau": openmw.binary_identity(arguments.luau_openmw)}
    if not quick:
        engines = {"luajit": openmw.binary_identity(arguments.luajit_openmw), **engines}
    if not quick and engines["luajit"]["sha256"] == engines["luau"]["sha256"]:
        raise ValidationError("LuaJIT and Luau checks require different OpenMW binaries")
    lua = str(launch._resolve_executable(arguments.lua))
    global_config = launch.resolve_global_config(arguments.global_config)
    catalog = scenario_inventory.load_catalog(HARNESS_ROOT, lua=lua)
    if quick:
        scenarios = catalog.select(arguments.scenario or [], [] if arguments.scenario else ["smoke"])
        campaigns = arguments.campaign or ["nested_attach_restart"]
    else:
        scenarios = catalog.select([], ["all"])
        campaigns = None
    if campaigns is not None and (len(campaigns) != len(set(campaigns)) or
            any(item not in process_campaigns.CAMPAIGN_BY_ID for item in campaigns)):
        raise ValidationError("quick check campaigns must be known and unique")
    workdir = launch.prepare_workdir(arguments.workdir)
    environment = dict(os.environ)
    checks: list[dict[str, Any]] = []
    result_file = workdir / "result.json"

    def save(status: str, error: str | None = None) -> None:
        result = {
            "schemaVersion": 2, "kind": "mom.runtime-validation.result",
            "status": status, "engines": engines, "checks": checks,
        }
        if quick:
            result["coverage"] = {"profile": "quick", "runtimes": ["luau"],
                "pure": "normal", "scenarios": scenarios, "campaigns": campaigns}
        if error is not None:
            result["error"] = error
        artifacts.write_json(result_file, result)

    def check(
        identifier: str,
        kind: str,
        command: list[str],
        *,
        runtime: str | None = None,
        timeout: float | None = arguments.timeout,
        profile: str | None = None,
    ) -> None:
        directory = workdir / identifier
        stdout_path = directory / "stdout.log"
        stderr_path = directory / "stderr.log"
        row: dict[str, Any] = {"id": identifier, "status": "running",
                               "stdout": str(stdout_path), "stderr": str(stderr_path)}
        if profile is not None:
            row["profile"] = profile
        checks.append(row)
        save("running")
        try:
            record = process.run_process(
                command, cwd=REPOSITORY_ROOT, environment=environment,
                stdout_path=stdout_path, stderr_path=stderr_path, timeout_seconds=timeout,
            )
            row["process"] = record
            if record["timedOut"]:
                raise ValidationError("process timed out")
            if record["returnCode"] != 0:
                raise ValidationError(f"process exited with status {record['returnCode']}")
            row.update(_verify_result(
                kind, workdir=directory / "run", stdout_path=stdout_path,
                runtime=runtime, scenarios=scenarios, campaigns=campaigns,
            ))
            if kind == "pure":
                _verify_pure_count(checks, row)
            row["status"] = "passed"
        except (ValidationError, OSError, process.ProcessError, artifacts.ArtifactError,
                correctness.CorrectnessError, process_campaigns.CampaignError) as exc:
            row.update(status="failed", error=str(exc))
        save("running")
        print(f"{identifier}: {row['status']}" +
              (f" ({row['error']})" if "error" in row else ""), flush=True)

    try:
        save("running")
        with process.VirtualDisplay(workdir / "xvfb.log") as display:
            environment["DISPLAY"] = display
            for stress in (() if quick else (False, True)):
                identifier = "standalone/" + ("stress" if stress else "normal")
                command = [sys.executable, str(HARNESS_ROOT / "host/standalone.py"),
                           "--lua", lua, "--timeout", str(arguments.timeout)]
                if stress:
                    command.append("--stress-only")
                check(identifier, "pure", command, profile="stress" if stress else "normal")

            for runtime, identity in engines.items():
                binary = Path(identity["path"])
                for stress in ((False,) if quick else (False, True)):
                    identifier = runtime + "/pure-" + ("stress" if stress else "normal")
                    command = [sys.executable, str(HARNESS_ROOT / "host/standalone.py"),
                               "--openmw", str(binary), "--workdir", str(workdir / identifier / "run"),
                               "--timeout", str(arguments.timeout), "--global-config", str(global_config)]
                    if stress:
                        command.append("--stress-only")
                    check(identifier, "pure", command, runtime=runtime,
                          profile="stress" if stress else "normal")

                identifier = runtime + "/correctness"
                command = launch.build_harness_command(launch.HarnessCommand(
                    mode="correctness", work_directory=workdir / identifier / "run",
                    result_file=workdir / identifier / "run/result.json", scenarios=tuple(scenarios),
                    openmw_binary=binary, global_config=global_config, build_openmw=False,
                ))
                check(identifier, "correctness", command, runtime=runtime)

                identifier = runtime + "/campaigns"
                command = [sys.executable, str(HARNESS_ROOT / "host/process_campaigns.py"),
                           "--openmw", str(binary), "--no-build-openmw",
                           "--workdir", str(workdir / identifier / "run"),
                           "--phase-timeout", str(math.ceil(arguments.timeout)),
                           "--global-config", str(global_config)]
                for campaign in campaigns or ():
                    command.extend(["--campaign", campaign])
                # Campaigns enforce their own phase deadlines and cleanup.
                check(identifier, "campaigns", command, runtime=runtime, timeout=None)

    except BaseException as exc:
        with process.ignore_cancellation():
            status = "cancelled" if isinstance(exc, KeyboardInterrupt) else "failed"
            error = str(exc) or type(exc).__name__
            for row in checks:
                if row["status"] == "running":
                    row.update(status=status, error=error)
            save(status, error)
        raise

    status = "passed" if all(row["status"] == "passed" for row in checks) else "failed"
    with process.ignore_cancellation():
        save(status)
    label = "Quick check" if quick else "Dual-runtime check"
    print(f"{label}: {status}; result: {result_file}")
    return 0 if status == "passed" else 1
