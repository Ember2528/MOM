from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest
import warnings
import zipfile


REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
sys.path.insert(0, str(REPOSITORY_ROOT / "tools"))

import release as release_package


class ReleasePackageTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.repository = self.root / "repo"
        self.core = self.repository / "mom" / "00 OpenMW"
        self.core.mkdir(parents=True)
        (self.core / "mom.omwscripts").write_text("GLOBAL: scripts/mom/mom.lua\n")
        (self.repository / "mom" / "README.md").write_text("Public README\n")
        docs = self.repository / "mom" / "docs"
        docs.mkdir()
        (docs / "GUIDE.md").write_text("Public guide\n")
        self.manifest = self.repository / "manifest.txt"
        self.manifest.write_text("mom/00 OpenMW\nmom/README.md\nmom/docs/GUIDE.md\n")
        self.archive = self.root / "mom.zip"

    def files(self) -> dict[str, bytes]:
        return release_package.source_files(self.repository, self.manifest)

    def test_build_is_deterministic_and_contains_public_docs(self) -> None:
        release_package.build_archive(self.archive, self.files())
        original = self.archive.read_bytes()
        os.utime(self.core / "mom.omwscripts", (1_000_000, 1_000_000))
        release_package.build_archive(self.archive, self.files())
        self.assertEqual(self.archive.read_bytes(), original)
        release_package.audit_archive(self.archive, self.files())
        with zipfile.ZipFile(self.archive) as package:
            self.assertEqual(package.namelist(), [
                "00 OpenMW/mom.omwscripts", "README.md", "docs/GUIDE.md",
            ])

    def test_unlisted_workspace_artifacts_do_not_enter_package(self) -> None:
        (self.repository / ".pytest_cache").mkdir()
        (self.repository / "mom" / "mom.zip").write_bytes(b"scratch archive")
        (self.repository / "mom" / "99 mom_test_orchestrator").mkdir()
        self.assertEqual(len(self.files()), 3)

    def test_audit_rejects_missing_docs_extra_files_and_changed_content(self) -> None:
        expected = self.files()
        for changed in ("missing", "extra", "content", "traversal"):
            with self.subTest(changed=changed):
                contents = dict(expected)
                if changed == "missing":
                    del contents["docs/GUIDE.md"]
                elif changed == "extra":
                    contents["99 mom_test_orchestrator/test.lua"] = b"test code"
                elif changed == "content":
                    contents["README.md"] = b"stale readme"
                else:
                    contents["../outside.lua"] = b"unexpected"
                with zipfile.ZipFile(self.archive, "w") as package:
                    for name, content in contents.items():
                        package.writestr(name, content)
                with self.assertRaises(release_package.PackageError):
                    release_package.audit_archive(self.archive, expected)

    def test_audit_rejects_duplicate_entries(self) -> None:
        release_package.build_archive(self.archive, self.files())
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", UserWarning)
            with zipfile.ZipFile(self.archive, "a") as package:
                package.writestr("README.md", b"duplicate")
        with self.assertRaisesRegex(release_package.PackageError, "duplicate"):
            release_package.audit_archive(self.archive, self.files())

    def test_source_scan_rejects_metadata_saves_and_symlinks(self) -> None:
        for name in (".codex", "AGENTS.md", "save.omwsave", "openmw.log"):
            with self.subTest(name=name):
                unwanted = self.core / name
                unwanted.write_text("local artifact")
                with self.assertRaises(release_package.PackageError):
                    self.files()
                unwanted.unlink()
        (self.core / "linked.lua").symlink_to(self.manifest)
        with self.assertRaisesRegex(release_package.PackageError, "symlinks"):
            self.files()

    def test_missing_required_source_is_rejected(self) -> None:
        (self.repository / "mom" / "docs" / "GUIDE.md").unlink()
        with self.assertRaisesRegex(release_package.PackageError, "missing include"):
            self.files()


if __name__ == "__main__":
    unittest.main()
