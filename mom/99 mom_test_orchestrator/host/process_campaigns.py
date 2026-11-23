from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
import os
from pathlib import Path
import re
import shlex
import shutil
import sys
from typing import Sequence

import artifacts
import correctness
import launch
import process


HOST_ROOT = Path(__file__).resolve().parent
HARNESS_ROOT = HOST_ROOT.parent
REPOSITORY_ROOT = HARNESS_ROOT.parent.parent
HARNESS = HARNESS_ROOT / "run_harness.sh"
OVERLAY_ROOT = HARNESS_ROOT / "process_campaign_overlays"
WORKDIR_MARKER = ".mom_process_campaigns"
HANDOFF_KEY_PATTERN = re.compile(r"^[A-Za-z0-9_.-]+$")
HANDOFF_VALUE_PATTERN = re.compile(
    r"\[MOMCampaign\]\[VALUE\] "
    r"key=([A-Za-z0-9_.-]+) hex=([0-9A-Fa-f]*)"
)
PHASE_REQUIRED_ARTIFACTS = {
    "command.txt",
    "config/openmw.cfg",
    "config/openmw.log",
    "generated-data/scripts/mom_test_orchestrator/run_options.lua",
    "handoff-data/scripts/mom_test_orchestrator/campaign_handoff.lua",
    "host.log",
    "result.json",
}


class CampaignError(RuntimeError):
    pass


@dataclass(frozen=True)
class Phase:
    id: str
    scenario: str
    mode: str
    values: tuple[tuple[str, str], ...] = ()
    overlay: str | None = None


@dataclass(frozen=True)
class Campaign:
    id: str
    phases: tuple[Phase, ...]


@dataclass(frozen=True)
class PhaseOutcome:
    status: str
    save: Path | None
    result: Path


@dataclass(frozen=True)
class RunSettings:
    workdir: Path
    result_file: Path
    phase_timeout: int
    openmw_binary: Path
    global_config: Path | None
    base_config: Path | None
    store: artifacts.ContentStore


def _container_transfer_phases() -> tuple[Phase, ...]:
    return (
        Phase(
            "apply_pending",
            "campaign_container_apply_boundary",
            "save",
            (("container.phase", "apply_pending"),),
        ),
        Phase(
            "apply_committed",
            "campaign_container_apply_boundary",
            "save",
            (("container.phase", "apply_committed"),),
        ),
        Phase(
            "revert_pending",
            "campaign_container_revert_boundary",
            "save",
            (("container.phase", "revert_pending"),),
        ),
        Phase("verify", "campaign_container_verify", "verify"),
    )


