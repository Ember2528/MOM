from __future__ import annotations

import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import uuid
from typing import Any, Iterable


class ArtifactError(RuntimeError):
    pass


SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
OBJECT_PATH_PATTERN = re.compile(
    r"^objects/([0-9a-f]{2})/([0-9a-f]{64})$"
)


def canonical_json(value: Any) -> bytes:
    return (json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True) + "\n").encode()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def tree_digest(roots: Iterable[Path]) -> str:
    digest = hashlib.sha256()
    members: list[tuple[str, Path]] = []
    for root in roots:
        resolved = root.resolve(strict=True)
        if resolved.is_file():
            members.append((resolved.name, resolved))
            continue
        for path in resolved.rglob("*"):
            if (
                path.is_file()
                and ".git" not in path.parts
                and "__pycache__" not in path.parts
                and path.suffix not in {".pyc", ".pyo"}
            ):
                members.append((f"{resolved.name}/{path.relative_to(resolved).as_posix()}", path))
    for name, path in sorted(members):
        digest.update(name.encode())
        digest.update(b"\0")
        digest.update(bytes.fromhex(sha256_file(path)))
    return digest.hexdigest()


def atomic_write(path: Path, value: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".tmp")
    with temporary.open("wb") as stream:
        stream.write(value)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def write_json(path: Path, value: Any) -> None:
    atomic_write(path, canonical_json(value))


def validate_object_reference(
    value: object,
    label: str = "artifact reference",
) -> dict[str, Any]:
    if (
        not isinstance(value, dict)
        or set(value) != {"object", "sha256", "size"}
    ):
        raise ArtifactError(f"{label} has an unsupported shape")
    digest = value["sha256"]
    size = value["size"]
    object_path = value["object"]
    if (
        not isinstance(digest, str)
        or SHA256_PATTERN.fullmatch(digest) is None
    ):
        raise ArtifactError(f"{label}.sha256 is invalid")
    if isinstance(size, bool) or not isinstance(size, int) or size < 0:
        raise ArtifactError(f"{label}.size must be a non-negative integer")
    match = (
        OBJECT_PATH_PATTERN.fullmatch(object_path)
        if isinstance(object_path, str)
        else None
    )
    if (
        match is None
        or match.group(1) != digest[:2]
        or match.group(2) != digest
    ):
        raise ArtifactError(f"{label}.object is inconsistent")
    return value


class ContentStore:
    def __init__(self, root: Path, *, create: bool = True):
        self.root = root.resolve()
        self.objects = self.root / "objects"
        if create:
            self.objects.mkdir(parents=True, exist_ok=True)

    def _path(self, digest: str) -> Path:
        return self.objects / digest[:2] / digest

    def put(self, source: Path) -> dict[str, Any]:
        resolved = source.resolve(strict=True)
        if not resolved.is_file():
            raise ArtifactError(f"canonical artifact is not a file: {resolved}")
        digest = sha256_file(resolved)
        size = resolved.stat().st_size
        destination = self._path(digest)
        if destination.is_file():
            if (
                destination.stat().st_size != size
                or sha256_file(destination) != digest
            ):
                raise ArtifactError(
                    f"canonical object is corrupt: {destination}"
                )
        else:
            destination.parent.mkdir(parents=True, exist_ok=True)
            temporary = destination.with_name(
                f".{destination.name}.{uuid.uuid4().hex}.tmp"
            )
            shutil.copyfile(resolved, temporary)
            if temporary.stat().st_size != size or sha256_file(temporary) != digest:
                temporary.unlink(missing_ok=True)
                raise ArtifactError(
                    f"canonical object copy is inconsistent: {resolved}"
                )
            try:
                os.replace(temporary, destination)
            finally:
                temporary.unlink(missing_ok=True)
        return {
            "object": destination.relative_to(self.root).as_posix(),
            "sha256": digest,
            "size": size,
        }

    def resolve(self, reference: object) -> Path:
        value = validate_object_reference(reference)
        destination = self.root / value["object"]
        try:
            resolved = destination.resolve(strict=True)
        except OSError as exc:
            raise ArtifactError(
                f"canonical object is missing: {destination}"
            ) from exc
        if self.root not in resolved.parents:
            raise ArtifactError(
                f"canonical object escaped its root: {destination}"
            )
        if (
            not resolved.is_file()
            or resolved.stat().st_size != value["size"]
            or sha256_file(resolved) != value["sha256"]
        ):
            raise ArtifactError(
                f"canonical object content is inconsistent: {destination}"
            )
        return resolved

    def describe(self, path: Path) -> dict[str, Any]:
        resolved = path.resolve(strict=True)
        try:
            relative = resolved.relative_to(self.root)
        except ValueError as exc:
            raise ArtifactError(
                f"path is outside the canonical object store: {resolved}"
            ) from exc
        reference = {
            "object": relative.as_posix(),
            "sha256": sha256_file(resolved),
            "size": resolved.stat().st_size,
        }
        self.resolve(reference)
        return reference


