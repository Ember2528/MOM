from __future__ import annotations

import json
from pathlib import Path
from typing import Any

import statistics as harness_statistics


class ResultError(ValueError):
    pass


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ResultError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(
                stream,
                object_pairs_hook=_strict_object,
                parse_constant=lambda value: (_ for _ in ()).throw(
                    ResultError(f"non-finite JSON number: {value}")
                ),
            )
    except (OSError, json.JSONDecodeError) as exc:
        raise ResultError(f"cannot read JSON {path}: {exc}") from exc


def _positive_int(value: object, label: str, *, allow_zero: bool = False) -> int:
    minimum = 0 if allow_zero else 1
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        qualifier = "non-negative" if allow_zero else "positive"
        raise ResultError(f"{label} must be a {qualifier} integer")
    return value


def _finite(value: object, label: str, *, minimum: float | None = None) -> float:
    try:
        result = harness_statistics.finite_number(value, label)
    except ValueError as exc:
        raise ResultError(str(exc)) from exc
    if minimum is not None and result < minimum:
        raise ResultError(f"{label} must be at least {minimum}")
    return result


def _sha256(value: object, label: str) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise ResultError(f"{label} must be a lowercase SHA-256 value")
    return value


def load_contracts(performance_root: Path) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any]]:
    catalog = load_json(performance_root / "workloads.json")
    profiles = load_json(performance_root / "profiles.json")
    budgets = load_json(performance_root / "budgets.json")
    validate_catalog(catalog)
    validate_profiles(profiles)
    validate_budgets(budgets, catalog)
    return catalog, profiles, budgets


def validate_catalog(catalog: object) -> None:
    if not isinstance(catalog, dict) or catalog.get("schemaVersion") != 3:
        raise ResultError("workload catalog schemaVersion must be 3")
    workloads = catalog.get("workloads")
    if not isinstance(workloads, list) or not workloads:
        raise ResultError("workload catalog must contain workloads")
    seen: set[str] = set()
    required = {
        "id",
        "version",
        "category",
        "modes",
        "operations",
        "minimumSampleSeconds",
        "gcPolicy",
        "semantics",
        "requiresFreshProcess",
        "contractSources",
    }
    for index, workload in enumerate(workloads):
        label = f"workloads[{index}]"
        if not isinstance(workload, dict) or set(workload) != required:
            raise ResultError(f"{label} has an unsupported shape")
        identifier = workload["id"]
        if not isinstance(identifier, str) or not identifier or identifier in seen:
            raise ResultError(f"{label}.id must be nonempty and unique")
        seen.add(identifier)
        _positive_int(workload["version"], f"{label}.version")
        _positive_int(workload["operations"], f"{label}.operations")
        _finite(workload["minimumSampleSeconds"], f"{label}.minimumSampleSeconds", minimum=0)
        if not isinstance(workload["category"], str) or not workload["category"]:
            raise ResultError(f"{label}.category is required")
        modes = workload["modes"]
        if not isinstance(modes, list) or not modes or len(modes) != len(set(modes)):
            raise ResultError(f"{label}.modes must be a unique nonempty list")
        if any(mode not in {"standalone", "embedded", "integration"} for mode in modes):
            raise ResultError(f"{label}.modes contains an unsupported mode")
        if workload["gcPolicy"] not in {"inclusive", "forced", "prohibited"}:
            raise ResultError(f"{label}.gcPolicy is unsupported")
        if workload["semantics"] not in {"steady_state", "cold_start"}:
            raise ResultError(f"{label}.semantics is unsupported")
        if not isinstance(workload["requiresFreshProcess"], bool):
            raise ResultError(f"{label}.requiresFreshProcess must be boolean")
        contract_sources = workload["contractSources"]
        if (
            not isinstance(contract_sources, list)
            or not contract_sources
            or not all(
                isinstance(source, str) and source for source in contract_sources
            )
            or contract_sources != sorted(set(contract_sources))
        ):
            raise ResultError(
                f"{label}.contractSources must be a sorted unique nonempty list"
            )
        for source in contract_sources:
            path = Path(source)
            if (
                path.is_absolute()
                or ".." in path.parts
                or path.as_posix() != source
            ):
                raise ResultError(f"{label}.contractSources contains an invalid path")


def validate_profiles(profiles: object) -> None:
    if not isinstance(profiles, dict) or profiles.get("schemaVersion") != 2:
        raise ResultError("profile schemaVersion must be 2")
    definitions = profiles.get("profiles")
    if not isinstance(definitions, dict) or set(definitions) != {
        "quick", "standard", "release", "memory", "profile"
    }:
        raise ResultError(
            "run profiles must define quick, standard, release, memory, and profile"
        )
    for name, profile in definitions.items():
        fields = {
            "processes",
            "samplesPerProcess",
            "warmupsPerProcess",
            "memoryEvidence",
        }
        supported_shapes = {
            frozenset(fields),
            frozenset(fields | {"requiresSingleWorkload"}),
        }
        if not isinstance(profile, dict) or frozenset(profile) not in supported_shapes:
            raise ResultError(f"profile {name} has an unsupported shape")
        _positive_int(profile.get("processes"), f"profile {name}.processes")
        _positive_int(profile.get("samplesPerProcess"), f"profile {name}.samplesPerProcess")
        _positive_int(
            profile.get("warmupsPerProcess"),
            f"profile {name}.warmupsPerProcess",
            allow_zero=True,
        )
        if not isinstance(profile.get("memoryEvidence"), bool):
            raise ResultError(f"profile {name}.memoryEvidence must be boolean")
        if "requiresSingleWorkload" in profile and not isinstance(
            profile["requiresSingleWorkload"], bool
        ):
            raise ResultError(f"profile {name}.requiresSingleWorkload must be boolean")


def validate_budgets(budgets: object, catalog: dict[str, Any]) -> None:
    if not isinstance(budgets, dict) or budgets.get("schemaVersion") != 4:
        raise ResultError("budget schemaVersion must be 4")
    if set(budgets) != {
        "schemaVersion", "absoluteMicros", "absoluteMemoryKb", "comparison"
    }:
        raise ResultError("budget contract has an unsupported shape")
    absolute = budgets.get("absoluteMicros")
    if not isinstance(absolute, dict) or set(absolute) != {
        "process_cpu", "monotonic_wall"
    }:
        raise ResultError("budgets must define both supported clocks")
    by_id = catalog_by_id(catalog)
    clock_modes = {
        "process_cpu": {"standalone"},
        "monotonic_wall": {"embedded", "integration"},
    }
    for clock, entries in absolute.items():
        if not isinstance(entries, dict) or not set(entries) <= set(by_id):
            raise ResultError(f"absolute budget IDs are invalid for {clock}")
        for identifier, value in entries.items():
            _finite(value, f"budget {clock}/{identifier}", minimum=0)
            if not clock_modes[clock].intersection(by_id[identifier]["modes"]):
                raise ResultError(
                    f"budget {clock}/{identifier} cannot apply to any supported mode"
                )
    memory = budgets.get("absoluteMemoryKb")
    if not isinstance(memory, dict) or set(memory) != {
        "standalone", "embedded", "integration"
    }:
        raise ResultError("budgets must define memory limits for every mode")
    for mode, runtimes in memory.items():
        if not isinstance(runtimes, dict):
            raise ResultError(f"memory budgets for {mode} must be an object")
        for runtime_identity, lanes in runtimes.items():
            if not isinstance(runtime_identity, str) or not runtime_identity:
                raise ResultError(
                    f"memory budget runtime identity for {mode} is invalid"
                )
            if ";binary=" in runtime_identity:
                identity_prefix, separator, binary_sha256 = (
                    runtime_identity.rpartition(";binary=")
                )
                if (
                    not separator
                    or not identity_prefix
                    or ";binary=" in identity_prefix
                    or len(binary_sha256) != 64
                    or any(
                        character not in "0123456789abcdef"
                        for character in binary_sha256
                    )
                ):
                    raise ResultError(
                        f"memory budget runtime identity for {mode} "
                        "has an invalid binary SHA-256"
                    )
            if not isinstance(lanes, dict) or set(lanes) != {
                "allocated", "retained"
            }:
                raise ResultError(
                    f"memory budgets for {mode}/{runtime_identity} "
                    "must define allocated and retained limits"
                )
            for lane, entries in lanes.items():
                if (
                    not isinstance(entries, dict)
                    or not set(entries) <= set(by_id)
                ):
                    raise ResultError(
                        "absolute memory budget IDs are invalid for "
                        f"{mode}/{runtime_identity}/{lane}"
                    )
                for identifier, value in entries.items():
                    _finite(
                        value,
                        "memory budget "
                        f"{mode}/{runtime_identity}/{lane}/{identifier}",
                        minimum=0,
                    )
                    if mode not in by_id[identifier]["modes"]:
                        raise ResultError(
                            f"memory budget {mode}/{runtime_identity}/"
                            f"{lane}/{identifier} cannot apply to that mode"
                        )
                    if lane == "allocated" and (
                        mode != "standalone"
                        or by_id[identifier]["gcPolicy"] != "inclusive"
                    ):
                        raise ResultError(
                            f"allocation budget {mode}/{runtime_identity}/"
                            f"{identifier} requires standalone inclusive GC"
                        )
    comparison = budgets.get("comparison")
    if not isinstance(comparison, dict) or set(comparison) != {
        "confidence",
        "bootstrapResamples",
        "minimumSamples",
        "maximumRegressionRatio",
        "seed",
    }:
        raise ResultError("comparison budget has an unsupported shape")
    confidence = _finite(comparison["confidence"], "comparison confidence")
    if not 0 < confidence < 1:
        raise ResultError("comparison confidence must be between zero and one")
    _positive_int(comparison["bootstrapResamples"], "bootstrap resamples")
    _positive_int(comparison["minimumSamples"], "minimum samples")
    if _finite(comparison["maximumRegressionRatio"], "maximum regression ratio") <= 1:
        raise ResultError("maximum regression ratio must exceed one")
    _positive_int(comparison["seed"], "comparison seed", allow_zero=True)