CAMPAIGNS = (
    Campaign("content_phase_restart", (
        Phase("setup", "campaign_content_phase_setup", "save"),
        Phase("resave", "campaign_content_phase_resave", "save"),
        Phase("verify", "campaign_content_phase_verify", "verify"),
        Phase("edited", "campaign_content_phase_changed", "verify", overlay="content_phase_updated"),
    )),
    Campaign("filtered_one_restart", (
        Phase("setup", "campaign_filtered_one_setup", "save"),
        Phase("verify", "campaign_filtered_one_verify", "verify"),
    )),
    Campaign("nested_attach_restart", (
        Phase("setup", "campaign_nested_attach_setup", "save"),
        Phase("verify", "campaign_nested_attach_verify", "verify"),
    )),
    Campaign("nested_place_restart", (
        Phase("setup", "campaign_nested_place_setup", "save"),
        Phase("verify", "campaign_nested_place_verify", "verify"),
    )),
    Campaign("reversible_restart", (
        Phase("setup", "campaign_reversible_setup", "save"),
        Phase("verify", "campaign_reversible_verify", "verify"),
    )),
    Campaign("deferred_cleanup_restart", (
        Phase("setup", "campaign_deferred_setup", "save"),
        Phase("verify", "campaign_deferred_verify", "verify"),
    )),
    Campaign("logical_identity_restart", (
        Phase("setup", "campaign_logical_move_setup", "save"),
        Phase("verify", "campaign_logical_move_verify", "verify"),
    )),
    Campaign("starting_door_restart", (
        Phase("setup", "campaign_starting_door_setup", "save"),
        Phase("verify", "campaign_starting_door_verify", "verify"),
    )),
    Campaign("retired_position_child_restart", (
        Phase("setup", "campaign_retired_move_setup", "save"),
        Phase("verify", "campaign_retired_move_verify", "verify"),
    )),
    Campaign("actor_local_restart", (
        Phase("setup", "campaign_actor_local_setup", "save"),
        Phase("verify", "campaign_actor_local_verify", "verify"),
    )),
    Campaign("creature_mesh_restart", (
        Phase("setup", "campaign_creature_mesh_setup", "save"),
        Phase("verify", "campaign_creature_mesh_verify", "verify"),
    )),
    Campaign("inventory_ensure_restart", (
        Phase("setup", "campaign_inventory_ensure_setup", "save"),
        Phase("verify", "campaign_inventory_ensure_verify", "verify"),
    )),
    Campaign("container_transfer_restart", _container_transfer_phases()),
    Campaign("respawning_container_restart", (
        Phase("setup", "campaign_respawning_container_setup", "save"),
        Phase("verify", "campaign_respawning_container_verify", "verify"),
    )),
    Campaign("vfr_compat_restart", (
        Phase("setup", "campaign_vfr_setup", "save"),
        Phase("verify", "campaign_vfr_verify", "verify"),
    )),
    Campaign("startup_plan_change_restart", (
        Phase("setup", "campaign_plan_change_setup", "save", overlay="plan_v1"),
        Phase("verify", "campaign_plan_change_verify", "verify", overlay="plan_v2"),
    )),
    Campaign("static_evolution_restart", (
        Phase("baseline", "campaign_static_baseline", "verify"),
        Phase("initial", "campaign_static_initial", "save", overlay="static_v1"),
        Phase("extended", "campaign_static_extended", "save", overlay="static_v2"),
        Phase("removed", "campaign_static_removed", "save", overlay="static_v3"),
        Phase(
            "verify",
            "campaign_static_history_verify",
            "verify",
            overlay="static_v3",
        ),
    )),
    Campaign("provider_unavailable_restart", (
        Phase("setup", "campaign_provider_setup", "save"),
        Phase("verify", "campaign_provider_verify", "verify"),
    )),
)
CAMPAIGN_BY_ID = {campaign.id: campaign for campaign in CAMPAIGNS}


def validate_catalog() -> None:
    if len(CAMPAIGN_BY_ID) != len(CAMPAIGNS):
        raise CampaignError("campaign ids must be unique")
    for campaign in CAMPAIGNS:
        phase_ids: set[str] = set()
        for phase in campaign.phases:
            if phase.id in phase_ids:
                raise CampaignError(
                    f"campaign {campaign.id} has duplicate phase {phase.id}"
                )
            phase_ids.add(phase.id)
            if phase.mode not in {"save", "verify"}:
                raise CampaignError(
                    f"campaign {campaign.id} phase {phase.id} has invalid mode"
                )
            if phase.overlay is not None and not HANDOFF_KEY_PATTERN.fullmatch(
                phase.overlay
            ):
                raise CampaignError(
                    f"campaign {campaign.id} phase {phase.id} has invalid overlay"
                )
            for key, _value in phase.values:
                if not HANDOFF_KEY_PATTERN.fullmatch(key):
                    raise CampaignError(
                        f"campaign {campaign.id} phase {phase.id} "
                        f"has invalid handoff key"
                    )


def prepare_workdir(path: Path, repository_root: Path = REPOSITORY_ROOT) -> Path:
    try:
        return launch.prepare_workdir(path, repository_root, marker=WORKDIR_MARKER)
    except launch.LaunchError as exc:
        raise CampaignError(str(exc)) from exc


