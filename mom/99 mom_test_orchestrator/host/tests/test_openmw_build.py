from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path
import signal
import shutil
import subprocess
import sys
import tempfile
import time
import unittest


HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import launch


class OpenmwBuildTests(unittest.TestCase):
    def build_environment(self, root: Path, source: Path) -> dict[str, str]:
        commands = root / "commands"
        commands.mkdir(exist_ok=True)
        cmake = commands / "cmake"
        cmake.write_text(f"#!{sys.executable}\n" + '''
import json
import os
from pathlib import Path
import subprocess
import sys
import time

arguments = sys.argv[1:]
if arguments == ['--version']:
    print('cmake version fixture')
elif arguments[0] == '--build':
    build = Path(arguments[1])
    binary = build / 'openmw'
    binary.write_text('#!/bin/sh\\nexit 0\\n')
    binary.chmod(0o755)
    (build / 'openmw.cfg').write_text('fixture engine config\\n')
    (build / 'defaults.bin').write_bytes(b'fixture defaults')
    (build / 'resources/vfs-mw').mkdir(parents=True)
else:
    source = Path(arguments[arguments.index('-S') + 1])
    build = Path(arguments[arguments.index('-B') + 1])
    build.mkdir(parents=True)
    head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    row = {'head': head, 'source': (source / 'source.txt').read_text(), 'options': arguments[4:]}
    with Path(os.environ['FIXTURE_BUILD_LOG']).open('a') as log:
        log.write(json.dumps(row) + '\\n')
    if os.environ.get('FIXTURE_HOLD'):
        Path(os.environ['FIXTURE_STARTED']).write_text(str(os.getpid()))
        deadline = time.monotonic() + 10
        while not Path(os.environ['FIXTURE_RELEASE']).exists():
            if time.monotonic() > deadline:
                raise SystemExit('fixture build release timed out')
            time.sleep(0.01)
''', encoding="utf-8")
        cmake.chmod(0o755)
        flock = commands / "flock"
        flock.write_text(
            f"#!{sys.executable}\nimport os\nfrom pathlib import Path\nimport sys\n"
            "if os.environ.get('FIXTURE_LOCK_ATTEMPT'):\n"
            "    Path(os.environ['FIXTURE_LOCK_ATTEMPT']).touch()\n"
            f"os.execv({shutil.which('flock')!r}, ['flock', *sys.argv[1:]])\n",
            encoding="utf-8",
        )
        flock.chmod(0o755)
        patches = root / "patches"
        patches.mkdir(exist_ok=True)
        return dict(os.environ, PATH=str(commands) + os.pathsep + os.environ["PATH"],
                    MOM_HARNESS_OPENMW_SOURCE_URL=str(source),
                    MOM_HARNESS_OPENMW_SOURCE_REF="clockwork-alpha",
                    MOM_HARNESS_OPENMW_BUILD_ROOT=str(root / "managed"),
                    MOM_HARNESS_OPENMW_PATCH_DIR=str(patches),
                    FIXTURE_BUILD_LOG=str(root / "builds.jsonl"),
                    FIXTURE_STARTED=str(root / "started"),
                    FIXTURE_RELEASE=str(root / "release"))

    @staticmethod
    def build_command(result: Path, *arguments: str) -> list[str]:
        return [str(launch.BUILD_ENTRYPOINT), "--result-file", str(result), *arguments]

    @staticmethod
    def wait_for_file(path: Path, child: subprocess.Popen[str]) -> None:
        deadline = time.monotonic() + 10
        while not path.exists():
            if child.poll() is not None:
                raise AssertionError(child.communicate())
            if time.monotonic() > deadline:
                raise AssertionError(f"fixture did not publish {path}")
            time.sleep(0.01)

    @staticmethod
    def stop_child(child: subprocess.Popen[str]) -> None:
        if child.poll() is None:
            os.killpg(child.pid, signal.SIGKILL)
        child.communicate(timeout=10)

    def git(self, directory: Path, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(directory), *arguments],
            check=True, text=True, capture_output=True,
        )
        return result.stdout.strip()

    def repository(self, root: Path, name: str, content: str) -> Path:
        repository = root / name
        repository.mkdir()
        self.git(repository, "init", "--initial-branch=clockwork-alpha")
        self.git(repository, "config", "user.name", "MOM harness tests")
        self.git(repository, "config", "user.email", "mom@example.invalid")
        self.commit(repository, content)
        return repository

    def commit(self, repository: Path, content: str) -> str:
        (repository / "source.txt").write_text(content, encoding="utf-8")
        self.git(repository, "add", "source.txt")
        self.git(repository, "commit", "-m", "test source")
        return self.git(repository, "rev-parse", "HEAD")

    def prepare_source(
        self, root: Path, remote: Path, ref: str = "clockwork-alpha",
    ) -> subprocess.CompletedProcess[str]:
        environment = dict(os.environ)
        environment.update({
            "OPENMW_SOURCE_URL": str(remote),
            "OPENMW_SOURCE_REF": ref,
            "OPENMW_BUILD_ROOT": str(root / "managed"),
            "OPENMW_SOURCE_DIR_EXPLICIT": "0",
            "DRY_RUN": "0",
            "REPO_ROOT": str(launch.REPOSITORY_ROOT),
            "SCRIPT_DIR": str(launch.HARNESS_ROOT),
        })
        return subprocess.run(
            ["bash", "-c", 'set -euo pipefail; die() { printf "%s\\n" "$*" >&2; exit 1; }; '
             'source "$1"; ensure_openmw_source_checkout', "test-build",
             str(launch.HARNESS_ROOT / "harness_lib" / "openmw_environment.sh")],
            env=environment, text=True, capture_output=True,
        )

    def test_managed_checkout_switches_remote_and_refreshes_branch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            first = self.repository(root, "first", "first\n")
            second = self.repository(root, "second", "second\n")
            # Forks can reuse tag names for different commits. Updating a
            # requested branch must not try to replace unrelated cached tags.
            self.git(first, "tag", "stable")
            self.git(second, "tag", "stable")
            cached = root / "managed" / "source-cache" / "openmw"
            for source in (first, second):
                result = self.prepare_source(root, source)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.git(cached, "remote", "get-url", "origin"), str(source))
                self.assertEqual(self.git(cached, "rev-parse", "HEAD"),
                                 self.git(source, "rev-parse", "HEAD"))
            updated = self.commit(second, "new branch tip\n")
            result = self.prepare_source(root, second)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.git(cached, "rev-parse", "HEAD"), updated)

            # A missing ref must fail rather than silently reuse a local branch
            # from the previous remote or an earlier fetch.
            result = self.prepare_source(root, first, "missing-branch")
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.git(cached, "rev-parse", "HEAD"), updated)

    def test_pinned_checkout_remains_at_requested_commit(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.repository(root, "source", "first\n")
            pinned = self.git(source, "rev-parse", "HEAD")
            self.commit(source, "later\n")
            result = self.prepare_source(root, source, pinned)
            self.assertEqual(result.returncode, 0, result.stderr)
            cached = root / "managed" / "source-cache" / "openmw"
            self.assertEqual(self.git(cached, "rev-parse", "HEAD"), pinned)

    def test_build_cache_identity_tracks_source_patches_and_build_options(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            patch = root / "test.patch"
            patch.write_text("first patch", encoding="utf-8")

            def key(head: str = "head-one", build_type: str = "Release") -> str:
                environment = dict(os.environ, OPENMW_BUILD_TYPE=build_type)
                result = subprocess.run(
                    ["bash", "-c", 'set -euo pipefail; source "$1"; '
                     'compute_openmw_build_key "$2" "$3"', "test-key",
                     str(launch.HARNESS_ROOT / "harness_lib" / "openmw_environment.sh"),
                     head, str(patch)],
                    env=environment, check=True, text=True, capture_output=True,
                )
                return result.stdout.split()[0]

            original = key()
            self.assertEqual(original, key())
            self.assertNotEqual(original, key(head="head-two"))
            self.assertNotEqual(original, key(build_type="RelWithDebInfo"))
            patch.write_text("changed patch", encoding="utf-8")
            self.assertNotEqual(original, key())

    def test_default_patches_follow_engine_runtime_and_allow_unpatched_builds(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            source.mkdir()

            def patches(patch_directory: Path) -> list[str]:
                environment = dict(os.environ, OPENMW_SOURCE_DIR=str(source),
                                   OPENMW_PATCH_DIR=str(patch_directory),
                                   SCRIPT_DIR=str(launch.HARNESS_ROOT))
                result = subprocess.run(
                    ["bash", "-c", 'set -euo pipefail; die() { exit 1; }; source "$1"; '
                     'collect_openmw_patches; '
                     'for patch in "${OPENMW_PATCH_FILES[@]}"; do printf "%s\\n" "$patch"; done',
                     "test-patches",
                     str(launch.HARNESS_ROOT / "harness_lib" / "openmw_environment.sh")],
                    env=environment, check=True, text=True, capture_output=True,
                )
                return result.stdout.splitlines()

            default = launch.HARNESS_ROOT / "openmw_patches"
            self.assertEqual(patches(default), [str(default / "0001-add-unsafe-sandbox-authority.patch")])
            (source / "components" / "luau").mkdir(parents=True)
            self.assertEqual(patches(default), [str(default / "luau" / "0001-add-harness-collector-authority.patch")])
            explicit = root / "patches"
            explicit.mkdir()
            self.assertEqual(patches(explicit), [])
            patch = explicit / "custom.patch"
            patch.write_text("custom", encoding="utf-8")
            self.assertEqual(patches(explicit), [str(patch)])

    def test_shell_and_python_default_targets_match(self) -> None:
        entrypoint = launch.BUILD_ENTRYPOINT.read_text(encoding="utf-8")
        self.assertIn(
            "MOM_HARNESS_OPENMW_SOURCE_URL:-" + launch.DEFAULT_SOURCE_URL,
            entrypoint,
        )
        self.assertIn(
            "MOM_HARNESS_OPENMW_SOURCE_REF:-" + launch.DEFAULT_SOURCE_REF,
            entrypoint,
        )
        self.assertEqual(launch.DEFAULT_SOURCE_URL,
                         "https://gitlab.com/OursCodeur/openmw.git")
        self.assertEqual(launch.DEFAULT_SOURCE_REF, "clockwork-alpha")

    def test_dry_run_creates_neither_cache_nor_result_and_preserves_existing_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = dict(os.environ, MOM_HARNESS_OPENMW_BUILD_ROOT=str(root / "cache"))
            for existing in (False, True):
                result = root / "plan" / "result.txt"
                if existing:
                    result.parent.mkdir()
                    result.write_text("previous build result\n")
                completed = subprocess.run(
                    self.build_command(result, "--dry-run"), env=environment,
                    text=True, capture_output=True, timeout=10,
                )
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertIn("OpenMW build plan:", completed.stdout)
                self.assertFalse((root / "cache").exists())
                if existing:
                    self.assertEqual(result.read_text(), "previous build result\n")
                else:
                    self.assertFalse(result.parent.exists())

    def test_cache_guards_resolve_aliases_and_refuse_unmarked_or_escaped_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.repository(root, "source", "source\n")
            environment = self.build_environment(root, source)
            alias = root / "repository-link"
            alias.symlink_to(launch.REPOSITORY_ROOT, target_is_directory=True)
            for cache in (Path("/tmp/parent/.."), alias / "..", root):
                with self.subTest(cache=cache):
                    completed = subprocess.run(
                        self.build_command(root / "result"), text=True, capture_output=True,
                        env=dict(environment, MOM_HARNESS_OPENMW_BUILD_ROOT=str(cache)), timeout=10,
                    )
                    self.assertNotEqual(completed.returncode, 0)
            cache = root / "managed"
            cache.mkdir()
            (cache / ".mom_openmw_build_root").touch()
            (cache / "source-cache").symlink_to(source, target_is_directory=True)
            sentinel = source / "keep.txt"
            sentinel.write_text("keep\n")
            completed = subprocess.run(
                self.build_command(root / "result"), env=environment,
                text=True, capture_output=True, timeout=10,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("outside owned OpenMW cache", completed.stderr)
            self.assertEqual(sentinel.read_text(), "keep\n")
            self.assertFalse((root / "result").exists())

    def test_concurrent_builders_compile_one_pinned_cache_entry(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.repository(root, "source", "source\n")
            environment = self.build_environment(root, source)
            first = subprocess.Popen(
                self.build_command(root / "first.txt"),
                env=dict(environment, FIXTURE_HOLD="1"), text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            )
            self.addCleanup(self.stop_child, first)
            self.wait_for_file(root / "started", first)
            second = subprocess.Popen(
                self.build_command(root / "second.txt"),
                env=dict(environment, FIXTURE_LOCK_ATTEMPT=str(root / "second-lock")), text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            )
            self.addCleanup(self.stop_child, second)
            self.wait_for_file(root / "second-lock", second)
            self.assertIsNone(second.poll())
            (root / "release").touch()
            for child in (first, second):
                _stdout, stderr = child.communicate(timeout=15)
                self.assertEqual(child.returncode, 0, stderr)
            self.assertEqual((root / "first.txt").read_bytes(), (root / "second.txt").read_bytes())
            builds = [json.loads(line) for line in (root / "builds.jsonl").read_text().splitlines()]
            self.assertEqual(len(builds), 1)
            self.assertEqual(builds[0]["head"], self.git(source, "rev-parse", "HEAD"))
            binary = Path((root / "first.txt").read_text().strip())
            identity = json.loads((binary.parent / "mom-build-identity.json").read_text())
            self.assertEqual(identity["buildKey"], (binary.parent / ".mom_openmw_patch_key").read_text().strip())
            self.assertEqual(identity["binary"], {
                "sha256": hashlib.sha256(binary.read_bytes()).hexdigest(), "size": binary.stat().st_size,
            })
            binary.write_text("stale executable\n")
            rebuilt = subprocess.run(
                self.build_command(root / "rebuilt.txt"), env=environment,
                text=True, capture_output=True, timeout=15,
            )
            self.assertEqual(rebuilt.returncode, 0, rebuilt.stderr)
            self.assertEqual(len((root / "builds.jsonl").read_text().splitlines()), 2)
            self.assertNotEqual(binary.read_text(), "stale executable\n")

    def test_build_provenance_records_patches_and_leaves_explicit_checkout_untouched(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.repository(root, "source", "original\n")
            commit = self.git(source, "rev-parse", "HEAD")
            self.git(source, "remote", "add", "origin", "https://example.invalid/openmw.git")
            (source / "source.txt").write_text("uncommitted edits\n")
            environment = self.build_environment(root, source)
            patch = root / "patches" / "fixture.patch"
            patch.write_text("diff --git a/source.txt b/source.txt\n--- a/source.txt\n+++ b/source.txt\n"
                             "@@ -1 +1 @@\n-original\n+patched\n")
            result = root / "result.txt"
            completed = subprocess.run(
                self.build_command(result), text=True, capture_output=True, timeout=15,
                env=dict(environment, MOM_HARNESS_OPENMW_SOURCE_DIR=str(source)),
            )
            self.assertEqual(completed.returncode, 0, completed.stderr)
            binary = Path(result.read_text().strip())
            identity = json.loads((binary.parent / "mom-build-identity.json").read_text())
            self.assertEqual(identity["source"], {
                "mode": "explicit", "commit": commit, "ref": "HEAD",
                "url": "https://example.invalid/openmw.git",
            })
            self.assertEqual(identity["patches"], [{
                "name": patch.name, "sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
            }])
            build = json.loads((root / "builds.jsonl").read_text())
            self.assertEqual(build["head"], commit)
            self.assertEqual(build["source"], "patched\n")
            self.assertEqual(identity["build"]["cmakeOptions"], build["options"])
            self.assertEqual((source / "source.txt").read_text(), "uncommitted edits\n")
            self.assertEqual(self.git(source, "rev-parse", "HEAD"), commit)
            self.assertEqual(self.git(source, "status", "--porcelain"), "M source.txt")

    def test_cancelled_build_releases_the_cache_lock_for_a_waiting_builder(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = self.repository(root, "source", "source\n")
            environment = self.build_environment(root, source)
            first = subprocess.Popen(
                self.build_command(root / "first.txt"), env=dict(environment, FIXTURE_HOLD="1"),
                text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            )
            self.addCleanup(self.stop_child, first)
            self.wait_for_file(root / "started", first)
            second = subprocess.Popen(
                self.build_command(root / "second.txt"),
                env=dict(environment, FIXTURE_LOCK_ATTEMPT=str(root / "second-lock")), text=True,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True,
            )
            self.addCleanup(self.stop_child, second)
            self.wait_for_file(root / "second-lock", second)
            self.assertIsNone(second.poll())
            os.killpg(first.pid, signal.SIGTERM)
            first.communicate(timeout=10)
            self.assertNotEqual(first.returncode, 0)
            _stdout, stderr = second.communicate(timeout=15)
            self.assertEqual(second.returncode, 0, stderr)
            self.assertFalse((root / "first.txt").exists())
            self.assertTrue(Path((root / "second.txt").read_text().strip()).is_file())


if __name__ == "__main__":
    unittest.main()