def catalog_by_id(catalog: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {item["id"]: item for item in catalog["workloads"]}


def memory_runtime_identity(runtime: object) -> str:
    if not isinstance(runtime, dict):
        raise ResultError("memory runtime identity requires a runtime object")
    lua = runtime.get("lua")
    jit = runtime.get("jit")
    if not isinstance(lua, str) or not lua:
        raise ResultError("memory runtime identity requires a Lua version")
    if not isinstance(jit, dict) or not isinstance(jit.get("available"), bool):
        raise ResultError("memory runtime identity requires JIT availability")
    executable_sha256 = runtime.get("executableSha256")
    binary = (
        f";binary={_sha256(executable_sha256, 'Lua executable identity')}"
        if executable_sha256 is not None
        else ""
    )
    if not jit["available"]:
        return f"{lua};jit=none{binary}"

    enabled = jit.get("enabled")
    if enabled is not None and not isinstance(enabled, bool):
        raise ResultError("memory runtime JIT enabled state is invalid")
    version = jit.get("version")
    architecture = jit.get("architecture")
    for label, value in (
        ("version", version),
        ("architecture", architecture),
    ):
        if value is not None and (not isinstance(value, str) or not value):
            raise ResultError(f"memory runtime JIT {label} is invalid")
    enabled_name = (
        "unknown" if enabled is None else "on" if enabled else "off"
    )
    return (
        f"{lua};jit={version or 'unknown'};"
        f"enabled={enabled_name};arch={architecture or 'unknown'}{binary}"
    )


def select_workloads(
    catalog: dict[str, Any], identifiers: list[str] | None, mode: str
) -> list[dict[str, Any]]:
    by_id = catalog_by_id(catalog)
    selected_ids = identifiers or [item["id"] for item in catalog["workloads"] if mode in item["modes"]]
    if len(selected_ids) != len(set(selected_ids)):
        raise ResultError("selected workload IDs must be unique")
    selected: list[dict[str, Any]] = []
    for identifier in selected_ids:
        workload = by_id.get(identifier)
        if workload is None:
            raise ResultError(f"unknown workload: {identifier}")
        if mode not in workload["modes"]:
            raise ResultError(f"workload {identifier} does not support {mode}")
        selected.append(workload)
    if not selected:
        raise ResultError("at least one workload must be selected")
    return selected


def validate_raw_result(
    raw: object,
    catalog: dict[str, Any],
    *,
    expected_mode: str | None = None,
    expected_ids: list[str] | None = None,
    expected_samples: int | None = None,
    expected_warmups: int | None = None,
    expected_memory: bool | None = None,
) -> dict[str, Any]:
    if not isinstance(raw, dict):
        raise ResultError("raw result must be an object")
    base_fields = {
        "schemaVersion",
        "kind",
        "status",
        "mode",
        "clock",
        "memoryEvidence",
        "runtime",
        "warmupsPerCase",
        "samplesPerCase",
        "results",
    }
    if set(raw) - {"capturedAtUtc", "error"} != base_fields:
        raise ResultError("raw result has an unsupported shape")
    if raw.get("schemaVersion") != 5 or raw.get("kind") != "mom.performance.raw":
        raise ResultError("raw result schema/kind is unsupported")
    mode = raw.get("mode")
    clock = raw.get("clock")
    expected_clock = {
        "standalone": "process_cpu",
        "embedded": "monotonic_wall",
        "integration": "monotonic_wall",
    }.get(mode)
    if expected_clock is None or clock != expected_clock:
        raise ResultError("raw result mode and clock do not match")
    if expected_mode is not None and mode != expected_mode:
        raise ResultError(f"raw result mode is {mode}, expected {expected_mode}")
    memory_evidence = raw.get("memoryEvidence")
    if not isinstance(memory_evidence, bool):
        raise ResultError("raw result memoryEvidence must be boolean")
    if expected_memory is not None and memory_evidence != expected_memory:
        raise ResultError(
            "raw result memory evidence differs from the run specification"
        )
    raw_status = raw.get("status")
    if raw_status not in {"passed", "failed", "invalid"}:
        raise ResultError("raw result status is unsupported")
    runtime = raw.get("runtime")
    if not isinstance(runtime, dict):
        raise ResultError("raw result runtime identity is required")
    if mode == "standalone":
        _sha256(
            runtime.get("executableSha256"),
            "standalone Lua executable identity",
        )
    captured_at = raw.get("capturedAtUtc")
    if captured_at is not None and (
        not isinstance(captured_at, str) or not captured_at
    ):
        raise ResultError("raw result capturedAtUtc must be a nonempty string or null")
    if "error" in raw and (
        raw_status != "failed"
        or not isinstance(raw["error"], str)
        or not raw["error"]
    ):
        raise ResultError("raw result error is valid only for a failed result")
    samples_per_case = _positive_int(raw.get("samplesPerCase"), "samplesPerCase")
    warmups_per_case = _positive_int(
        raw.get("warmupsPerCase"), "warmupsPerCase", allow_zero=True
    )
    if expected_samples is not None and samples_per_case != expected_samples:
        raise ResultError("raw result sample count differs from the run specification")
    if expected_warmups is not None and warmups_per_case != expected_warmups:
        raise ResultError("raw result warmup count differs from the run specification")

    results = raw.get("results")
    if not isinstance(results, list):
        raise ResultError("raw result entries must be an array")
    if "error" in raw and results:
        raise ResultError("raw result-level error cannot accompany workload results")
    actual_ids: list[str] = []
    by_id = catalog_by_id(catalog)
    derived = "failed" if "error" in raw else "passed"
    for index, entry in enumerate(results):
        label = f"results[{index}]"
        if not isinstance(entry, dict):
            raise ResultError(f"{label} must be an object")
        entry_base_fields = {
            "id",
            "version",
            "category",
            "unit",
            "operations",
            "minimumSampleSeconds",
            "gcPolicy",
            "semantics",
            "detail",
            "status",
            "samples",
        }
        status = entry.get("status")
        expected_entry_fields = (
            entry_base_fields | {"error"}
            if status == "failed"
            else entry_base_fields | {"checksum"}
        )
        if set(entry) != expected_entry_fields:
            raise ResultError(f"{label} has an unsupported shape")
        identifier = entry.get("id")
        if not isinstance(identifier, str) or identifier in actual_ids:
            raise ResultError(f"{label}.id must be nonempty and unique")
        actual_ids.append(identifier)
        definition = by_id.get(identifier)
        if definition is None or mode not in definition["modes"]:
            raise ResultError(f"{label} is not declared for {mode}")
        for field in (
            "version", "category", "operations", "minimumSampleSeconds", "gcPolicy", "semantics"
        ):
            if entry.get(field) != definition[field]:
                raise ResultError(f"{label}.{field} differs from the workload catalog")
        if entry.get("unit") != "microseconds_per_operation":
            raise ResultError(f"{label}.unit is unsupported")
        if not isinstance(entry.get("detail"), dict):
            raise ResultError(f"{label}.detail must be an object")
        if status not in {"passed", "failed", "invalid"}:
            raise ResultError(f"{label}.status is unsupported")
        samples = entry.get("samples")
        if not isinstance(samples, list):
            raise ResultError(f"{label}.samples must be an array")
        if status != "failed" and len(samples) != samples_per_case:
            raise ResultError(f"{label}.samples has the wrong count")
        if status == "failed" and len(samples) > samples_per_case:
            raise ResultError(f"{label}.samples exceeds the requested count")
        checksum = entry.get("checksum")
        if status != "failed" and (
            not isinstance(checksum, str) or not checksum
        ):
            raise ResultError(f"{label}.checksum must be a nonempty string")
        expected_sample_checksum = checksum
        case_baseline: dict[str, Any] | None = None
        for sample_index, sample in enumerate(samples):
            sample_label = f"{label}.samples[{sample_index}]"
            if not isinstance(sample, dict):
                raise ResultError(f"{sample_label} must be an object")
            sample_base_fields = {
                "elapsedSeconds",
                "operations",
                "checksum",
                "valid",
            }
            gc_fields = {
                "gcCaseBefore",
                "gcSetupBefore",
                "gcBefore",
                "gcAfter",
                "gcRetained",
            }
            required_sample_fields = (
                sample_base_fields | gc_fields
                if memory_evidence
                else sample_base_fields
            )
            optional_sample_fields = {
                "processCpuSeconds",
                "evidence",
                "invalidReason",
            }
            if (
                not required_sample_fields <= set(sample)
                or not set(sample)
                <= required_sample_fields | optional_sample_fields
            ):
                raise ResultError(f"{sample_label} has an unsupported shape")
            elapsed = _finite(sample.get("elapsedSeconds"), f"{sample_label}.elapsedSeconds", minimum=0)
            if sample.get("operations") != definition["operations"]:
                raise ResultError(f"{sample_label}.operations differs from the catalog")
            sample_checksum = sample.get("checksum")
            if not isinstance(sample_checksum, str) or not sample_checksum:
                raise ResultError(f"{sample_label}.checksum is inconsistent")
            if expected_sample_checksum is None:
                expected_sample_checksum = sample_checksum
            elif sample_checksum != expected_sample_checksum:
                raise ResultError(f"{sample_label}.checksum is inconsistent")
            if not isinstance(sample.get("valid"), bool):
                raise ResultError(f"{sample_label}.valid must be boolean")
            if sample["valid"] != (elapsed >= definition["minimumSampleSeconds"]):
                raise ResultError(f"{sample_label}.valid disagrees with the timing floor")
            if sample["valid"]:
                if "invalidReason" in sample:
                    raise ResultError(
                        f"{sample_label}.invalidReason is invalid for a valid sample"
                    )
            elif sample.get("invalidReason") != "below_timing_floor":
                raise ResultError(
                    f"{sample_label}.invalidReason must preserve the timing-floor failure"
                )
            if sample.get("processCpuSeconds") is not None:
                _finite(sample["processCpuSeconds"], f"{sample_label}.processCpuSeconds", minimum=0)
            if "evidence" in sample and not isinstance(sample["evidence"], dict):
                raise ResultError(f"{sample_label}.evidence must be an object")
            if memory_evidence:
                for gc_field in (
                    "gcCaseBefore",
                    "gcSetupBefore",
                    "gcBefore",
                    "gcAfter",
                    "gcRetained",
                ):
                    gc = sample.get(gc_field)
                    if not isinstance(gc, dict) or set(gc) != {"memoryKb", "running"}:
                        raise ResultError(f"{sample_label}.{gc_field} must be an object")
                    _finite(
                        gc.get("memoryKb"),
                        f"{sample_label}.{gc_field}.memoryKb",
                        minimum=0,
                    )
                    if gc.get("running") is not None and not isinstance(
                        gc.get("running"), bool
                    ):
                        raise ResultError(
                            f"{sample_label}.{gc_field}.running"
                            " must be boolean or null"
                        )
                current_case_baseline = sample["gcCaseBefore"]
                if case_baseline is None:
                    case_baseline = current_case_baseline
                elif current_case_baseline != case_baseline:
                    raise ResultError(
                        f"{sample_label}.gcCaseBefore differs from the "
                        "case-lifetime baseline"
                    )
        if status == "failed":
            derived = "failed"
            if not isinstance(entry.get("error"), str) or not entry["error"]:
                raise ResultError(f"{label}.error is required for a failed workload")
        else:
            has_invalid_sample = any(not sample["valid"] for sample in samples)
            expected_status = "invalid" if has_invalid_sample else "passed"
            if status != expected_status:
                raise ResultError(
                    f"{label}.status disagrees with its sample validity"
                )
            if status == "invalid" and derived != "failed":
                derived = "invalid"
    if expected_ids is not None and actual_ids != expected_ids:
        raise ResultError(f"raw workload order differs: {actual_ids} != {expected_ids}")
    if raw_status != derived:
        raise ResultError("raw result status disagrees with its workload results")
    return raw


def validate_allocation_result(
    raw: object,
    catalog: dict[str, Any],
    *,
    expected_id: str | None = None,
    expected_runtime: dict[str, Any] | None = None,
) -> dict[str, Any]:
    fields = {
        "schemaVersion",
        "kind",
        "status",
        "mode",
        "capturedAtUtc",
        "runtime",
        "warmupsPerCase",
        "samplesPerCase",
        "result",
    }
    if not isinstance(raw, dict) or set(raw) != fields:
        raise ResultError("allocation result has an unsupported shape")
    if (
        raw.get("schemaVersion") != 1
        or raw.get("kind") != "mom.performance.allocation"
    ):
        raise ResultError("allocation result schema/kind is unsupported")
    if raw.get("mode") != "standalone":
        raise ResultError("allocation result must use standalone mode")
    if raw.get("warmupsPerCase") != 1 or raw.get("samplesPerCase") != 1:
        raise ResultError(
            "allocation result must contain one warmup and one sample"
        )
    captured_at = raw.get("capturedAtUtc")
    if captured_at is not None and (
        not isinstance(captured_at, str) or not captured_at
    ):
        raise ResultError(
            "allocation result capturedAtUtc must be a nonempty string or null"
        )
    runtime = raw.get("runtime")
    if not isinstance(runtime, dict):
        raise ResultError("allocation result runtime identity is required")
    _sha256(
        runtime.get("executableSha256"),
        "allocation Lua executable identity",
    )
    if expected_runtime is not None and runtime != expected_runtime:
        raise ResultError(
            "allocation result runtime differs from the timing runtime"
        )

    result = raw.get("result")
    base_fields = {
        "id",
        "version",
        "category",
        "unit",
        "operations",
        "gcPolicy",
        "semantics",
        "detail",
        "status",
        "samples",
    }
    if not isinstance(result, dict):
        raise ResultError("allocation result workload is required")
    status = result.get("status")
    expected_fields = (
        base_fields | {"error"}
        if status == "failed"
        else base_fields | {"checksum"}
    )
    if set(result) != expected_fields:
        raise ResultError(
            "allocation result workload has an unsupported shape"
        )
    identifier = result.get("id")
    definition = (
        catalog_by_id(catalog).get(identifier)
        if isinstance(identifier, str)
        else None
    )
    if (
        definition is None
        or "standalone" not in definition["modes"]
        or definition["gcPolicy"] != "inclusive"
    ):
        raise ResultError(
            "allocation result workload is not standalone inclusive"
        )
    if expected_id is not None and identifier != expected_id:
        raise ResultError(
            f"allocation result workload is {identifier}, expected {expected_id}"
        )
    for field in (
        "version",
        "category",
        "operations",
        "gcPolicy",
        "semantics",
    ):
        if result.get(field) != definition[field]:
            raise ResultError(
                f"allocation result workload.{field} differs from the catalog"
            )
    if result.get("unit") != "kilobytes_per_timed_body":
        raise ResultError("allocation result workload unit is unsupported")
    if not isinstance(result.get("detail"), dict):
        raise ResultError("allocation result workload detail must be an object")
    if status not in {"passed", "failed"} or raw.get("status") != status:
        raise ResultError("allocation result status is inconsistent")
    samples = result.get("samples")
    if not isinstance(samples, list):
        raise ResultError("allocation result samples must be an array")
    if status == "failed":
        if (
            samples
            or not isinstance(result.get("error"), str)
            or not result["error"]
        ):
            raise ResultError(
                "failed allocation result requires an error and no sample"
            )
        return raw
    if len(samples) != 1:
        raise ResultError(
            "passed allocation result requires exactly one sample"
        )
    checksum = result.get("checksum")
    if not isinstance(checksum, str) or not checksum:
        raise ResultError("allocation result checksum is required")
    sample = samples[0]
    sample_fields = {
        "operations",
        "checksum",
        "gcBefore",
        "gcStoppedAfter",
        "gcRetained",
    }
    if not isinstance(sample, dict) or set(sample) != sample_fields:
        raise ResultError("allocation result sample has an unsupported shape")
    if (
        sample["operations"] != definition["operations"]
        or sample["checksum"] != checksum
    ):
        raise ResultError(
            "allocation result sample identity/checksum is inconsistent"
        )
    snapshots: dict[str, dict[str, Any]] = {}
    for field, expected_running in (
        ("gcBefore", True),
        ("gcStoppedAfter", False),
        ("gcRetained", True),
    ):
        snapshot = sample[field]
        if (
            not isinstance(snapshot, dict)
            or set(snapshot) != {"memoryKb", "running"}
            or snapshot.get("running") is not expected_running
        ):
            raise ResultError(
                f"allocation result sample.{field} has an invalid collector state"
            )
        _finite(
            snapshot.get("memoryKb"),
            f"allocation result sample.{field}.memoryKb",
            minimum=0,
        )
        snapshots[field] = snapshot
    if (
        snapshots["gcStoppedAfter"]["memoryKb"]
        < snapshots["gcBefore"]["memoryKb"]
    ):
        raise ResultError(
            "allocation result stopped heap shrank during the timed body"
        )
    return raw


def _derived_workload_status(
    process_runs: list[dict[str, Any]],
    budget: float | None,
    allocation_probe: dict[str, Any] | None = None,
    memory_allocated_budget: float | None = None,
    memory_retained_budget: float | None = None,
) -> tuple[str, str | None, str | None]:
    statuses = [run["status"] for run in process_runs]
    checksums = {
        run["checksum"]
        for run in process_runs
        if run["checksum"] is not None
    }
    values = [
        value
        for run in process_runs
        for value in run["samplesMicros"]
    ]
    memory_retained = [
        value
        for run in process_runs
        for value in run["memoryRetainedDeltaKb"]
    ]
    status = "passed"
    reason = None
    if not statuses or "failed" in statuses:
        status, reason = "failed", "semantic_failure"
    elif "invalid" in statuses or not values:
        status, reason = "invalid", "invalid_or_missing_sample"
    elif len(checksums) != 1:
        status, reason = "failed", "checksum_drift"
    elif budget is not None and max(values) > budget:
        status, reason = "failed", "absolute_budget_exceeded"
    elif (
        allocation_probe is not None
        and allocation_probe["status"] == "failed"
    ):
        status, reason = "failed", "allocation_probe_failure"
    elif (
        allocation_probe is not None
        and len(checksums) == 1
        and allocation_probe["checksum"] != next(iter(checksums))
    ):
        status, reason = "failed", "allocation_checksum_drift"
    elif (
        memory_allocated_budget is not None
        and allocation_probe is not None
        and allocation_probe["memoryAllocatedDeltaKb"]
            > memory_allocated_budget
    ):
        status, reason = "failed", "absolute_memory_allocated_budget_exceeded"
    elif (
        memory_retained_budget is not None
        and memory_retained
        and max(memory_retained) > memory_retained_budget
    ):
        status, reason = "failed", "absolute_memory_retained_budget_exceeded"
    checksum = next(iter(checksums)) if len(checksums) == 1 else None
    return status, reason, checksum


def _sample_allocation_result(raw: dict[str, Any]) -> dict[str, Any]:
    result = raw["result"]
    if result["status"] == "failed":
        return {
            "status": "failed",
            "checksum": None,
            "error": result["error"],
            "gcBeforeKb": None,
            "gcStoppedAfterKb": None,
            "gcRetainedKb": None,
            "memoryAllocatedDeltaKb": None,
            "memoryRetainedDeltaKb": None,
        }
    sample = result["samples"][0]
    before = sample["gcBefore"]["memoryKb"]
    stopped_after = sample["gcStoppedAfter"]["memoryKb"]
    retained = sample["gcRetained"]["memoryKb"]
    return {
        "status": "passed",
        "checksum": result["checksum"],
        "error": None,
        "gcBeforeKb": before,
        "gcStoppedAfterKb": stopped_after,
        "gcRetainedKb": retained,
        "memoryAllocatedDeltaKb": stopped_after - before,
        "memoryRetainedDeltaKb": retained - before,
    }


def _sample_process_run(
    result: dict[str, Any], memory_evidence: bool
) -> dict[str, Any]:
    timings: list[float] = []
    setup_deltas: list[float] = []
    timed_transient_deltas: list[float] = []
    timed_retained_deltas: list[float] = []
    after_deltas: list[float] = []
    retained_deltas: list[float] = []
    for sample in result["samples"]:
        timings.append(
            sample["elapsedSeconds"] * 1_000_000 / sample["operations"]
        )
        if memory_evidence:
            case_before = sample["gcCaseBefore"]["memoryKb"]
            setup_before = sample["gcSetupBefore"]["memoryKb"]
            timed_before = sample["gcBefore"]["memoryKb"]
            after = sample["gcAfter"]["memoryKb"]
            retained = sample["gcRetained"]["memoryKb"]
            setup_deltas.append(timed_before - setup_before)
            timed_transient_deltas.append(after - timed_before)
            timed_retained_deltas.append(retained - timed_before)
            after_deltas.append(after - case_before)
            retained_deltas.append(retained - case_before)
    return {
        "status": result["status"],
        "checksum": result.get("checksum"),
        "samplesMicros": timings,
        "memorySetupDeltaKb": setup_deltas,
        "memoryTimedTransientDeltaKb": timed_transient_deltas,
        "memoryTimedRetainedDeltaKb": timed_retained_deltas,
        "memoryAfterDeltaKb": after_deltas,
        "memoryRetainedDeltaKb": retained_deltas,
    }


def summarize_raw_results(
    raw_results: list[dict[str, Any]],
    selected: list[dict[str, Any]],
    budgets: dict[str, Any],
    *,
    profile: str,
    comparability: dict[str, Any],
    allocation_results: list[dict[str, Any]] | None = None,
) -> dict[str, Any]:
    if not raw_results:
        raise ResultError("cannot summarize an empty raw result set")
    mode = raw_results[0]["mode"]
    clock = raw_results[0]["clock"]
    runtime = raw_results[0]["runtime"]
    memory_evidence = raw_results[0]["memoryEvidence"]
    for raw in raw_results[1:]:
        if (
            raw["mode"] != mode
            or raw["clock"] != clock
            or raw["runtime"] != runtime
            or raw["memoryEvidence"] != memory_evidence
        ):
            raise ResultError("raw runtime identities differ within one experiment")
    if (
        comparability.get("runParameters", {}).get("memoryEvidence")
        is not memory_evidence
    ):
        raise ResultError(
            "raw memory evidence differs from the run comparability context"
        )

    gathered: dict[str, list[dict[str, Any]]] = {
        item["id"]: [] for item in selected
    }
    for raw in raw_results:
        for result in raw["results"]:
            gathered[result["id"]].append(
                _sample_process_run(result, memory_evidence)
            )

    overall = "passed"
    workloads: list[dict[str, Any]] = []
    clock_budgets = budgets["absoluteMicros"][clock]
    memory_runtime = memory_runtime_identity(runtime)
    runtime_memory_budgets = budgets["absoluteMemoryKb"][mode].get(
        memory_runtime,
        {"allocated": {}, "retained": {}},
    )
    memory_allocated_budgets = runtime_memory_budgets["allocated"]
    memory_retained_budgets = runtime_memory_budgets["retained"]
    allocation_by_id: dict[str, dict[str, Any]] = {}
    for raw in allocation_results or []:
        if raw["runtime"] != runtime:
            raise ResultError(
                "allocation result runtime differs from the timing runtime"
            )
        identifier = raw["result"]["id"]
        if identifier in allocation_by_id:
            raise ResultError(
                f"duplicate allocation result for workload {identifier}"
            )
        if (
            not memory_evidence
            or mode != "standalone"
            or identifier not in memory_allocated_budgets
        ):
            raise ResultError(
                f"unexpected allocation result for workload {identifier}"
            )
        allocation_by_id[identifier] = _sample_allocation_result(raw)
    for definition in selected:
        process_runs = gathered[definition["id"]]
        timings = [
            value
            for run in process_runs
            for value in run["samplesMicros"]
        ]
        setup_deltas = [
            value
            for run in process_runs
            for value in run["memorySetupDeltaKb"]
        ]
        timed_transient_deltas = [
            value
            for run in process_runs
            for value in run["memoryTimedTransientDeltaKb"]
        ]
        timed_retained_deltas = [
            value
            for run in process_runs
            for value in run["memoryTimedRetainedDeltaKb"]
        ]
        after_deltas = [
            value
            for run in process_runs
            for value in run["memoryAfterDeltaKb"]
        ]
        retained_deltas = [
            value
            for run in process_runs
            for value in run["memoryRetainedDeltaKb"]
        ]
        budget = clock_budgets.get(definition["id"])
        memory_allocated_budget = memory_allocated_budgets.get(definition["id"])
        memory_retained_budget = memory_retained_budgets.get(definition["id"])
        allocation_probe = allocation_by_id.get(definition["id"])
        if (
            memory_evidence
            and mode == "standalone"
            and memory_allocated_budget is not None
            and allocation_probe is None
        ):
            raise ResultError(
                "missing allocation result for budgeted workload "
                f"{definition['id']}"
            )
        status, reason, checksum = _derived_workload_status(
            process_runs,
            budget,
            allocation_probe,
            memory_allocated_budget,
            memory_retained_budget,
        )
        if status == "failed":
            overall = "failed"
        elif status == "invalid" and overall != "failed":
            overall = "invalid"
        workloads.append({
            "id": definition["id"],
            "version": definition["version"],
            "category": definition["category"],
            "operations": definition["operations"],
            "checksum": checksum,
            "status": status,
            "reason": reason,
            "budgetMicros": budget,
            "budgetMemoryAllocatedKb": memory_allocated_budget,
            "budgetMemoryRetainedKb": memory_retained_budget,
            "allocationProbe": allocation_probe,
            "processRuns": process_runs,
            "samplesMicros": timings,
            "statisticsMicros": (
                harness_statistics.summarize(timings) if timings else None
            ),
            "memorySetupDeltaKb": setup_deltas,
            "memorySetupStatisticsKb": (
                harness_statistics.summarize(setup_deltas)
                if setup_deltas
                else None
            ),
            "memoryTimedTransientDeltaKb": timed_transient_deltas,
            "memoryTimedTransientStatisticsKb": (
                harness_statistics.summarize(timed_transient_deltas)
                if timed_transient_deltas
                else None
            ),
            "memoryTimedRetainedDeltaKb": timed_retained_deltas,
            "memoryTimedRetainedStatisticsKb": (
                harness_statistics.summarize(timed_retained_deltas)
                if timed_retained_deltas
                else None
            ),
            "memoryAfterDeltaKb": after_deltas,
            "memoryAfterStatisticsKb": (
                harness_statistics.summarize(after_deltas)
                if after_deltas
                else None
            ),
            "memoryRetainedDeltaKb": retained_deltas,
            "memoryRetainedStatisticsKb": (
                harness_statistics.summarize(retained_deltas)
                if retained_deltas
                else None
            ),
        })
    return {
        "schemaVersion": 7,
        "kind": "mom.performance.summary",
        "status": overall,
        "profile": profile,
        "mode": mode,
        "clock": clock,
        "rawRunCount": len(raw_results),
        "allocationProbeCount": len(allocation_by_id),
        "runtime": runtime,
        "comparability": comparability,
        "workloads": workloads,
    }


def _validated_numeric_array(
    value: object,
    label: str,
    *,
    minimum: float | None = None,
) -> list[float]:
    if not isinstance(value, list):
        raise ResultError(f"{label} must be an array")
    return [_finite(item, label, minimum=minimum) for item in value]


def _validate_comparability(value: object) -> dict[str, Any]:
    fields = {
        "cpuModel",
        "cpuGovernors",
        "cpuAffinity",
        "kernel",
        "machine",
        "lua",
        "luaExecutableSha256",
        "jitAvailable",
        "jitEnabled",
        "jitVersion",
        "jitArchitecture",
        "selectedWorkloadContractSha256",
        "openmwSha256",
        "openmwBuildId",
        "openmwSourceRef",
        "openmwBuildType",
        "gameData",
        "runParameters",
        "nativeCampaign",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise ResultError("performance summary comparability has an unsupported shape")
    for field in ("cpuModel", "kernel", "machine"):
        if not isinstance(value[field], str) or not value[field]:
            raise ResultError(f"comparability.{field} must be a nonempty string")
    governors = value["cpuGovernors"]
    if (
        not isinstance(governors, list)
        or not governors
        or not all(isinstance(item, str) and item for item in governors)
        or governors != sorted(set(governors))
    ):
        raise ResultError(
            "comparability.cpuGovernors must be a sorted unique nonempty array"
        )
    for field in (
        "cpuAffinity",
        "lua",
        "jitVersion",
        "jitArchitecture",
        "openmwBuildId",
        "openmwSourceRef",
        "openmwBuildType",
        "nativeCampaign",
    ):
        if value[field] is not None and (
            not isinstance(value[field], str) or not value[field]
        ):
            raise ResultError(
                f"comparability.{field} must be a nonempty string or null"
            )
    for field in ("jitAvailable", "jitEnabled"):
        if value[field] is not None and not isinstance(value[field], bool):
            raise ResultError(
                f"comparability.{field} must be boolean or null"
            )
    for field in (
        "luaExecutableSha256",
        "selectedWorkloadContractSha256",
        "openmwSha256",
    ):
        if value[field] is not None:
            _sha256(value[field], f"comparability.{field}")
    if value["selectedWorkloadContractSha256"] is None:
        raise ResultError(
            "comparability.selectedWorkloadContractSha256 is required"
        )
    game_data = value["gameData"]
    if game_data is not None:
        if not isinstance(game_data, list) or not game_data:
            raise ResultError("comparability.gameData must be a nonempty array or null")
        for index, identity in enumerate(game_data):
            label = f"comparability.gameData[{index}]"
            if (
                not isinstance(identity, dict)
                or set(identity) != {"name", "size", "sha256"}
                or not isinstance(identity["name"], str)
                or not identity["name"]
                or isinstance(identity["size"], bool)
                or not isinstance(identity["size"], int)
                or identity["size"] < 0
                or not isinstance(identity["sha256"], str)
                or len(identity["sha256"]) != 64
                or any(
                    character not in "0123456789abcdef"
                    for character in identity["sha256"]
                )
            ):
                raise ResultError(f"{label} has an unsupported shape")
    parameters = value["runParameters"]
    parameter_fields = {
        "processes",
        "samplesPerProcess",
        "warmupsPerProcess",
        "memoryEvidence",
    }
    if (
        not isinstance(parameters, dict)
        or frozenset(parameters)
        not in {
            frozenset(parameter_fields),
            frozenset(parameter_fields | {"requiresSingleWorkload"}),
        }
    ):
        raise ResultError("comparability.runParameters has an unsupported shape")
    _positive_int(parameters["processes"], "runParameters.processes")
    _positive_int(
        parameters["samplesPerProcess"], "runParameters.samplesPerProcess"
    )
    _positive_int(
        parameters["warmupsPerProcess"],
        "runParameters.warmupsPerProcess",
        allow_zero=True,
    )
    for field in ("memoryEvidence", "requiresSingleWorkload"):
        if field in parameters and not isinstance(parameters[field], bool):
            raise ResultError(f"runParameters.{field} must be boolean")
    return parameters


def _validated_allocation_probe(
    value: object,
    label: str,
) -> dict[str, Any] | None:
    if value is None:
        return None
    fields = {
        "status",
        "checksum",
        "error",
        "gcBeforeKb",
        "gcStoppedAfterKb",
        "gcRetainedKb",
        "memoryAllocatedDeltaKb",
        "memoryRetainedDeltaKb",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise ResultError(f"{label} has an unsupported shape")
    status = value["status"]
    if status == "failed":
        if (
            value["checksum"] is not None
            or not isinstance(value["error"], str)
            or not value["error"]
            or any(
                value[field] is not None
                for field in (
                    "gcBeforeKb",
                    "gcStoppedAfterKb",
                    "gcRetainedKb",
                    "memoryAllocatedDeltaKb",
                    "memoryRetainedDeltaKb",
                )
            )
        ):
            raise ResultError(
                f"{label} failed evidence must contain only its error"
            )
        return value
    if status != "passed":
        raise ResultError(f"{label}.status is unsupported")
    if (
        not isinstance(value["checksum"], str)
        or not value["checksum"]
        or value["error"] is not None
    ):
        raise ResultError(f"{label} passed evidence identity is invalid")
    before = _finite(value["gcBeforeKb"], f"{label}.gcBeforeKb", minimum=0)
    stopped_after = _finite(
        value["gcStoppedAfterKb"],
        f"{label}.gcStoppedAfterKb",
        minimum=0,
    )
    retained = _finite(
        value["gcRetainedKb"], f"{label}.gcRetainedKb", minimum=0
    )
    allocated_delta = _finite(
        value["memoryAllocatedDeltaKb"],
        f"{label}.memoryAllocatedDeltaKb",
        minimum=0,
    )
    retained_delta = _finite(
        value["memoryRetainedDeltaKb"],
        f"{label}.memoryRetainedDeltaKb",
    )
    if (
        stopped_after < before
        or allocated_delta != stopped_after - before
        or retained_delta != retained - before
    ):
        raise ResultError(f"{label} deltas disagree with its snapshots")
    return value


def validate_summary(
    summary: object, catalog: dict[str, Any], budgets: dict[str, Any]
) -> dict[str, Any]:
    required = {
        "schemaVersion", "kind", "status", "profile", "mode", "clock",
        "rawRunCount", "allocationProbeCount", "runtime", "comparability",
        "workloads",
    }
    if not isinstance(summary, dict) or set(summary) != required:
        raise ResultError("performance summary has an unsupported shape")
    if summary.get("schemaVersion") != 7 or summary.get("kind") != "mom.performance.summary":
        raise ResultError("performance summary schema/kind is unsupported")
    if not isinstance(summary["profile"], str) or not summary["profile"]:
        raise ResultError("performance summary profile is required")
    mode = summary["mode"]
    clock = summary["clock"]
    expected_clock = {
        "standalone": "process_cpu",
        "embedded": "monotonic_wall",
        "integration": "monotonic_wall",
    }.get(mode)
    if expected_clock is None or clock != expected_clock:
        raise ResultError("performance summary mode and clock do not match")
    _positive_int(summary["rawRunCount"], "summary rawRunCount")
    _positive_int(
        summary["allocationProbeCount"],
        "summary allocationProbeCount",
        allow_zero=True,
    )
    if not isinstance(summary["runtime"], dict):
        raise ResultError("performance summary runtime/comparability context is required")
    parameters = _validate_comparability(summary["comparability"])
    if (
        summary["comparability"]["luaExecutableSha256"]
        != summary["runtime"].get("executableSha256")
    ):
        raise ResultError(
            "performance summary Lua executable identity differs from runtime"
        )
    if mode == "standalone":
        _sha256(
            summary["runtime"].get("executableSha256"),
            "standalone summary Lua executable identity",
        )
    rows = summary["workloads"]
    if not isinstance(rows, list) or not rows:
        raise ResultError("performance summary workloads must be a nonempty array")

    by_id = catalog_by_id(catalog)
    expected_budget_map = budgets["absoluteMicros"][clock]
    runtime_identity = memory_runtime_identity(summary["runtime"])
    runtime_memory_budgets = budgets["absoluteMemoryKb"][mode].get(
        runtime_identity,
        {"allocated": {}, "retained": {}},
    )
    expected_memory_allocated_map = runtime_memory_budgets["allocated"]
    expected_memory_retained_map = runtime_memory_budgets["retained"]
    seen: set[str] = set()
    overall = "passed"
    row_fields = {
        "id", "version", "category", "operations", "checksum", "status", "reason",
        "budgetMicros", "budgetMemoryAllocatedKb", "budgetMemoryRetainedKb",
        "allocationProbe",
        "processRuns", "samplesMicros", "statisticsMicros",
        "memorySetupDeltaKb", "memorySetupStatisticsKb",
        "memoryTimedTransientDeltaKb", "memoryTimedTransientStatisticsKb",
        "memoryTimedRetainedDeltaKb", "memoryTimedRetainedStatisticsKb",
        "memoryAfterDeltaKb", "memoryAfterStatisticsKb",
        "memoryRetainedDeltaKb", "memoryRetainedStatisticsKb",
    }
    process_fields = {
        "status",
        "checksum",
        "samplesMicros",
        "memorySetupDeltaKb",
        "memoryTimedTransientDeltaKb",
        "memoryTimedRetainedDeltaKb",
        "memoryAfterDeltaKb",
        "memoryRetainedDeltaKb",
    }
    for index, row in enumerate(rows):
        label = f"summary.workloads[{index}]"
        if not isinstance(row, dict) or set(row) != row_fields:
            raise ResultError(f"{label} has an unsupported shape")
        identifier = row["id"]
        definition = by_id.get(identifier) if isinstance(identifier, str) else None
        if definition is None or identifier in seen or mode not in definition["modes"]:
            raise ResultError(f"{label}.id is unknown, duplicate, or invalid for {mode}")
        seen.add(identifier)
        for field in ("version", "category", "operations"):
            if row[field] != definition[field]:
                raise ResultError(f"{label}.{field} differs from the workload catalog")
        budget = expected_budget_map.get(identifier)
        if row["budgetMicros"] != budget:
            raise ResultError(f"{label}.budgetMicros differs from the budget contract")
        memory_allocated_budget = expected_memory_allocated_map.get(identifier)
        memory_retained_budget = expected_memory_retained_map.get(identifier)
        if row["budgetMemoryAllocatedKb"] != memory_allocated_budget:
            raise ResultError(
                f"{label}.budgetMemoryAllocatedKb differs from the budget contract"
            )
        if row["budgetMemoryRetainedKb"] != memory_retained_budget:
            raise ResultError(
                f"{label}.budgetMemoryRetainedKb differs from the budget contract"
            )
        allocation_probe = _validated_allocation_probe(
            row["allocationProbe"],
            f"{label}.allocationProbe",
        )
        allocation_required = (
            parameters["memoryEvidence"]
            and mode == "standalone"
            and memory_allocated_budget is not None
        )
        if allocation_required != (allocation_probe is not None):
            raise ResultError(
                f"{label}.allocationProbe disagrees with the allocation budget"
            )

        process_runs = row["processRuns"]
        if (
            not isinstance(process_runs, list)
            or len(process_runs) != parameters["processes"]
        ):
            raise ResultError(
                f"{label}.processRuns differs from the configured process count"
            )
        checked_runs: list[dict[str, Any]] = []
        for run_index, run in enumerate(process_runs):
            run_label = f"{label}.processRuns[{run_index}]"
            if not isinstance(run, dict) or set(run) != process_fields:
                raise ResultError(f"{run_label} has an unsupported shape")
            if run["status"] not in {"passed", "failed", "invalid"}:
                raise ResultError(f"{run_label}.status is unsupported")
            checksum = run["checksum"]
            if checksum is not None and (
                not isinstance(checksum, str) or not checksum
            ):
                raise ResultError(
                    f"{run_label}.checksum must be a nonempty string or null"
                )
            if run["status"] != "failed" and checksum is None:
                raise ResultError(f"{run_label} omitted its checksum")
            timings = _validated_numeric_array(
                run["samplesMicros"],
                f"{run_label}.samplesMicros",
                minimum=0,
            )
            after = _validated_numeric_array(
                run["memoryAfterDeltaKb"],
                f"{run_label}.memoryAfterDeltaKb",
            )
            retained = _validated_numeric_array(
                run["memoryRetainedDeltaKb"],
                f"{run_label}.memoryRetainedDeltaKb",
            )
            setup = _validated_numeric_array(
                run["memorySetupDeltaKb"],
                f"{run_label}.memorySetupDeltaKb",
            )
            timed_transient = _validated_numeric_array(
                run["memoryTimedTransientDeltaKb"],
                f"{run_label}.memoryTimedTransientDeltaKb",
            )
            timed_retained = _validated_numeric_array(
                run["memoryTimedRetainedDeltaKb"],
                f"{run_label}.memoryTimedRetainedDeltaKb",
            )
            if parameters["memoryEvidence"]:
                if any(
                    len(timings) != len(values)
                    for values in (
                        setup,
                        timed_transient,
                        timed_retained,
                        after,
                        retained,
                    )
                ):
                    raise ResultError(
                        f"{run_label} timing and memory sample counts differ"
                    )
            elif setup or timed_transient or timed_retained or after or retained:
                raise ResultError(
                    f"{run_label} contains memory samples without memory evidence"
                )
            expected_sample_count = parameters["samplesPerProcess"]
            if (
                run["status"] == "failed"
                and len(timings) > expected_sample_count
            ) or (
                run["status"] != "failed"
                and len(timings) != expected_sample_count
            ):
                raise ResultError(
                    f"{run_label} differs from the configured sample count"
                )
            checked_runs.append({
                **run,
                "samplesMicros": timings,
                "memorySetupDeltaKb": setup,
                "memoryTimedTransientDeltaKb": timed_transient,
                "memoryTimedRetainedDeltaKb": timed_retained,
                "memoryAfterDeltaKb": after,
                "memoryRetainedDeltaKb": retained,
            })

        timings = [
            value for run in checked_runs for value in run["samplesMicros"]
        ]
        setup_deltas = [
            value for run in checked_runs for value in run["memorySetupDeltaKb"]
        ]
        timed_transient_deltas = [
            value
            for run in checked_runs
            for value in run["memoryTimedTransientDeltaKb"]
        ]
        timed_retained_deltas = [
            value
            for run in checked_runs
            for value in run["memoryTimedRetainedDeltaKb"]
        ]
        after_deltas = [
            value for run in checked_runs for value in run["memoryAfterDeltaKb"]
        ]
        retained_deltas = [
            value
            for run in checked_runs
            for value in run["memoryRetainedDeltaKb"]
        ]
        for field, expected, minimum in (
            ("samplesMicros", timings, 0),
            ("memorySetupDeltaKb", setup_deltas, None),
            ("memoryTimedTransientDeltaKb", timed_transient_deltas, None),
            ("memoryTimedRetainedDeltaKb", timed_retained_deltas, None),
            ("memoryAfterDeltaKb", after_deltas, None),
            ("memoryRetainedDeltaKb", retained_deltas, None),
        ):
            actual = _validated_numeric_array(
                row[field], f"{label}.{field}", minimum=minimum
            )
            if actual != expected:
                raise ResultError(
                    f"{label}.{field} does not preserve its process clusters"
                )
        for field, values in (
            ("statisticsMicros", timings),
            ("memorySetupStatisticsKb", setup_deltas),
            ("memoryTimedTransientStatisticsKb", timed_transient_deltas),
            ("memoryTimedRetainedStatisticsKb", timed_retained_deltas),
            ("memoryAfterStatisticsKb", after_deltas),
            ("memoryRetainedStatisticsKb", retained_deltas),
        ):
            expected_statistics = (
                harness_statistics.summarize(values) if values else None
            )
            if row[field] != expected_statistics:
                raise ResultError(
                    f"{label}.{field} does not match its samples"
                )

        expected_status, expected_reason, expected_checksum = (
            _derived_workload_status(
                checked_runs,
                budget,
                allocation_probe,
                memory_allocated_budget,
                memory_retained_budget,
            )
        )
        if (
            row["status"] != expected_status
            or row["reason"] != expected_reason
            or row["checksum"] != expected_checksum
        ):
            raise ResultError(
                f"{label} status/reason/checksum disagrees with process evidence"
            )
        if expected_status == "failed":
            overall = "failed"
        elif expected_status == "invalid" and overall != "failed":
            overall = "invalid"
    if parameters["memoryEvidence"]:
        expected_raw_runs = parameters["processes"] * len(seen)
    else:
        fresh_process_count = sum(
            1 for identifier in seen if by_id[identifier]["requiresFreshProcess"]
        )
        batched_process_count = int(fresh_process_count < len(seen))
        expected_raw_runs = parameters["processes"] * (
            fresh_process_count + batched_process_count
        )
    if summary["rawRunCount"] != expected_raw_runs:
        raise ResultError(
            "performance summary rawRunCount disagrees with its run parameters"
        )
    expected_allocation_probes = sum(
        1
        for identifier in seen
        if (
            parameters["memoryEvidence"]
            and mode == "standalone"
            and identifier in expected_memory_allocated_map
        )
    )
    if summary["allocationProbeCount"] != expected_allocation_probes:
        raise ResultError(
            "performance summary allocationProbeCount disagrees with its "
            "allocation evidence"
        )
    if summary["status"] != overall:
        raise ResultError("performance summary status disagrees with its workloads")
    return summary


def validate_comparison(comparison: object) -> dict[str, Any]:
    if not isinstance(comparison, dict):
        raise ResultError("performance comparison must be an object")
    common = {"schemaVersion", "kind", "status", "mismatches", "workloads"}
    if comparison.get("schemaVersion") != 3 or comparison.get("kind") != "mom.performance.comparison":
        raise ResultError("performance comparison schema/kind is unsupported")
    if comparison.get("status") == "not-comparable":
        if set(comparison) != common:
            raise ResultError("not-comparable result has an unsupported shape")
        if not isinstance(comparison["mismatches"], list) or not comparison["mismatches"]:
            raise ResultError("not-comparable result requires mismatches")
        if any(not isinstance(item, str) or not item for item in comparison["mismatches"]):
            raise ResultError("comparison mismatches must be nonempty strings")
        if comparison["workloads"] != []:
            raise ResultError("not-comparable result cannot contain workload comparisons")
        return comparison

    if set(comparison) != common | {"confidence"}:
        raise ResultError("performance comparison has an unsupported shape")
    if comparison["status"] not in {"passed", "failed", "regression", "inconclusive"}:
        raise ResultError("performance comparison status is unsupported")
    confidence = _finite(comparison["confidence"], "comparison confidence")
    if not 0 < confidence < 1 or comparison["mismatches"] != []:
        raise ResultError("comparable result has invalid confidence or mismatches")
    rows = comparison["workloads"]
    if not isinstance(rows, list) or not rows:
        raise ResultError("comparable result requires workload comparisons")
    fields = {
        "id", "status", "reason", "baselineMedianMicros", "candidateMedianMicros",
        "ratio", "maximumRegressionRatio", "memory",
    }
    memory_fields = {
        "status",
        "reason",
        "baselineTimedTransientMedianKb",
        "candidateTimedTransientMedianKb",
        "timedTransientDifferenceKb",
        "baselineTimedRetainedMedianKb",
        "candidateTimedRetainedMedianKb",
        "timedRetainedDifferenceKb",
    }
    seen: set[str] = set()
    row_statuses: set[str] = set()
    for index, row in enumerate(rows):
        label = f"comparison.workloads[{index}]"
        if not isinstance(row, dict) or set(row) != fields:
            raise ResultError(f"{label} has an unsupported shape")
        identifier = row["id"]
        if not isinstance(identifier, str) or not identifier or identifier in seen:
            raise ResultError(f"{label}.id must be nonempty and unique")
        seen.add(identifier)
        if row["status"] not in {
            "passed", "failed", "regression", "inconclusive", "not-comparable"
        }:
            raise ResultError(f"{label}.status is unsupported")
        row_statuses.add(row["status"])
        reason = row["reason"]
        if row["status"] == "passed" and reason is not None:
            raise ResultError(f"{label}.reason must be null when passed")
        if row["status"] != "passed" and (not isinstance(reason, str) or not reason):
            raise ResultError(f"{label}.reason is required when not passed")
        for field in ("baselineMedianMicros", "candidateMedianMicros"):
            if row[field] is not None:
                _finite(row[field], f"{label}.{field}", minimum=0)
        _finite(row["maximumRegressionRatio"], f"{label}.maximumRegressionRatio", minimum=1)
        ratio = row["ratio"]
        if ratio is not None:
            if not isinstance(ratio, dict) or set(ratio) != {"estimate", "lower", "upper"}:
                raise ResultError(f"{label}.ratio has an unsupported shape")
            for field in ("estimate", "lower", "upper"):
                _finite(ratio[field], f"{label}.ratio.{field}", minimum=0)
        memory = row["memory"]
        if not isinstance(memory, dict) or set(memory) != memory_fields:
            raise ResultError(f"{label}.memory has an unsupported shape")
        if memory["status"] not in {"measured", "inconclusive"}:
            raise ResultError(f"{label}.memory.status is unsupported")
        if memory["status"] == "measured":
            if memory["reason"] is not None:
                raise ResultError(
                    f"{label}.memory.reason must be null when measured"
                )
        elif not isinstance(memory["reason"], str) or not memory["reason"]:
            raise ResultError(
                f"{label}.memory.reason is required when inconclusive"
            )
        for field in (
            "baselineTimedTransientMedianKb",
            "candidateTimedTransientMedianKb",
            "baselineTimedRetainedMedianKb",
            "candidateTimedRetainedMedianKb",
        ):
            if memory[field] is not None:
                _finite(memory[field], f"{label}.memory.{field}")
        for field in (
            "timedTransientDifferenceKb",
            "timedRetainedDifferenceKb",
        ):
            interval = memory[field]
            if interval is not None:
                if (
                    not isinstance(interval, dict)
                    or set(interval) != {"estimate", "lower", "upper"}
                ):
                    raise ResultError(
                        f"{label}.memory.{field} has an unsupported shape"
                    )
                for interval_field in ("estimate", "lower", "upper"):
                    _finite(
                        interval[interval_field],
                        f"{label}.memory.{field}.{interval_field}",
                    )
        if memory["status"] == "measured" and (
            memory["timedTransientDifferenceKb"] is None
            or memory["timedRetainedDifferenceKb"] is None
        ):
            raise ResultError(
                f"{label}.memory measured without confidence intervals"
            )
    expected_status = (
        "failed" if "failed" in row_statuses
        else "regression" if "regression" in row_statuses
        else "inconclusive" if row_statuses & {"inconclusive", "not-comparable"}
        else "passed"
    )
    if comparison["status"] != expected_status:
        raise ResultError("performance comparison status disagrees with its workloads")
    return comparison


def _comparability_mismatches(
    baseline: dict[str, Any], candidate: dict[str, Any]
) -> list[str]:
    mismatches: list[str] = []
    for field in ("profile", "mode", "clock"):
        if baseline.get(field) != candidate.get(field):
            mismatches.append(field)
    base_context = baseline.get("comparability")
    new_context = candidate.get("comparability")
    if not isinstance(base_context, dict) or not isinstance(new_context, dict):
        return mismatches + ["comparability"]
    for key in sorted(set(base_context) | set(new_context)):
        if base_context.get(key) != new_context.get(key):
            mismatches.append(f"comparability.{key}")
    return mismatches


def compare_summaries(
    baseline: dict[str, Any], candidate: dict[str, Any], budgets: dict[str, Any],
    catalog: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if catalog is not None:
        validate_summary(baseline, catalog, budgets)
        validate_summary(candidate, catalog, budgets)
    else:
        for label, summary in (("baseline", baseline), ("candidate", candidate)):
            if not isinstance(summary, dict) or summary.get("kind") != "mom.performance.summary":
                raise ResultError(f"{label} is not a MOM performance summary")
    mismatches = _comparability_mismatches(baseline, candidate)
    base_rows = {row["id"]: row for row in baseline.get("workloads", [])}
    new_rows = {row["id"]: row for row in candidate.get("workloads", [])}
    if set(base_rows) != set(new_rows):
        mismatches.append("workload_ids")
    for identifier in sorted(set(base_rows) & set(new_rows)):
        left, right = base_rows[identifier], new_rows[identifier]
        for field in ("version", "operations", "checksum"):
            if left.get(field) != right.get(field):
                mismatches.append(f"workloads.{identifier}.{field}")
    if mismatches:
        return validate_comparison({
            "schemaVersion": 3,
            "kind": "mom.performance.comparison",
            "status": "not-comparable",
            "mismatches": mismatches,
            "workloads": [],
        })

    policy = budgets["comparison"]
    rows: list[dict[str, Any]] = []
    for identifier in [row["id"] for row in baseline["workloads"]]:
        left, right = base_rows[identifier], new_rows[identifier]
        status = "passed"
        reason = None
        interval = None
        base_samples = left.get("samplesMicros", [])
        new_samples = right.get("samplesMicros", [])
        base_runs = left.get("processRuns", [])
        new_runs = right.get("processRuns", [])
        base_clusters = [run["samplesMicros"] for run in base_runs]
        new_clusters = [run["samplesMicros"] for run in new_runs]
        enough_samples = (
            min(len(base_samples), len(new_samples))
            >= policy["minimumSamples"]
        )
        enough_clusters = min(len(base_clusters), len(new_clusters)) >= 2
        if left.get("status") != "passed":
            status, reason = "not-comparable", "baseline_not_passed"
        elif right.get("status") != "passed":
            status, reason = "failed", "candidate_not_passed"
        elif not enough_samples:
            status, reason = "inconclusive", "insufficient_samples"
        elif not enough_clusters:
            status, reason = "inconclusive", "insufficient_process_clusters"
        else:
            interval = harness_statistics.hierarchical_bootstrap_median_ratio(
                base_clusters,
                new_clusters,
                confidence=policy["confidence"],
                resamples=policy["bootstrapResamples"],
                seed=policy["seed"] + sum(identifier.encode("utf-8")),
            )
            limit = policy["maximumRegressionRatio"]
            if interval["lower"] > limit:
                status, reason = "regression", "confidence_interval_above_limit"
            elif interval["upper"] > limit:
                status, reason = "inconclusive", "confidence_interval_crosses_limit"

        memory_reason = None
        if not baseline["comparability"]["runParameters"]["memoryEvidence"]:
            memory_reason = "memory_not_captured"
        elif left.get("status") != "passed" or right.get("status") != "passed":
            memory_reason = "workload_not_comparable"
        elif not enough_samples:
            memory_reason = "insufficient_samples"
        elif not enough_clusters:
            memory_reason = "insufficient_process_clusters"
        base_timed_transient = [
            run["memoryTimedTransientDeltaKb"] for run in base_runs
        ]
        new_timed_transient = [
            run["memoryTimedTransientDeltaKb"] for run in new_runs
        ]
        base_timed_retained = [
            run["memoryTimedRetainedDeltaKb"] for run in base_runs
        ]
        new_timed_retained = [
            run["memoryTimedRetainedDeltaKb"] for run in new_runs
        ]
        timed_transient_difference = None
        timed_retained_difference = None
        if memory_reason is None:
            memory_seed = (
                policy["seed"]
                + sum(identifier.encode("utf-8"))
                + 1_000_003
            )
            timed_transient_difference = (
                harness_statistics.hierarchical_bootstrap_median_difference(
                    base_timed_transient,
                    new_timed_transient,
                    confidence=policy["confidence"],
                    resamples=policy["bootstrapResamples"],
                    seed=memory_seed,
                )
            )
            timed_retained_difference = (
                harness_statistics.hierarchical_bootstrap_median_difference(
                    base_timed_retained,
                    new_timed_retained,
                    confidence=policy["confidence"],
                    resamples=policy["bootstrapResamples"],
                    seed=memory_seed + 1_000_003,
                )
            )
        rows.append({
            "id": identifier,
            "status": status,
            "reason": reason,
            "baselineMedianMicros": (
                left.get("statisticsMicros") or {}
            ).get("median"),
            "candidateMedianMicros": (
                right.get("statisticsMicros") or {}
            ).get("median"),
            "ratio": interval,
            "maximumRegressionRatio": policy["maximumRegressionRatio"],
            "memory": {
                "status": "measured" if memory_reason is None else "inconclusive",
                "reason": memory_reason,
                "baselineTimedTransientMedianKb": (
                    left.get("memoryTimedTransientStatisticsKb") or {}
                ).get("median"),
                "candidateTimedTransientMedianKb": (
                    right.get("memoryTimedTransientStatisticsKb") or {}
                ).get("median"),
                "timedTransientDifferenceKb": timed_transient_difference,
                "baselineTimedRetainedMedianKb": (
                    left.get("memoryTimedRetainedStatisticsKb") or {}
                ).get("median"),
                "candidateTimedRetainedMedianKb": (
                    right.get("memoryTimedRetainedStatisticsKb") or {}
                ).get("median"),
                "timedRetainedDifferenceKb": timed_retained_difference,
            },
        })
    statuses = {row["status"] for row in rows}
    overall = (
        "failed" if "failed" in statuses
        else "regression" if "regression" in statuses
        else "inconclusive" if statuses & {"inconclusive", "not-comparable"}
        else "passed"
    )
    return validate_comparison({
        "schemaVersion": 3,
        "kind": "mom.performance.comparison",
        "status": overall,
        "mismatches": [],
        "confidence": policy["confidence"],
        "workloads": rows,
    })
