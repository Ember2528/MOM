from __future__ import annotations

import os
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import standalone


class StandaloneConfigTests(unittest.TestCase):
    def test_native_pure_launch_uses_shared_paths_and_only_pure_script_registration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            resources = root / "resources"
            (resources / "vfs-mw").mkdir(parents=True)
            data = root / "data"
            data.mkdir()
            for name in ("Morrowind.esm", "Tribunal.esm", "Bloodmoon.esm"):
                (data / name).write_bytes(b"fixture")
            global_config = root / "xdg/openmw/openmw.cfg"
            global_config.parent.mkdir(parents=True)
            global_config.write_text(f'data="{data}"\n', encoding="utf-8")
            base_config = root / "base.cfg"
            base_config.write_text(f'resources="{resources}"\n', encoding="utf-8")
            binary = root / "openmw"
            binary.write_text("", encoding="utf-8")
            binary.chmod(0o755)
            workdir = root / "native"
            arguments = standalone.parser().parse_args([
                "--openmw", str(binary), "--workdir", str(workdir)
            ])

            def complete(command: list[str], **kwargs: object) -> dict[str, object]:
                (workdir / "config/openmw.log").write_text(
                    "MOM_PURE_RESULT:passed\n", encoding="utf-8"
                )
                return {"returnCode": 0, "timedOut": False}

            with (mock.patch.dict(os.environ, {
                    "XDG_CONFIG_HOME": str(root / "xdg"),
                    "MOM_HARNESS_OPENMW_BASE_CONFIG": str(base_config),
                  }, clear=True),
                  mock.patch.object(standalone, "native_script", return_value="-- test\n"),
                  mock.patch.object(standalone.process, "run_process", side_effect=complete)):
                self.assertEqual(standalone.run_native(arguments), 0)
            config = (workdir / "config/openmw.cfg").read_text(encoding="utf-8")
            content = [line for line in config.splitlines() if line.startswith("content=")]
            self.assertEqual(content, [
                "content=Morrowind.esm", "content=Tribunal.esm", "content=Bloodmoon.esm",
                "content=mom_pure.omwscripts",
            ])
            self.assertIn(f'data="{data}"', config)
            self.assertIn(f'resources="{resources}"', config)


if __name__ == "__main__":
    unittest.main()
