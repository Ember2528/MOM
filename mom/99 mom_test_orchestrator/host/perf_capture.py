from __future__ import annotations

from pathlib import Path
import re
import shutil
import subprocess
from typing import Any

import artifacts


class PerfCaptureError(RuntimeError):
    pass


RECORD_EVENT = "cycles:u"
CORE_EVENTS = ("cycles:u", "instructions:u", "branches:u", "branch-misses:u")
CACHE_EVENTS = (
    "cache-references:u",
    "cache-misses:u",
    "L1-dcache-loads:u",
    "L1-dcache-load-misses:u",
    "LLC-loads:u",
    "LLC-load-misses:u",
)
CAMPAIGNS = ("wall-control", "record", "stat-core", "stat-cache")


def perf_identity() -> dict[str, Any]:
    executable = shutil.which("perf")
    if executable is None:
        raise PerfCaptureError("perf is unavailable")
    path = Path(executable).resolve(strict=True)
    completed = subprocess.run(
        [str(path), "--version"],
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=30,
    )
    if completed.returncode != 0 or not completed.stdout.strip():
        raise PerfCaptureError("perf version query failed")
    return {
        "path": str(path),
        "sha256": artifacts.sha256_file(path),
        "version": completed.stdout.splitlines()[0].strip(),
    }


def command(campaign: str, exact_child: list[str], output_directory: Path) -> tuple[list[str], dict[str, Any]]:
    if campaign not in CAMPAIGNS:
        raise PerfCaptureError(f"unsupported native campaign: {campaign}")
    if not exact_child:
        raise PerfCaptureError("native campaign child command is empty")
    output_directory.mkdir(parents=True, exist_ok=True)
    metadata: dict[str, Any] = {"campaign": campaign, "exactChild": exact_child}
    if campaign == "wall-control":
        return list(exact_child), metadata
    perf = perf_identity()
    metadata["perf"] = perf
    if campaign == "record":
        data = output_directory / "perf.data"
        metadata.update({
            "event": RECORD_EVENT,
            "frequencyHz": 99,
            "callGraph": "dwarf",
            "perfData": data.name,
        })
        return [
            perf["path"], "record",
            "--output", str(data),
            "--event", RECORD_EVENT,
            "--freq", "99",
            "--call-graph", "dwarf",
            "--",
            *exact_child,
        ], metadata
    events = CORE_EVENTS if campaign == "stat-core" else CACHE_EVENTS
    output = output_directory / "stat.csv"
    metadata.update({"events": list(events), "statOutput": output.name})
    return [
        perf["path"], "stat",
        "--field-separator", ";",
        "--output", str(output),
        "--event", ",".join(events),
        "--",
        *exact_child,
    ], metadata


def parse_stat(path: Path, expected_events: tuple[str, ...]) -> list[dict[str, Any]]:
    found: dict[str, dict[str, Any]] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        fields = line.split(";")
        if len(fields) < 3:
            continue
        event = fields[2].strip()
        if event not in expected_events:
            continue
        raw_value = fields[0].strip()
        raw_percent = fields[4].strip() if len(fields) > 4 else ""
        percentage = None
        if raw_percent:
            try:
                percentage = float(raw_percent.rstrip("%"))
            except ValueError:
                percentage = None
        if raw_value.startswith("<"):
            state, value = "unavailable", None
        else:
            try:
                value = float(raw_value.replace(",", ""))
                state = (
                    "multiplexed" if percentage is not None and percentage < 99.0 else "available"
                )
            except ValueError:
                state, value = "unavailable", None
        found[event] = {
            "event": event,
            "state": state,
            "value": value,
            "percentRunning": percentage,
        }
    return [
        found.get(event, {
            "event": event,
            "state": "missing",
            "value": None,
            "percentRunning": None,
        })
        for event in expected_events
    ]


def _run_postprocess(command: list[str], output: Path) -> dict[str, Any]:
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=300,
    )
    artifacts.atomic_write(output, completed.stdout)
    return {"command": command, "returnCode": completed.returncode, "output": output.name}


def postprocess(metadata: dict[str, Any], output_directory: Path) -> dict[str, Any]:
    campaign = metadata["campaign"]
    result = dict(metadata)
    if campaign == "wall-control":
        result["status"] = "captured"
        return result
    if campaign in {"stat-core", "stat-cache"}:
        path = output_directory / metadata["statOutput"]
        if not path.is_file():
            result.update({"status": "failed", "error": "perf stat output missing"})
            return result
        events = CORE_EVENTS if campaign == "stat-core" else CACHE_EVENTS
        result["counters"] = parse_stat(path, events)
        states = {item["state"] for item in result["counters"]}
        if states == {"available"}:
            result["status"] = "captured"
        elif states & {"available", "multiplexed"}:
            result["status"] = "partial"
        else:
            result["status"] = "unavailable"
        return result

    data = output_directory / metadata["perfData"]
    if not data.is_file():
        result.update({"status": "failed", "error": "perf.data missing"})
        return result
    perf = metadata["perf"]["path"]
    build_ids = _run_postprocess(
        [perf, "buildid-list", "--input", str(data), "--with-hits"],
        output_directory / "buildids.txt",
    )
    script = _run_postprocess(
        [perf, "script", "--input", str(data), "--header"],
        output_directory / "perf-script.txt",
    )
    text = (output_directory / "perf-script.txt").read_text(encoding="utf-8", errors="replace")
    lost = sum(int(value) for value in re.findall(r"lost\s+(\d+)\s+events", text, re.IGNORECASE))
    unresolved = len(re.findall(r"\[unknown\]|\[JIT\]|//anon|\b0x[0-9a-f]+\b", text, re.IGNORECASE))
    result.update({
        "status": "captured" if build_ids["returnCode"] == 0 and script["returnCode"] == 0 else "partial",
        "perfDataSha256": artifacts.sha256_file(data),
        "perfDataSize": data.stat().st_size,
        "postprocess": {"buildIds": build_ids, "script": script},
        "lostEvents": lost,
        "jitOrUnresolvedFrameLines": unresolved,
    })
    return result