def _strict_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    value: dict[str, Any] = {}
    for key, item in pairs:
        if key in value:
            raise ArtifactError(f"duplicate JSON key: {key}")
        value[key] = item
    return value


def _load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as stream:
            return json.load(
                stream,
                object_pairs_hook=_strict_object,
                parse_constant=lambda value: (_ for _ in ()).throw(
                    ArtifactError(f"non-finite JSON number: {value}")
                ),
            )
    except (OSError, json.JSONDecodeError) as exc:
        raise ArtifactError(f"cannot read artifact JSON {path}: {exc}") from exc


def load_json(path: Path) -> Any:
    return _load_json(path)


def _finite_nonnegative(value: object, label: str) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or value < 0
    ):
        raise ArtifactError(f"{label} must be a finite non-negative number")
    return float(value)


def _validate_process_record(value: object, label: str) -> dict[str, Any]:
    fields = {
        "command",
        "cwd",
        "startedAtUtc",
        "durationSeconds",
        "returnCode",
        "timedOut",
        "cpuAffinity",
    }
    if not isinstance(value, dict) or set(value) != fields:
        raise ArtifactError(f"{label} has an unsupported shape")
    command = value["command"]
    if (
        not isinstance(command, list)
        or not command
        or not all(isinstance(item, str) and item for item in command)
    ):
        raise ArtifactError(f"{label}.command must contain nonempty arguments")
    for field in ("cwd", "startedAtUtc"):
        if not isinstance(value[field], str) or not value[field]:
            raise ArtifactError(f"{label}.{field} must be a nonempty string")
    _finite_nonnegative(value["durationSeconds"], f"{label}.durationSeconds")
    return_code = value["returnCode"]
    if isinstance(return_code, bool) or not isinstance(return_code, int):
        raise ArtifactError(f"{label}.returnCode must be an integer")
    if not isinstance(value["timedOut"], bool):
        raise ArtifactError(f"{label}.timedOut must be boolean")
    if value["timedOut"] and return_code == 0:
        raise ArtifactError(f"{label} timed out with a successful return code")
    affinity = value["cpuAffinity"]
    if (
        not isinstance(affinity, dict)
        or set(affinity) != {"requested", "effective", "scope"}
        or affinity["scope"] != "process_group"
    ):
        raise ArtifactError(f"{label}.cpuAffinity has an unsupported shape")
    for field in ("requested", "effective"):
        if affinity[field] is not None and (
            not isinstance(affinity[field], str) or not affinity[field]
        ):
            raise ArtifactError(
                f"{label}.cpuAffinity.{field} must be a nonempty string or null"
            )
    return value


def _validate_run_record(value: dict[str, Any]) -> dict[str, Any]:
    base_fields = {
        "status",
        "startedAtUtc",
        "finishedAtUtc",
        "processes",
        "preparationProcesses",
        "nativeCaptures",
    }
    if frozenset(value) not in {
        frozenset(base_fields),
        frozenset(base_fields | {"error"}),
    }:
        raise ArtifactError("run record has an unsupported shape")
    if value["status"] not in {"passed", "failed", "invalid"}:
        raise ArtifactError("run record status is unsupported")
    for field in ("startedAtUtc", "finishedAtUtc"):
        if not isinstance(value[field], str) or not value[field]:
            raise ArtifactError(f"run record {field} must be a nonempty string")
    for field in ("processes", "preparationProcesses", "nativeCaptures"):
        if not isinstance(value[field], list):
            raise ArtifactError(f"run record {field} must be an array")
    processes = [
        _validate_process_record(item, f"run record processes[{index}]")
        for index, item in enumerate(value["processes"])
    ]
    preparations = [
        _validate_process_record(
            item, f"run record preparationProcesses[{index}]"
        )
        for index, item in enumerate(value["preparationProcesses"])
    ]
    if value["status"] in {"passed", "invalid"}:
        if not processes:
            raise ArtifactError("completed run record has no execution processes")
        if any(
            record["timedOut"] or record["returnCode"] != 0
            for record in processes
        ):
            raise ArtifactError(
                "completed run record contains an unsuccessful process"
            )
        if any(
            record["timedOut"] or record["returnCode"] != 0
            for record in preparations
        ):
            raise ArtifactError(
                "completed run record contains an unsuccessful preparation process"
            )
    if "error" in value:
        error = value["error"]
        if (
            value["status"] != "failed"
            or not isinstance(error, dict)
            or set(error) != {"type", "message"}
            or not all(isinstance(error[field], str) and error[field] for field in error)
        ):
            raise ArtifactError("run record error has an unsupported shape")
    return value


