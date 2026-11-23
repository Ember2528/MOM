#!/usr/bin/env python3
"""Build and audit the release ZIP against an include-only source manifest."""
from __future__ import annotations

import argparse
from pathlib import Path, PurePosixPath
import stat
import tempfile
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[1]
MANIFEST = Path(__file__).with_name("release_manifest.txt")
FORBIDDEN_NAMES = {"AGENTS.md", "__pycache__"}
FORBIDDEN_SUFFIXES = {".zip", ".omwsave", ".log", ".pyc", ".pyo"}


class PackageError(ValueError):
    pass


def source_files(repository: Path, manifest: Path) -> dict[str, bytes]:
    package_root = repository / "mom"
    files: dict[str, bytes] = {}
    for line in manifest.read_text(encoding="utf-8").splitlines():
        relative = line.strip()
        if not relative or relative.startswith("#"):
            continue
        parts = PurePosixPath(relative).parts
        if (
            len(parts) < 2 or parts[0] != "mom" or ".." in parts
            or "\\" in relative or PurePosixPath(relative).as_posix() != relative
        ):
            raise PackageError(f"invalid include path: {relative}")
        root = repository / relative
        if not root.exists():
            raise PackageError(f"missing include path: {relative}")
        for path in (root, *sorted(root.rglob("*"))):
            name = path.relative_to(package_root).as_posix()
            if path.is_symlink() or not path.resolve().is_relative_to(package_root.resolve()):
                raise PackageError(f"package source must not contain symlinks: {name}")
            if any(part.startswith(".") or part in FORBIDDEN_NAMES for part in PurePosixPath(name).parts):
                raise PackageError(f"package source contains local metadata: {name}")
            if path.is_dir():
                continue
            if not path.is_file() or path.suffix.lower() in FORBIDDEN_SUFFIXES:
                raise PackageError(f"package source contains a non-release file: {name}")
            if name in files:
                raise PackageError(f"overlapping include paths: {name}")
            files[name] = path.read_bytes()
    if not files:
        raise PackageError("release manifest contains no files")
    return dict(sorted(files.items()))


def audit_archive(archive: Path, files: dict[str, bytes]) -> None:
    with zipfile.ZipFile(archive) as package:
        entries = package.infolist()
        names = [entry.filename for entry in entries]
        if len(names) != len(set(names)):
            raise PackageError("archive contains duplicate entries")
        missing = sorted(files.keys() - set(names))
        unexpected = sorted(set(names) - files.keys())
        if missing or unexpected:
            raise PackageError(f"archive paths differ: missing={missing}; unexpected={unexpected}")
        for entry in entries:
            if stat.S_ISLNK(entry.external_attr >> 16):
                raise PackageError(f"archive contains a symlink: {entry.filename}")
            if package.read(entry) != files[entry.filename]:
                raise PackageError(f"archive content differs from source: {entry.filename}")


def build_archive(archive: Path, files: dict[str, bytes]) -> None:
    archive.parent.mkdir(parents=True, exist_ok=True)
    temporary: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(dir=archive.parent, suffix=".zip", delete=False) as handle:
            temporary = Path(handle.name)
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as package:
            for name, content in sorted(files.items()):
                entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
                entry.create_system = 3
                entry.external_attr = (stat.S_IFREG | 0o644) << 16
                package.writestr(entry, content, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
        audit_archive(temporary, files)
        temporary.replace(archive)
    finally:
        if temporary is not None:
            temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_mutually_exclusive_group()
    commands.add_argument("--build", type=Path, metavar="ZIP", help="build and audit a release ZIP")
    commands.add_argument("--audit", type=Path, metavar="ZIP", help="audit an existing ZIP against current sources")
    args = parser.parse_args()
    try:
        files = source_files(REPOSITORY_ROOT, MANIFEST)
        if args.build:
            archive = args.build.absolute()
            if archive.resolve().is_relative_to((REPOSITORY_ROOT / "mom").resolve()):
                raise PackageError("build the release ZIP outside the mom/ source directory")
            build_archive(archive, files)
            print(f"Built and audited {archive}: {len(files)} files")
        elif args.audit:
            audit_archive(args.audit, files)
            print(f"Audited {args.audit}: {len(files)} files")
        else:
            with tempfile.TemporaryDirectory(prefix="mom-release-audit-") as directory:
                build_archive(Path(directory) / "mom.zip", files)
            print(f"Release package audit passed: {len(files)} files in a freshly built ZIP")
    except (OSError, PackageError, zipfile.BadZipFile, RuntimeError) as exc:
        parser.exit(1, f"ERROR: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