def write_handoff_module(
    phase_dir: Path,
    handoff: dict[str, str],
    phase: Phase,
) -> Path:
    values = dict(handoff)
    for key, value in phase.values:
        values[key] = value.encode("utf-8").hex()

    data_dir = phase_dir / "handoff-data"
    module = data_dir / "scripts" / "mom_test_orchestrator" / "campaign_handoff.lua"
    lines = ["return {"]
    lines.extend(f'  ["{key}"] = "{value}",' for key, value in values.items())
    lines.append("}")
    artifacts.atomic_write(module, ("\n".join(lines) + "\n").encode("ascii"))
    return data_dir


def capture_handoff_values(process_log: Path, handoff: dict[str, str]) -> None:
    if not process_log.is_file():
        return
    text = process_log.read_text(encoding="utf-8", errors="replace")
    for match in HANDOFF_VALUE_PATTERN.finditer(text):
        handoff[match.group(1)] = match.group(2)


def prepare_overlay(
    name: str,
    phase_dir: Path,
    overlay_root: Path = OVERLAY_ROOT,
) -> Path:
    if not HANDOFF_KEY_PATTERN.fullmatch(name):
        raise CampaignError(f"invalid campaign overlay: {name}")
    source = overlay_root / name
    if not source.is_dir():
        raise CampaignError(f"campaign overlay is unavailable: {source}")
    target = phase_dir / "overlay-data"
    shutil.copytree(source, target)
    return target


def newest_save(root: Path) -> Path | None:
    if not root.is_dir():
        return None
    saves = [path for path in root.rglob("*.omwsave") if path.is_file()]
    return max(saves, key=lambda path: path.stat().st_mtime_ns) if saves else None


def build_phase_command(
    *,
    phase: Phase,
    harness_work: Path,
    harness_result: Path,
    handoff_data: Path,
    overlay_data: Path | None,
    input_save: Path | None,
    openmw_binary: Path | None = None,
    global_config: Path | None = None,
    base_config: Path | None = None,
    build_openmw: bool | None = None,
    harness: Path = HARNESS,
) -> list[str]:
    openmw_arguments = ["--data", str(handoff_data)]
    if overlay_data is not None:
        openmw_arguments.extend(("--data", str(overlay_data)))
    if input_save is not None:
        openmw_arguments.extend(("--load-savegame", str(input_save)))
    return launch.build_harness_command(
        launch.HarnessCommand(
            mode="correctness",
            work_directory=harness_work,
            result_file=harness_result,
            scenarios=(phase.scenario,),
            openmw_binary=openmw_binary,
            global_config=global_config,
            base_config=base_config,
            build_openmw=build_openmw,
            openmw_arguments=tuple(openmw_arguments),
        ),
        harness=harness,
    )


def _read_harness_result(path: Path) -> dict[str, object] | None:
    if not path.is_file():
        return None
    try:
        return correctness.load_result(path)
    except correctness.CorrectnessError:
        return None


def _artifact_reference(entry: dict[str, object]) -> dict[str, object]:
    return {
        "object": entry["object"],
        "sha256": entry["sha256"],
        "size": entry["size"],
    }


def _phase_artifact(
    phase: dict[str, object],
    logical_path: str,
) -> dict[str, object] | None:
    matches = [
        entry
        for entry in phase["artifacts"]
        if entry["path"] == logical_path
    ]
    if not matches:
        return None
    if len(matches) != 1:
        raise CampaignError(
            f"campaign phase artifact path is duplicate: {logical_path}"
        )
    return _artifact_reference(matches[0])