def validate_run_directory(path: Path) -> dict[str, Any]:
    directory = path.resolve(strict=True)
    if not directory.is_dir():
        raise ArtifactError(f"performance run is not a directory: {directory}")
    run_path = directory / "run.json"
    receipt = _load_json(run_path)
    envelope_fields = {
        "schemaVersion",
        "kind",
        "runId",
        "specificationId",
        "artifacts",
    }
    if not isinstance(receipt, dict) or not envelope_fields <= set(receipt):
        raise ArtifactError("run.json has an unsupported shape")
    if (
        receipt["schemaVersion"] != 2
        or receipt["kind"] != "mom.performance.run"
    ):
        raise ArtifactError("run.json schema/kind is unsupported")
    run_id = receipt["runId"]
    specification_id = receipt["specificationId"]
    if (
        not isinstance(run_id, str)
        or SHA256_PATTERN.fullmatch(run_id) is None
        or not isinstance(specification_id, str)
        or SHA256_PATTERN.fullmatch(specification_id) is None
    ):
        raise ArtifactError("run.json identities must be lowercase SHA-256 values")
    if directory.name != run_id:
        raise ArtifactError("run directory name differs from run.json runId")

    manifest = receipt["artifacts"]
    if not isinstance(manifest, list):
        raise ArtifactError("run.json artifacts must be an array")
    physical: dict[str, dict[str, Any]] = {}
    for member in sorted(directory.rglob("*")):
        if member.is_symlink():
            raise ArtifactError(f"run directory contains a symbolic link: {member}")
        if not member.is_file():
            continue
        relative = member.relative_to(directory).as_posix()
        if relative == "run.json":
            continue
        physical[relative] = {
            "path": relative,
            "size": member.stat().st_size,
            "sha256": sha256_file(member),
            "storage": "inline",
        }
    store = ContentStore(directory.parent.parent, create=False)
    seen_paths: set[str] = set()
    for index, entry in enumerate(manifest):
        label = f"run.json artifacts[{index}]"
        if not isinstance(entry, dict):
            raise ArtifactError(f"{label} has an unsupported shape")
        storage = entry.get("storage")
        expected_fields = (
            {"path", "size", "sha256", "storage"}
            if storage == "inline"
            else {"path", "size", "sha256", "storage", "object"}
        )
        if set(entry) != expected_fields or storage not in {"inline", "object"}:
            raise ArtifactError(f"{label} has an unsupported shape")
        relative = entry["path"]
        if (
            not isinstance(relative, str)
            or not relative
            or Path(relative).is_absolute()
            or ".." in Path(relative).parts
            or Path(relative).as_posix() != relative
        ):
            raise ArtifactError(f"{label}.path is unsafe")
        if (
            isinstance(entry["size"], bool)
            or not isinstance(entry["size"], int)
            or entry["size"] < 0
        ):
            raise ArtifactError(f"{label}.size must be a non-negative integer")
        if (
            not isinstance(entry["sha256"], str)
            or SHA256_PATTERN.fullmatch(entry["sha256"]) is None
        ):
            raise ArtifactError(f"{label}.sha256 is invalid")
        if relative in seen_paths:
            raise ArtifactError(f"{label}.path is duplicate")
        seen_paths.add(relative)
        if storage == "inline":
            expected = physical.get(relative)
            if expected != entry:
                raise ArtifactError(
                    f"artifact manifest {label} differs from its inline artifact"
                )
        else:
            if relative in physical:
                raise ArtifactError(
                    f"{label} duplicates a canonical object inline"
                )
            store.resolve({
                "object": entry["object"],
                "sha256": entry["sha256"],
                "size": entry["size"],
            })
    if seen_paths != set(physical) | {
        entry["path"] for entry in manifest if entry["storage"] == "object"
    }:
        raise ArtifactError("run.json artifact manifest is inconsistent")
    if set(physical) != {
        entry["path"] for entry in manifest if entry["storage"] == "inline"
    }:
        raise ArtifactError(
            "run.json artifact manifest differs from the run directory"
        )
    if manifest != sorted(manifest, key=lambda entry: entry["path"]):
        raise ArtifactError("run.json artifact manifest is not sorted")

    specification = _load_json(directory / "spec.json")
    if (
        not isinstance(specification, dict)
        or specification.get("specificationId") != specification_id
    ):
        raise ArtifactError("spec.json specificationId is inconsistent")
    specification_payload = dict(specification)
    del specification_payload["specificationId"]
    if sha256_bytes(canonical_json(specification_payload)) != specification_id:
        raise ArtifactError("spec.json content does not match its specificationId")

    record = {
        key: value
        for key, value in receipt.items()
        if key not in envelope_fields
    }
    _validate_run_record(record)
    identity = {
        "specificationId": specification_id,
        "record": record,
        "artifacts": manifest,
    }
    if sha256_bytes(canonical_json(identity)) != run_id:
        raise ArtifactError("run.json content does not match its runId")

    summary_path = directory / "results" / "summary.json"
    if summary_path.is_file():
        summary = _load_json(summary_path)
        if (
            not isinstance(summary, dict)
            or summary.get("kind") != "mom.performance.summary"
            or summary.get("status") != record["status"]
        ):
            raise ArtifactError(
                "run.json status differs from results/summary.json"
            )
    return receipt


