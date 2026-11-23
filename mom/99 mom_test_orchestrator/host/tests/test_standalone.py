from __future__ import annotations

from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import standalone


class PureRuntimeTests(unittest.TestCase):
    def test_source_snapshot_preserves_bytes_and_production_module_precedence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            production = repository / "mom/00 OpenMW"
            harness = repository / "mom/99 mom_test_orchestrator"
            production.mkdir(parents=True)
            harness.mkdir(parents=True)
            source = b"-- actual source\r\nreturn 'production'\r\n"
            (production / "shared.lua").write_bytes(source)
            (harness / "shared.lua").write_text("return 'test facade'\n")
            (production / "mom.omwscripts").write_text("GLOBAL: shared.lua\n")
            sources, modules = standalone.source_snapshot(repository)
            self.assertEqual(sources[str(production / "shared.lua")].encode(), source)
            self.assertEqual(modules["shared"], str(production / "shared.lua"))
            self.assertIn(str(production / "mom.omwscripts"), sources)

    def test_source_literal_is_data_and_preserves_control_characters(self) -> None:
        executable = shutil.which("luajit")
        if executable is None:
            self.skipTest("LuaJIT is unavailable")
        source = '\r\n\x00123"\\]]; error("source escaped its literal") -- [=[é☃\n'
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "quoted.lua"
            script.write_text("io.write(" + standalone.lua_string(source) + ")\n")
            completed = subprocess.run([executable, str(script)], check=True,
                                       stdout=subprocess.PIPE, timeout=10)
            self.assertEqual(completed.stdout, source.encode())

    def test_native_success_requires_exactly_one_receipt_and_clean_exit(self) -> None:
        passed = "[Global] MOM_PURE_RESULT:passed\n"
        self.assertTrue(standalone.native_result_passed(0, passed))
        for status, log in ((1, passed), (0, ""), (0, passed + passed),
                            (0, passed + "MOM_PURE_RESULT:failed\n"),
                            (0, "MOM_PURE_RESULT:failed\n")):
            with self.subTest(status=status, log=log):
                self.assertFalse(standalone.native_result_passed(status, log))

    def test_native_test_loader_preserves_luajit_package_cache_behavior(self) -> None:
        executable = shutil.which("luajit")
        if executable is None:
            self.skipTest("LuaJIT is unavailable")
        checks = """
local function checkRequire(requireModule, cache, preload)
  local calls = 0
  preload.fixture = function() calls = calls + 1 end
  assert(requireModule('fixture') == true and requireModule('fixture') == true and calls == 1)
  cache.fixture = nil
  preload.fixture = function() calls = calls + 1; return false end
  assert(requireModule('fixture') == false and requireModule('fixture') == false and calls == 3)
  local published = {}
  preload.fixture = function() cache.fixture = published end
  assert(requireModule('fixture') == published and requireModule('fixture') == published)
  cache.fixture = false
  preload.fixture = function() cache.fixture = nil end
  assert(requireModule('fixture') == nil and cache.fixture == nil)
  calls = 0
  preload.fixture = function() calls = calls + 1; error('fixture load rejected') end
  assert(not pcall(requireModule, 'fixture'))
  assert(not pcall(requireModule, 'fixture') and calls == 1)
  cache.fixture = nil
  assert(not pcall(requireModule, 'fixture') and calls == 2)
  cache.fixture = nil
  preload.fixture = nil
end
"""
        # Compare the standard loader and the actual native bootstrap loader.
        # util.loadCode is the only mocked engine service; native suites exercise
        # that service on the real target frontend and VM separately.
        script_text = checks + "checkRequire(require, package.loaded, package.preload)\n"
        entry = checks + "checkRequire(require, package.loaded, package.preload)\n"
        script_text += "sources = {[" + standalone.lua_string(
            "/repo/mom/99 mom_test_orchestrator/pure/run.lua"
        ) + "] = " + standalone.lua_string(entry) + "}\n"
        script_text += """
modules, arguments = {}, {'/repo'}
package.preload['openmw.core'] = function() return {quit = function() end} end
package.preload['openmw.util'] = function()
  return {loadCode = function(source, environment)
    return setfenv(assert(loadstring(source)), environment)
  end}
end
local normalSelect = select
select = function(...)
  if normalSelect('#', ...) == 1 and (...) == 'sandbox.bypass' then
    return {collectgarbage = collectgarbage}
  end
  return normalSelect(...)
end
"""
        script_text += "assert(loadfile(" + standalone.lua_string(str(
            standalone.HARNESS_ROOT / "pure/native_bootstrap.lua"
        )) + "))().engineHandlers.onUpdate()\n"
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "loader.lua"
            script.write_text(script_text)
            completed = subprocess.run([executable, str(script)], check=True,
                                       stdout=subprocess.PIPE, text=True, timeout=10)
            self.assertTrue(standalone.native_result_passed(completed.returncode, completed.stdout),
                            completed.stdout)


if __name__ == "__main__":
    unittest.main()