def validate_phase_result(value: object) -> dict[str, object]:
    fields = {
        "schemaVersion",
        "kind",
        "status",
        "campaign",
        "phase",
        "scenario",
        "mode",
        "harnessExit",
        "openmwExit",
        "timedOut",
        "durationSeconds",
        "harnessResultKind",
        "inputSave",
        "artifacts",
        "overlay",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise CampaignError("campaign phase result has an unsupported shape")
    if (
        value["schemaVersion"] != 2
        or value["kind"] != "mom.process-campaign.phase"
    ):
        raise CampaignError("campaign phase result schema/kind is unsupported")
    if value["status"] not in {"passed", "failed"}:
        raise CampaignError("campaign phase result status is unsupported")
    for field in ("campaign", "phase", "scenario"):
        if not isinstance(value[field], str) or not value[field]:
            raise CampaignError(
                f"campaign phase result {field} must be a nonempty string"
            )
    if value["mode"] not in {"save", "verify"}:
        raise CampaignError("campaign phase result mode is unsupported")
    for field in ("harnessExit", "openmwExit"):
        field_value = value[field]
        if field_value is not None and (
            isinstance(field_value, bool) or not isinstance(field_value, int)
        ):
            raise CampaignError(
                f"campaign phase result {field} must be an integer or null"
            )
    if not isinstance(value["timedOut"], bool):
        raise CampaignError("campaign phase result timedOut must be boolean")
    duration = value["durationSeconds"]
    if (
        isinstance(duration, bool)
        or not isinstance(duration, (int, float))
        or not math.isfinite(float(duration))
        or duration < 0
    ):
        raise CampaignError(
            "campaign phase result durationSeconds must be non-negative and finite"
        )
    for field in ("harnessResultKind", "overlay"):
        if not isinstance(value[field], str):
            raise CampaignError(
                f"campaign phase result {field} must be a string"
            )
    if value["inputSave"] is not None:
        try:
            artifacts.validate_object_reference(
                value["inputSave"],
                "campaign phase result inputSave",
            )
        except artifacts.ArtifactError as exc:
            raise CampaignError(str(exc)) from exc
    retained = value["artifacts"]
    if not isinstance(retained, list):
        raise CampaignError("campaign phase result artifacts must be an array")
    retained_paths: set[str] = set()
    for index, entry in enumerate(retained):
        label = f"campaign phase result artifacts[{index}]"
        if not isinstance(entry, dict) or set(entry) != {
            "path",
            "object",
            "sha256",
            "size",
        }:
            raise CampaignError(f"{label} has an unsupported shape")
        logical_path = entry["path"]
        if (
            not isinstance(logical_path, str)
            or not logical_path
            or Path(logical_path).is_absolute()
            or ".." in Path(logical_path).parts
            or Path(logical_path).as_posix() != logical_path
            or logical_path in retained_paths
        ):
            raise CampaignError(f"{label}.path is unsafe or duplicate")
        retained_paths.add(logical_path)
        try:
            artifacts.validate_object_reference(
                _artifact_reference(entry),
                label,
            )
        except artifacts.ArtifactError as exc:
            raise CampaignError(str(exc)) from exc
    if retained != sorted(retained, key=lambda entry: entry["path"]):
        raise CampaignError(
            "campaign phase result artifacts are not sorted"
        )
    if not {"command.txt", "handoff-data/scripts/mom_test_orchestrator/"
            "campaign_handoff.lua", "host.log"} <= retained_paths:
        raise CampaignError(
            "campaign phase result lacks mandatory host evidence"
        )
    overlay_paths = {
        path for path in retained_paths if path.startswith("overlay-data/")
    }
    if bool(value["overlay"]) != bool(overlay_paths):
        raise CampaignError(
            "campaign phase overlay identity disagrees with its artifacts"
        )
    save_reference = _phase_artifact(value, "save.omwsave")
    if value["mode"] == "verify" and save_reference is not None:
        raise CampaignError("verify phase retained an output save")
    if value["status"] != "passed" and save_reference is not None:
        raise CampaignError("failed campaign phase retained an output save")
    if value["timedOut"]:
        if value["harnessExit"] != 124 or value["status"] != "failed":
            raise CampaignError("timed-out campaign phase result is inconsistent")
    if value["status"] == "passed":
        if not PHASE_REQUIRED_ARTIFACTS <= retained_paths:
            raise CampaignError(
                "passing campaign phase lacks required process evidence"
            )
        if value["openmwExit"] != 0:
            raise CampaignError(
                "passing campaign phase has a failed OpenMW process"
            )
        if value["mode"] == "verify":
            if (
                value["harnessExit"] != 0
                or value["harnessResultKind"] != "mom.correctness.result"
                or save_reference is not None
            ):
                raise CampaignError(
                    "passing verify phase has inconsistent process/save evidence"
                )
        elif (
            value["harnessExit"] != 0
            or value["harnessResultKind"]
            != "mom.process-campaign.phase-receipt"
            or save_reference is None
        ):
            raise CampaignError(
                "passing save phase has inconsistent process/save evidence"
            )
    return value


def validate_campaign_result(value: object) -> dict[str, object]:
    fields = {
        "schemaVersion",
        "kind",
        "status",
        "workdir",
        "campaigns",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise CampaignError("process campaign result has an unsupported shape")
    if (
        value["schemaVersion"] != 2
        or value["kind"] != "mom.process-campaign.result"
    ):
        raise CampaignError("process campaign result schema/kind is unsupported")
    if not isinstance(value["workdir"], str) or not value["workdir"]:
        raise CampaignError("process campaign result workdir is required")
    campaigns = value["campaigns"]
    if not isinstance(campaigns, list):
        raise CampaignError("process campaign results must be an array")
    seen: set[str] = set()
    derived = "passed"
    for index, row in enumerate(campaigns):
        if not isinstance(row, dict) or set(row) != {"id", "status", "phases"}:
            raise CampaignError(
                f"process campaign results[{index}] has an unsupported shape"
            )
        if (
            not isinstance(row["id"], str)
            or not row["id"]
            or row["id"] in seen
        ):
            raise CampaignError(
                f"process campaign results[{index}].id is invalid or duplicate"
            )
        seen.add(row["id"])
        if row["status"] not in {"passed", "failed"}:
            raise CampaignError(
                f"process campaign results[{index}].status is unsupported"
            )
        phases = row["phases"]
        if (
            not isinstance(phases, list)
            or not phases
            or not all(
                isinstance(path, str)
                and path
                and not Path(path).is_absolute()
                and ".." not in Path(path).parts
                for path in phases
            )
            or len(phases) != len(set(phases))
        ):
            raise CampaignError(
                f"process campaign results[{index}].phases is invalid"
            )
        if row["status"] == "failed":
            derived = "failed"
    if value["status"] != derived:
        raise CampaignError(
            "process campaign result status disagrees with its campaigns"
        )
    return value


def validate_campaign_artifacts(value: object) -> dict[str, object]:
    result = validate_campaign_result(value)
    try:
        root = Path(result["workdir"]).resolve(strict=True)
        if not (root / WORKDIR_MARKER).is_file():
            raise CampaignError(
                "process campaign workdir lacks its ownership marker"
            )
        store = artifacts.ContentStore(root, create=False)
        for campaign_index, campaign in enumerate(result["campaigns"]):
            definition = CAMPAIGN_BY_ID.get(campaign["id"])
            if definition is None:
                raise CampaignError(
                    f"unknown process campaign result: {campaign['id']}"
                )
            retained_phases = campaign["phases"]
            if len(retained_phases) > len(definition.phases) or (
                campaign["status"] == "passed"
                and len(retained_phases) != len(definition.phases)
            ):
                raise CampaignError(
                    "process campaign result has an inconsistent phase count"
                )
            previous_save: dict[str, object] | None = None
            derived_status = "passed"
            for phase_index, relative in enumerate(retained_phases):
                phase_path = (root / relative).resolve(strict=True)
                if root not in phase_path.parents or not phase_path.is_file():
                    raise CampaignError(
                        "campaign phase result escaped its workdir"
                    )
                phase = validate_phase_result(
                    artifacts.load_json(phase_path)
                )
                declared = definition.phases[phase_index]
                if (
                    phase["campaign"] != campaign["id"]
                    or phase["phase"] != declared.id
                    or phase["scenario"] != declared.scenario
                    or phase["mode"] != declared.mode
                    or phase["overlay"] != (declared.overlay or "")
                ):
                    raise CampaignError(
                        "campaign phase result disagrees with the catalog"
                    )
                if phase["inputSave"] != previous_save:
                    raise CampaignError(
                        "campaign phase save chain is inconsistent"
                    )
                if phase["inputSave"] is not None:
                    store.resolve(phase["inputSave"])
                for entry in phase["artifacts"]:
                    store.resolve(_artifact_reference(entry))
                output_save = _phase_artifact(phase, "save.omwsave")
                if output_save is not None:
                    previous_save = output_save
                if phase["status"] == "failed":
                    derived_status = "failed"
                    if phase_index != len(retained_phases) - 1:
                        raise CampaignError(
                            "campaign retained phases after its first failure"
                        )
            if campaign["status"] != derived_status:
                raise CampaignError(
                    f"process campaign results[{campaign_index}] "
                    "status disagrees with its phases"
                )
    except artifacts.ArtifactError as exc:
        raise CampaignError(str(exc)) from exc
    return result


def run_phase(
    *,
    campaign: Campaign,
    phase: Phase,
    index: int,
    input_save: Path | None,
    handoff: dict[str, str],
    settings: RunSettings,
) -> PhaseOutcome:
    campaign_dir = settings.workdir / "campaigns" / campaign.id
    phase_dir = campaign_dir / "phases" / f"{index:02d}_{phase.id}"
    harness_work = phase_dir / "work"
    host_log = phase_dir / "host.log"
    harness_result_path = phase_dir / "harness-result.json"
    phase_result_path = phase_dir / "phase-result.json"
    process_log = harness_work / "config" / "openmw.log"

    handoff_data = write_handoff_module(phase_dir, handoff, phase)
    overlay_data = (
        prepare_overlay(phase.overlay, phase_dir)
        if phase.overlay is not None
        else None
    )
    command = build_phase_command(
        phase=phase,
        harness_work=harness_work,
        harness_result=harness_result_path,
        handoff_data=handoff_data,
        overlay_data=overlay_data,
        input_save=input_save,
        openmw_binary=settings.openmw_binary,
        global_config=settings.global_config,
        base_config=settings.base_config,
        build_openmw=False,
    )
    command_path = phase_dir / "command.txt"
    artifacts.atomic_write(
        command_path,
        (shlex.join(command) + "\n").encode("utf-8"),
    )

    print(f"Campaign {campaign.id} phase {phase.id}: {phase.scenario}", flush=True)
    process_record = process.run_process(
        command,
        cwd=REPOSITORY_ROOT,
        environment=dict(os.environ),
        stdout_path=host_log,
        stderr_path=None,
        timeout_seconds=settings.phase_timeout,
        termination_grace_seconds=10,
    )
    capture_handoff_values(process_log, handoff)

    timed_out = bool(process_record["timedOut"])
    return_code = int(process_record["returnCode"])
    harness_exit = 124 if timed_out else return_code
    harness_result = _read_harness_result(harness_result_path)
    openmw_exit = (
        harness_result["openmwStatus"]
        if harness_result is not None
        else None
    )

    save_path: Path | None = None
    save_reference: dict[str, object] | None = None
    status = "failed"
    harness_status = (
        harness_result["status"] if harness_result is not None else None
    )
    coherent_exit = (
        harness_result is not None
        and openmw_exit == 0
        and return_code == (0 if harness_status == "passed" else 1)
    )
    if (
        phase.mode == "save"
        and not timed_out
        and coherent_exit
        and return_code == 0
        and harness_status == "passed"
        and harness_result["kind"]
        == "mom.process-campaign.phase-receipt"
        and harness_result["scenario"] == phase.scenario
    ):
        produced = newest_save(harness_work / "userdata" / "saves")
        if produced is not None:
            save_reference = settings.store.put(produced)
            save_path = settings.store.resolve(save_reference)
            status = "passed"
    elif (
        phase.mode == "verify"
        and not timed_out
        and coherent_exit
        and return_code == 0
        and harness_result is not None
        and harness_result["kind"] == "mom.correctness.result"
        and harness_result["status"] == "passed"
    ):
        status = "passed"

    retained: list[dict[str, object]] = []

    def retain(path: Path, logical_path: str) -> None:
        if path.is_file():
            retained.append({
                "path": logical_path,
                **settings.store.put(path),
            })

    retain(command_path, "command.txt")
    retain(host_log, "host.log")
    retain(process_log, "config/openmw.log")
    retain(harness_result_path, "result.json")
    retain(
        harness_work / "config" / "openmw.cfg",
        "config/openmw.cfg",
    )
    retain(
        harness_work / "config" / "settings.cfg",
        "config/settings.cfg",
    )
    retain(
        harness_work
        / "generated-data"
        / "scripts"
        / "mom_test_orchestrator"
        / "run_options.lua",
        "generated-data/scripts/mom_test_orchestrator/run_options.lua",
    )
    for input_root, logical_root in (
        (handoff_data, "handoff-data"),
        (overlay_data, "overlay-data"),
    ):
        if input_root is None:
            continue
        for path in sorted(input_root.rglob("*")):
            if path.is_file():
                retain(
                    path,
                    f"{logical_root}/{path.relative_to(input_root).as_posix()}",
                )
    if save_reference is not None:
        retained.append({
            "path": "save.omwsave",
            **save_reference,
        })
    retained.sort(key=lambda entry: entry["path"])
    input_reference = (
        settings.store.describe(input_save)
        if input_save is not None
        else None
    )
    phase_result = validate_phase_result({
        "schemaVersion": 2,
        "kind": "mom.process-campaign.phase",
        "status": status,
        "campaign": campaign.id,
        "phase": phase.id,
        "scenario": phase.scenario,
        "mode": phase.mode,
        "harnessExit": harness_exit,
        "openmwExit": openmw_exit,
        "timedOut": timed_out,
        "durationSeconds": process_record["durationSeconds"],
        "harnessResultKind": (
            str(harness_result["kind"])
            if harness_result is not None
            else ""
        ),
        "inputSave": input_reference,
        "artifacts": retained,
        "overlay": phase.overlay or "",
    })
    artifacts.write_json(phase_result_path, phase_result)
    for child in phase_dir.iterdir():
        if child == phase_result_path:
            continue
        if child.is_dir():
            shutil.rmtree(child)
        else:
            child.unlink()
    return PhaseOutcome(status, save_path, phase_result_path)


def positive_integer(value: str) -> int:
    if not value.isdecimal() or int(value) == 0:
        raise argparse.ArgumentTypeError("must be a positive integer")
    return int(value)


def parser() -> argparse.ArgumentParser:
    value = argparse.ArgumentParser(
        description="Run MOM persistence checks across fresh OpenMW processes"
    )
    value.add_argument("--campaign", action="append", default=[])
    value.add_argument(
        "--workdir",
        type=Path,
        default=Path(os.environ.get(
            "MOM_CAMPAIGN_WORKDIR",
            str(launch.default_workdir("campaigns")),
        )),
    )
    value.add_argument(
        "--phase-timeout",
        type=positive_integer,
        default=positive_integer(os.environ.get("MOM_CAMPAIGN_PHASE_TIMEOUT", "240")),
        metavar="SEC",
    )
    value.add_argument("--result-file", type=Path)
    value.add_argument("--global-config", type=Path)
    value.add_argument("--openmw", type=Path)
    value.add_argument("--openmw-base-config", type=Path)
    build = value.add_mutually_exclusive_group()
    build.add_argument("--build-openmw", dest="build_openmw", action="store_true")
    build.add_argument("--no-build-openmw", dest="build_openmw", action="store_false")
    value.set_defaults(build_openmw=None)
    value.add_argument("--list", action="store_true", dest="list_campaigns")
    return value


def run(arguments: argparse.Namespace) -> int:
    validate_catalog()
    if arguments.list_campaigns:
        print(*(campaign.id for campaign in CAMPAIGNS), sep="\n")
        return 0
    if not HARNESS.is_file() or not os.access(HARNESS, os.X_OK):
        raise CampaignError(f"harness is not executable: {HARNESS}")

    selected_ids = arguments.campaign or [campaign.id for campaign in CAMPAIGNS]
    unknown = [identifier for identifier in selected_ids if identifier not in CAMPAIGN_BY_ID]
    if unknown:
        raise CampaignError(f"unknown campaign: {unknown[0]}")

    workdir = prepare_workdir(arguments.workdir)
    result_file = arguments.result_file or workdir / "result.json"
    openmw_binary = launch.resolve_openmw_binary(
        arguments.openmw,
        work_directory=workdir,
        build_openmw=arguments.build_openmw,
    )
    settings = RunSettings(
        workdir=workdir,
        result_file=result_file,
        phase_timeout=arguments.phase_timeout,
        openmw_binary=openmw_binary,
        global_config=arguments.global_config,
        base_config=arguments.openmw_base_config,
        store=artifacts.ContentStore(workdir),
    )

    overall_status = "passed"
    campaign_results: list[dict[str, object]] = []
    for identifier in selected_ids:
        campaign = CAMPAIGN_BY_ID[identifier]
        handoff: dict[str, str] = {}
        current_save: Path | None = None
        campaign_status = "passed"
        phase_results: list[str] = []
        for index, phase in enumerate(campaign.phases, start=1):
            outcome = run_phase(
                campaign=campaign,
                phase=phase,
                index=index,
                input_save=current_save,
                handoff=handoff,
                settings=settings,
            )
            phase_results.append(
                outcome.result.relative_to(workdir).as_posix()
            )
            if outcome.status != "passed":
                campaign_status = "failed"
                overall_status = "failed"
                print(
                    f"Campaign {campaign.id} failed in phase {phase.id}; "
                    f"artifacts: {workdir / 'campaigns' / campaign.id}",
                    file=sys.stderr,
                )
                break
            if outcome.save is not None:
                current_save = outcome.save
        campaign_results.append({
            "id": campaign.id,
            "status": campaign_status,
            "phases": phase_results,
        })

    result = validate_campaign_result({
        "schemaVersion": 2,
        "kind": "mom.process-campaign.result",
        "status": overall_status,
        "workdir": str(workdir),
        "campaigns": campaign_results,
    })
    artifacts.write_json(result_file, result)
    validate_campaign_artifacts(result)
    print(f"Process campaign result: {overall_status}")
    print(f"Process campaign JSON: {result_file}")
    return 0 if overall_status == "passed" else 1


def main(argv: Sequence[str] | None = None) -> int:
    try:
        with process.cancellation_signals():
            return run(parser().parse_args(argv))
    except KeyboardInterrupt as exc:
        print(f"Process campaigns cancelled: {exc}", file=sys.stderr)
        return 128 + getattr(exc, "signum", 2)
    except (
        CampaignError,
        artifacts.ArtifactError,
        launch.LaunchError,
        OSError,
        process.ProcessError,
    ) as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
