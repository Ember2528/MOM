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


class NativeLoaderDiagnosticsTests(unittest.TestCase):
    def run_bootstrap(self, entry: str, *, files: dict[str, str],
                      modules: dict[str, str] | None = None,
                      after: str = "", passed: bool = True) -> str:
        executable = shutil.which("luajit")
        if executable is None:
            self.skipTest("LuaJIT is unavailable")
        files = {"/repo/mom/99 mom_test_orchestrator/pure/run.lua": entry, **files}
        script_text = "sources = {\n" + "".join(
            f"[{standalone.lua_string(path)}] = {standalone.lua_string(source)},\n"
            for path, source in files.items()
        ) + "}\nmodules = {\n" + "".join(
            f"[{standalone.lua_string(name)}] = {standalone.lua_string(path)},\n"
            for name, path in (modules or {}).items()
        ) + "}\n"
        script_text += """
arguments, compiledSources = {'/repo'}, {}
package.preload['openmw.core'] = function() return {quit = function() end} end
package.preload['openmw.util'] = function()
  return {loadCode = function(source, environment)
    compiledSources[#compiledSources + 1] = source
    return setfenv(assert(loadstring(source, '=[native source]')), environment)
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
        )) + "))().engineHandlers.onUpdate()\n" + after
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "loader.lua"
            script.write_text(script_text)
            completed = subprocess.run([executable, str(script)], check=True,
                                       stdout=subprocess.PIPE, text=True, timeout=10)
        if passed:
            self.assertTrue(standalone.native_result_passed(completed.returncode, completed.stdout),
                            completed.stdout)
        else:
            self.assertEqual(completed.stdout.count("MOM_PURE_RESULT:failed\n"), 1,
                             completed.stdout)
        return completed.stdout

    def test_compile_failure_identifies_original_file_and_can_be_retried(self) -> None:
        path = "/repo/mom/00 OpenMW/scripts/broken.lua"
        self.run_bootstrap("""
local path = '/repo/mom/00 OpenMW/scripts/broken.lua'
local chunk, failure = loadfile(path)
assert(chunk == nil and failure:sub(1, #path + 2) == path .. ': ')
assert(failure:find('[native source]', 1, true))
for attempt = 1, 2 do
  local ok, failure = pcall(require, 'broken')
  assert(not ok and failure:find(path .. ': ', 1, true))
  assert(package.loaded.broken == nil)
end
""", files={path: "local = invalid"}, modules={"broken": path})

    def test_runtime_failure_identifies_original_file_and_retains_failure_sentinel(self) -> None:
        path = "/repo/mom/00 OpenMW/scripts/retry.lua"
        self.run_bootstrap("""
local path = '/repo/mom/00 OpenMW/scripts/retry.lua'
local ok, failure = pcall(require, 'retry')
assert(not ok and failure:sub(1, #path + 2) == path .. ': ')
assert(failure:find('fixture crashed', 1, true) and attempts == 1)
local failedCache = package.loaded.retry
ok, failure = pcall(require, 'retry')
assert(not ok and failure:find("loop or previous error loading module 'retry'", 1, true))
assert(attempts == 1 and package.loaded.retry == failedCache)
package.loaded.retry = nil
assert(require('retry') == false and attempts == 2)
assert(require('retry') == false and attempts == 3)
""", files={path: """
attempts = (attempts or 0) + 1
if attempts == 1 then error('fixture crashed', 0) end
return false
"""}, modules={"retry": path})

    def test_loadfile_preserves_source_arguments_and_nil_return_values(self) -> None:
        path = "/repo/mom/00 OpenMW/scripts/raw.lua"
        source = "-- original bytes: é\r\nlocal first, second = ...\r\nreturn first, nil, second, nil\r\n"
        self.run_bootstrap("""
local chunk = assert(loadfile('/repo/mom/00 OpenMW/scripts/raw.lua'))
local function check(...)
  assert(select('#', ...) == 4)
  local first, second, third, fourth = ...
  assert(first == 'one' and second == nil and third == 'two' and fourth == nil)
end
check(chunk('one', 'two'))
""", files={path: source}, after=(
            "assert(compiledSources[2] == " + standalone.lua_string(source) + ")\n"
        ))

    def test_entry_runtime_failure_reports_original_entry_path(self) -> None:
        output = self.run_bootstrap("error('entry crashed', 0)", files={}, passed=False)
        self.assertIn("/repo/mom/99 mom_test_orchestrator/pure/run.lua: entry crashed", output)


if __name__ == "__main__":
    unittest.main()
