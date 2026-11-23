"""Describe the exact source, patches and options of a harness-owned engine build."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys
from typing import Any


def command_identity(command: str) -> dict[str, Any]:
    arguments = shlex.split(command)
    executable = shutil.which(arguments[0]) if arguments else None
    version = None
    if executable is not None:
        try:
            result = subprocess.run(
                [executable, *arguments[1:], "--version"], check=False,
                stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=15,
            )
            if result.returncode == 0 and result.stdout.splitlines():
                version = result.stdout.splitlines()[0]
        except (OSError, subprocess.SubprocessError):
            pass
    return {"command": command, "path": executable, "version": version}


def encode(identity: dict[str, Any]) -> str:
    return json.dumps(identity, sort_keys=True, indent=2) + "\n"


def bind_binary(identity: dict[str, Any], binary: Path) -> dict[str, Any]:
    digest = hashlib.sha256()
    with binary.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return {
        **identity,
        "buildKey": hashlib.sha256(encode(identity).encode("utf-8")).hexdigest(),
        "binary": {"sha256": digest.hexdigest(), "size": binary.stat().st_size},
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    operation = parser.add_mutually_exclusive_group()
    operation.add_argument("--bind-binary", type=Path)
    operation.add_argument("--verify-binary", type=Path)
    parser.add_argument("--source-commit")
    parser.add_argument("--source-url", default="")
    parser.add_argument("--source-ref", default="HEAD")
    parser.add_argument("--source-mode", choices=("managed", "explicit"), default="managed")
    parser.add_argument("--build-type")
    parser.add_argument("--patch", action="append", type=Path, default=[])
    parser.add_argument("--cmake-option", action="append", default=[])
    arguments = parser.parse_args()
    if arguments.bind_binary or arguments.verify_binary:
        expected = json.load(sys.stdin)
        binary = arguments.bind_binary or arguments.verify_binary
        bound = bind_binary(expected, binary)
        if arguments.verify_binary:
            try:
                actual = json.loads(binary.with_name("mom-build-identity.json").read_text(encoding="utf-8"))
            except (OSError, ValueError):
                raise SystemExit(1)
            raise SystemExit(0 if actual == bound else 1)
        sys.stdout.write(encode(bound))
        return
    if not arguments.source_commit or not arguments.build_type:
        parser.error("--source-commit and --build-type are required when describing build inputs")
    identity = {
        "schemaVersion": 1,
        "kind": "mom.openmw-build",
        "source": {"url": arguments.source_url or None, "ref": arguments.source_ref,
                   "commit": arguments.source_commit, "mode": arguments.source_mode},
        "patches": [{"name": patch.name, "sha256": hashlib.sha256(patch.read_bytes()).hexdigest()}
                    for patch in arguments.patch],
        "build": {
            "type": arguments.build_type,
            "cmakeOptions": arguments.cmake_option,
            "cmake": command_identity("cmake"),
            "cCompiler": command_identity(os.environ.get("CC") or "cc"),
            "cxxCompiler": command_identity(os.environ.get("CXX") or "c++"),
            "environment": {name: os.environ.get(name) for name in
                            ("CMAKE_GENERATOR", "CFLAGS", "CXXFLAGS", "LDFLAGS")},
        },
    }
    sys.stdout.write(encode(identity))


if __name__ == "__main__":
    main()