def resolve_run_artifact(
    directory: Path,
    receipt: dict[str, Any],
    logical_path: str,
) -> Path:
    matches = [
        entry
        for entry in receipt.get("artifacts", [])
        if entry.get("path") == logical_path
    ]
    if len(matches) != 1:
        raise ArtifactError(
            f"run artifact path is missing or ambiguous: {logical_path}"
        )
    entry = matches[0]
    if entry.get("storage") == "inline":
        return directory / logical_path
    if entry.get("storage") == "object":
        return ContentStore(
            directory.parent.parent,
            create=False,
        ).resolve({
            "object": entry["object"],
            "sha256": entry["sha256"],
            "size": entry["size"],
        })
    raise ArtifactError(
        f"run artifact storage is unsupported: {logical_path}"
    )


class ArtifactRun:
    def __init__(self, root: Path, repository_root: Path):
        self.root = root.resolve()
        repository_root = repository_root.resolve()
        if self.root == repository_root or repository_root in self.root.parents:
            raise ArtifactError("performance artifacts must live outside the repository")
        self.root.mkdir(parents=True, exist_ok=True)
        self.store = ContentStore(self.root)
        self.staging = self.root / f".staging-{uuid.uuid4().hex}"
        self.staging.mkdir()
        for name in ("config", "logs", "results", "perf", "work"):
            (self.staging / name).mkdir()
        self.specification: dict[str, Any] | None = None
        self.specification_id: str | None = None

    def write_specification(self, specification: dict[str, Any]) -> str:
        value = canonical_json(specification)
        self.specification = specification
        self.specification_id = sha256_bytes(value)
        write_json(self.staging / "spec.json", {
            **specification,
            "specificationId": self.specification_id,
        })
        return self.specification_id

    def copy(self, source: Path, relative_destination: str) -> Path:
        destination = self.staging / relative_destination
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, destination)
        return destination

    @staticmethod
    def _canonical_path(relative: str) -> bool:
        path = Path(relative)
        return (
            bool(path.parts)
            and path.parts[0] in {"config", "logs"}
        ) or (
            len(path.parts) >= 2
            and path.parts[0] == "results"
            and path.parts[1] == "raw"
        )

    def _manifest(self) -> list[dict[str, Any]]:
        entries: list[dict[str, Any]] = []
        for path in sorted(self.staging.rglob("*")):
            if not path.is_file() or "work" in path.relative_to(self.staging).parts:
                continue
            relative = path.relative_to(self.staging).as_posix()
            if relative == "run.json":
                continue
            if self._canonical_path(relative):
                reference = self.store.put(path)
                entries.append({
                    "path": relative,
                    "storage": "object",
                    **reference,
                })
                path.unlink()
            else:
                entries.append({
                    "path": relative,
                    "size": path.stat().st_size,
                    "sha256": sha256_file(path),
                    "storage": "inline",
                })
        return sorted(entries, key=lambda entry: entry["path"])

    def finalize(self, run_record: dict[str, Any]) -> Path:
        if self.specification_id is None:
            raise ArtifactError("artifact specification was not written")
        _validate_run_record(run_record)
        shutil.rmtree(self.staging / "work", ignore_errors=True)
        manifest = self._manifest()
        identity = {
            "specificationId": self.specification_id,
            "record": run_record,
            "artifacts": manifest,
        }
        run_id = sha256_bytes(canonical_json(identity))
        write_json(self.staging / "run.json", {
            **run_record,
            "schemaVersion": 2,
            "kind": "mom.performance.run",
            "runId": run_id,
            "specificationId": self.specification_id,
            "artifacts": identity["artifacts"],
        })
        runs = self.root / "runs"
        runs.mkdir(exist_ok=True)
        destination = runs / run_id
        if destination.exists():
            raise ArtifactError(f"content-addressed run already exists: {destination}")
        os.replace(self.staging, destination)
        return destination

    def abandon(self) -> None:
        shutil.rmtree(self.staging, ignore_errors=True)
