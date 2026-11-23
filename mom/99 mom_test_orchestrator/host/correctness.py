from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import re
import sys
from typing import Any, Sequence

import artifacts


MACHINE_RESULT_MARKER = "[MOMTestOrchestrator][INFO] SCENARIO_RESULT "
SUMMARY_MARKER = "[MOMTestOrchestrator][INFO] RESULT "
CAMPAIGN_PHASE_MARKER = "[MOMCampaign][PHASE_RECEIPT] "

SUMMARY_PATTERN = re.compile(
    r"^status=(passed|failed) passed=([0-9]+) failed=([0-9]+) total=([0-9]+)$"
)


class CorrectnessError(ValueError):
    pass


RESULT_STATUSES = {"passed", "failed", "missing", "openmw_failed", "invalid"}


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise CorrectnessError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def _load_json_value(payload: str) -> Any:
    try:
        return json.loads(
            payload,
            object_pairs_hook=_strict_object,
            parse_constant=lambda value: (_ for _ in ()).throw(
                CorrectnessError(f"non-finite JSON number: {value}")
            ),
        )
    except json.JSONDecodeError as exc:
        raise CorrectnessError(f"invalid scenario receipt JSON: {exc}") from exc


def load_result(path: Path) -> dict[str, Any]:
    try:
        payload = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise CorrectnessError(f"cannot read harness result: {path}: {exc}") from exc
    value = _load_json_value(payload)
    if (
        isinstance(value, dict)
        and value.get("kind") == "mom.process-campaign.phase-receipt"
    ):
        return validate_campaign_phase_result(value)
    return validate_result(value)


def _validate_elapsed(value: dict[str, Any], fields: set[str]) -> None:
    # Historical receipts predate wall-clock measurement.
    if "elapsedSeconds" not in value:
        return
    fields.add("elapsedSeconds")
    elapsed = value["elapsedSeconds"]
    if (isinstance(elapsed, bool) or not isinstance(elapsed, (int, float))
            or not math.isfinite(elapsed) or elapsed < 0):
        raise CorrectnessError("elapsedSeconds must be a finite non-negative number")


def _validate_receipt(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CorrectnessError("scenario receipt must be an object")

    status = value.get("status")
    expected = {"id", "status", "frames"}
    if status == "failed":
        expected.add("error")
    _validate_elapsed(value, expected)
    if set(value) != expected:
        raise CorrectnessError("scenario receipt has an unsupported shape")

    identifier = value.get("id")
    frames = value.get("frames")
    if not isinstance(identifier, str) or not identifier:
        raise CorrectnessError("scenario receipt id must be a nonempty string")
    if status not in {"passed", "failed"}:
        raise CorrectnessError("scenario receipt status is unsupported")
    if isinstance(frames, bool) or not isinstance(frames, int) or frames < 0:
        raise CorrectnessError("scenario receipt frames must be a non-negative integer")
    if status == "failed" and (
        not isinstance(value.get("error"), str) or not value["error"]
    ):
        raise CorrectnessError("failed scenario receipt must include an error")
    return value


def _machine_receipts(lines: list[str]) -> list[dict[str, Any]] | None:
    payloads = [
        line.split(MACHINE_RESULT_MARKER, 1)[1]
        for line in lines
        if MACHINE_RESULT_MARKER in line
    ]
    if not payloads:
        return None

    receipts = [_validate_receipt(_load_json_value(payload)) for payload in payloads]
    identifiers = [receipt["id"] for receipt in receipts]
    if len(identifiers) != len(set(identifiers)):
        raise CorrectnessError("scenario receipt ids must be unique")
    return receipts


def parse_scenario_receipts(lines: list[str]) -> list[dict[str, Any]]:
    return _machine_receipts(lines) or []


def parse_summary(lines: list[str]) -> dict[str, Any] | None:
    payloads = [
        line.split(SUMMARY_MARKER, 1)[1]
        for line in lines
        if SUMMARY_MARKER in line
    ]
    if not payloads:
        return None
    if len(payloads) != 1:
        raise CorrectnessError("harness emitted multiple summary lines")

    match = SUMMARY_PATTERN.fullmatch(payloads[0])
    if match is None:
        raise CorrectnessError("invalid harness summary line")
    status, passed, failed, total = match.groups()
    result = {
        "status": status,
        "passed": int(passed),
        "failed": int(failed),
        "total": int(total),
    }
    if result["passed"] + result["failed"] != result["total"]:
        raise CorrectnessError("harness summary counts are inconsistent")
    if (status == "passed") != (result["failed"] == 0):
        raise CorrectnessError("harness summary status is inconsistent")
    return result


def _validate_campaign_engine_receipt(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise CorrectnessError("campaign engine phase receipt must be an object")
    status = value.get("status")
    expected = {
        "schemaVersion",
        "kind",
        "status",
        "scenario",
        "event",
    }
    if status == "failed":
        expected.add("error")
    if set(value) != expected:
        raise CorrectnessError(
            "campaign engine phase receipt has an unsupported shape"
        )
    if (
        value["schemaVersion"] != 1
        or value["kind"] != "mom.process-campaign.engine-phase"
    ):
        raise CorrectnessError(
            "campaign engine phase receipt schema/kind is unsupported"
        )
    if status not in {"passed", "failed"}:
        raise CorrectnessError(
            "campaign engine phase receipt status is unsupported"
        )
    if not isinstance(value["scenario"], str) or not value["scenario"]:
        raise CorrectnessError(
            "campaign engine phase receipt scenario must be nonempty"
        )
    expected_event = "save_complete" if status == "passed" else "save_failed"
    if value["event"] != expected_event:
        raise CorrectnessError(
            "campaign engine phase receipt event disagrees with its status"
        )
    if status == "failed" and (
        not isinstance(value["error"], str) or not value["error"]
    ):
        raise CorrectnessError(
            "failed campaign engine phase receipt must include an error"
        )
    return value


def parse_campaign_phase_receipt(
    lines: list[str],
) -> dict[str, Any] | None:
    payloads = [
        line.split(CAMPAIGN_PHASE_MARKER, 1)[1]
        for line in lines
        if CAMPAIGN_PHASE_MARKER in line
    ]
    if not payloads:
        return None
    if len(payloads) != 1:
        raise CorrectnessError(
            "harness emitted multiple campaign phase receipts"
        )
    return _validate_campaign_engine_receipt(_load_json_value(payloads[0]))


def validate_campaign_phase_result(value: object) -> dict[str, Any]:
    fields = {
        "schemaVersion",
        "kind",
        "status",
        "scenario",
        "openmwStatus",
        "engineReceipt",
        "log",
        "workdir",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise CorrectnessError(
            "campaign phase receipt result has an unsupported shape"
        )
    if (
        value["schemaVersion"] != 1
        or value["kind"] != "mom.process-campaign.phase-receipt"
    ):
        raise CorrectnessError(
            "campaign phase receipt result schema/kind is unsupported"
        )
    engine_receipt = _validate_campaign_engine_receipt(
        value["engineReceipt"]
    )
    if value["scenario"] != engine_receipt["scenario"]:
        raise CorrectnessError(
            "campaign phase receipt result scenario is inconsistent"
        )
    openmw_status = value["openmwStatus"]
    if isinstance(openmw_status, bool) or not isinstance(openmw_status, int):
        raise CorrectnessError(
            "campaign phase receipt result openmwStatus must be an integer"
        )
    expected_status = (
        "passed"
        if openmw_status == 0 and engine_receipt["status"] == "passed"
        else "failed"
    )
    if value["status"] != expected_status:
        raise CorrectnessError(
            "campaign phase receipt result status is inconsistent"
        )
    for field in ("scenario", "log", "workdir"):
        if not isinstance(value[field], str) or not value[field]:
            raise CorrectnessError(
                f"campaign phase receipt result {field} must be nonempty"
            )
    return value


def _validated_summary(
    summary: dict[str, Any],
    receipts: list[dict[str, Any]],
    selected_scenarios: list[str],
) -> dict[str, Any]:
    passed = sum(receipt["status"] == "passed" for receipt in receipts)
    failed = sum(receipt["status"] == "failed" for receipt in receipts)
    if (passed, failed, len(receipts)) != (
        summary["passed"],
        summary["failed"],
        summary["total"],
    ):
        raise CorrectnessError("scenario receipts do not match the harness summary")
    if selected_scenarios and sorted(receipt["id"] for receipt in receipts) != sorted(
        selected_scenarios
    ):
        raise CorrectnessError("scenario receipts do not match the requested scenarios")
    return summary


def validate_result(value: object) -> dict[str, Any]:
    fields = {
        "schemaVersion",
        "kind",
        "status",
        "passed",
        "failed",
        "total",
        "openmwStatus",
        "scenarios",
        "scenarioResults",
        "log",
        "workdir",
    }
    if isinstance(value, dict):
        _validate_elapsed(value, fields)
    if not isinstance(value, dict) or set(value) != fields:
        raise CorrectnessError("harness result has an unsupported shape")
    if (
        value["schemaVersion"] != 1
        or value["kind"] != "mom.correctness.result"
    ):
        raise CorrectnessError("harness result schema/kind is unsupported")
    status = value["status"]
    if status not in RESULT_STATUSES:
        raise CorrectnessError("harness result status is unsupported")
    openmw_status = value["openmwStatus"]
    if isinstance(openmw_status, bool) or not isinstance(openmw_status, int):
        raise CorrectnessError("harness result openmwStatus must be an integer")
    scenarios = value["scenarios"]
    if (
        not isinstance(scenarios, list)
        or not all(isinstance(item, str) and item for item in scenarios)
        or len(scenarios) != len(set(scenarios))
    ):
        raise CorrectnessError(
            "harness result scenarios must be unique nonempty strings"
        )
    receipts = value["scenarioResults"]
    if not isinstance(receipts, list):
        raise CorrectnessError("harness result scenarioResults must be an array")
    validated_receipts = [_validate_receipt(receipt) for receipt in receipts]
    identifiers = [receipt["id"] for receipt in validated_receipts]
    if len(identifiers) != len(set(identifiers)):
        raise CorrectnessError("scenario receipt ids must be unique")
    for field in ("log", "workdir"):
        if not isinstance(value[field], str) or not value[field]:
            raise CorrectnessError(
                f"harness result {field} must be a nonempty string"
            )

    counts = (value["passed"], value["failed"], value["total"])
    if status in {"passed", "failed"}:
        if any(
            isinstance(count, bool) or not isinstance(count, int) or count < 0
            for count in counts
        ):
            raise CorrectnessError(
                "completed harness result counts must be non-negative integers"
            )
        passed, failed, total = counts
        if passed + failed != total:
            raise CorrectnessError("harness result counts are inconsistent")
        if (status == "passed") != (failed == 0):
            raise CorrectnessError("harness result status is inconsistent")
        if (
            sum(receipt["status"] == "passed" for receipt in receipts) != passed
            or sum(receipt["status"] == "failed" for receipt in receipts) != failed
            or len(receipts) != total
        ):
            raise CorrectnessError(
                "harness result receipts disagree with its counts"
            )
        if scenarios and sorted(identifiers) != sorted(scenarios):
            raise CorrectnessError(
                "harness result receipts disagree with requested scenarios"
            )
        if openmw_status != 0:
            raise CorrectnessError(
                "completed harness result has a failed OpenMW status"
            )
    else:
        if counts != (None, None, None):
            raise CorrectnessError(
                "incomplete harness result must not report summary counts"
            )
        if status == "openmw_failed":
            if openmw_status == 0:
                raise CorrectnessError(
                    "openmw_failed harness result has a successful process status"
                )
        elif openmw_status != 0:
            raise CorrectnessError(
                "non-OpenMW harness failure has a failed process status"
            )
    return value


def build_result(
    *,
    log_path: Path,
    work_directory: Path,
    selected_scenarios: list[str],
    openmw_status: int,
    elapsed_seconds: float | None = None,
) -> dict[str, Any]:
    base = {
        "schemaVersion": 1,
        "kind": "mom.correctness.result",
        "status": "missing",
        "passed": None,
        "failed": None,
        "total": None,
        "openmwStatus": openmw_status,
        "scenarios": selected_scenarios,
        "scenarioResults": [],
        "log": str(log_path),
        "workdir": str(work_directory),
    }

    if elapsed_seconds is not None:
        base["elapsedSeconds"] = elapsed_seconds

    if not log_path.is_file():
        if openmw_status != 0:
            base["status"] = "openmw_failed"
        return validate_result(base)

    lines = log_path.read_text(encoding="utf-8", errors="replace").splitlines()
    try:
        campaign_receipt = parse_campaign_phase_receipt(lines)
        if campaign_receipt is not None:
            if (
                selected_scenarios != [campaign_receipt["scenario"]]
                or not campaign_receipt["scenario"].startswith("campaign_")
            ):
                raise CorrectnessError(
                    "campaign phase receipt does not match the requested phase"
                )
            return validate_campaign_phase_result({
                "schemaVersion": 1,
                "kind": "mom.process-campaign.phase-receipt",
                "status": (
                    "passed"
                    if openmw_status == 0
                    and campaign_receipt["status"] == "passed"
                    else "failed"
                ),
                "scenario": campaign_receipt["scenario"],
                "openmwStatus": openmw_status,
                "engineReceipt": campaign_receipt,
                "log": str(log_path),
                "workdir": str(work_directory),
            })
        receipts = parse_scenario_receipts(lines)
        base["scenarioResults"] = receipts
        if openmw_status != 0:
            base["status"] = "openmw_failed"
            return validate_result(base)
        summary = parse_summary(lines)
        if summary is None:
            return validate_result(base)
        base.update(_validated_summary(summary, receipts, selected_scenarios))
    except CorrectnessError:
        base["status"] = "openmw_failed" if openmw_status != 0 else "invalid"
    return validate_result(base)


def _result_command(arguments: argparse.Namespace) -> int:
    result = build_result(
        log_path=arguments.log,
        work_directory=arguments.workdir,
        selected_scenarios=arguments.scenario,
        openmw_status=arguments.openmw_status,
    )
    artifacts.write_json(arguments.output, result)
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
    return 0 if result["status"] == "passed" else 1


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(description="MOM correctness artifact support")
    commands = value.add_subparsers(dest="command_name", required=True)

    result = commands.add_parser("result")
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--log", type=Path, required=True)
    result.add_argument("--workdir", type=Path, required=True)
    result.add_argument("--openmw-status", type=int, required=True)
    result.add_argument("--scenario", action="append", default=[])
    result.set_defaults(handler=_result_command)

    return value


def main(argv: Sequence[str] | None = None) -> int:
    arguments = parser().parse_args(argv)
    try:
        return arguments.handler(arguments)
    except (CorrectnessError, OSError) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
