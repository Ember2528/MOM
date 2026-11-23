from __future__ import annotations

import argparse
from contextlib import redirect_stderr, redirect_stdout
import io
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import examples
import process


class ExamplesTests(unittest.TestCase):
    def test_collects_original_files_and_complete_fences_without_interpreting_prose(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            native = repository / "mom/01 Mod Patches/scripts/mom/config/patch.yml"
            native.parent.mkdir(parents=True)
            payload = b"version: 0\r\nvariants: {}\r\n# literal byte preservation\r\n"
            native.write_bytes(payload)
            conversion = repository / "mom/04 SSS Conversions/options/Schedule/scripts/mom/config/schedule.yaml"
            conversion.parent.mkdir(parents=True)
            conversion.write_bytes(payload)
            (conversion.parent / "template.yaml.example").write_bytes(payload)
            docs = repository / "mom/docs/guide.md"
            docs.parent.mkdir(parents=True)
            docs.write_bytes(
                b"# Any heading\n```yaml\n- modify: {}\n```\n"
                b"This prose is not a classification rule.\n```yaml\n"
                b"version: 0\r\nvariants: {}\r\n```\n"
                b"```yaml\nversion: 1\nvariants: {}\n```\n"
                b"```yaml\n  version: 0\n  variants: {}\n```\n"
                b"~~~yaml\nversion: 0 # complete\nvariants: {}\n~~~\n"
            )
            cases = examples.collect_examples(repository)
            self.assertEqual(len(cases), 4)
            self.assertEqual(cases[0].source, native.relative_to(repository).as_posix())
            self.assertEqual(cases[0].content, payload)
            self.assertEqual(cases[1].source, conversion.relative_to(repository).as_posix())
            self.assertEqual(cases[2].line, 7)
            self.assertEqual(cases[2].content, b"version: 0\r\nvariants: {}\r\n")
            self.assertIn(b"# complete", cases[3].content)
            staged = examples.stage_examples(repository / "generated", cases)
            self.assertEqual(len({path for path, _ in staged}), 4)
            for virtual, case in staged:
                self.assertEqual((repository / "generated" / virtual).read_bytes(), case.content)
                self.assertNotIn(case.source, virtual)

    def test_empty_inventory_and_unclosed_complete_fence_fail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(examples.ExamplesError, "no shipped"):
                examples.collect_examples(Path(directory))
        with self.assertRaisesRegex(examples.ExamplesError, "guide.md:2.*no closing fence"):
            examples.markdown_examples("guide.md", b"```yaml\nversion: 0\nvariants: {}\n")

    def test_nested_native_examples_stage_resources_without_other_runtime_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            repository = Path(directory)
            comparison = repository / "mom/04 SSS Conversions/comparisons/Scamps"
            data_root = comparison / "MOM"
            config = data_root / "scripts/mom/config/nested/scamps.yaml"
            config.parent.mkdir(parents=True)
            payload = b"version: 0\r\nvariants: {}\r\n"
            config.write_bytes(payload)
            resource_bytes = {
                "Meshes/RV/scamp.nif": b"\x00NIF\xff\r\n",
                "Textures/RV/scamp.dds": b"\x00DDS\xfe",
                "Sound/RV/scamp.wav": b"\x00WAV\xfd",
            }
            for name, content in resource_bytes.items():
                path = data_root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
            for name in ("helper.omwscripts", "original.esp", "scripts/execute_me.lua",
                         "scripts/staticSwitcher/data/not_native.yaml", "notes.yaml"):
                path = data_root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(payload)
            sss_config = comparison / "SSS/scripts/staticSwitcher/data/scamps.yaml"
            sss_config.parent.mkdir(parents=True)
            sss_config.write_bytes(b"replace_meshes: {}\n")
            sss_resource = comparison / "SSS/Meshes/RV/scamp.nif"
            sss_resource.parent.mkdir(parents=True)
            sss_resource.write_bytes(b"different SSS asset must not be staged")

            cases = examples.collect_examples(repository)
            self.assertEqual(len(cases), 1)
            self.assertEqual(cases[0].source, config.relative_to(repository).as_posix())
            self.assertEqual(cases[0].data_root, data_root)
            generated = repository / "generated"
            staged = examples.stage_examples(generated, cases)
            self.assertEqual((generated / staged[0][0]).read_bytes(), payload)
            for name, content in resource_bytes.items():
                self.assertEqual((generated / name).read_bytes(), content)
            self.assertEqual({p.relative_to(generated).as_posix()
                              for p in generated.rglob("*") if p.is_file()},
                             {*resource_bytes, staged[0][0]})

    def test_resource_collisions_follow_case_insensitive_vfs_paths(self) -> None:
        for conflicting in (False, True):
            with self.subTest(conflicting=conflicting), tempfile.TemporaryDirectory() as directory:
                repository = Path(directory)
                roots = [repository / "first", repository / "second"]
                first = roots[0] / "Meshes/RV/scamp.nif"
                second = roots[1] / "meshes/rv/SCAMP.NIF"
                first.parent.mkdir(parents=True)
                second.parent.mkdir(parents=True)
                first.write_bytes(b"\x00exact resource bytes\xff")
                second.write_bytes(b"different resource" if conflicting else first.read_bytes())
                cases = [examples.Example(str(index), 1, b"version: 0\nvariants: {}\n", root)
                         for index, root in enumerate(roots)]
                generated = repository / "generated"
                if conflicting:
                    with self.assertRaisesRegex(examples.ExamplesError,
                                                r"conflicting example resource meshes/rv/scamp\.nif"):
                        examples.stage_examples(generated, cases)
                    self.assertFalse(generated.exists())
                else:
                    examples.stage_examples(generated, cases)
                    resources = [p for p in generated.rglob("*")
                                 if p.is_file() and p.suffix.lower() == ".nif"]
                    self.assertEqual(len(resources), 1)
                    self.assertEqual(resources[0].read_bytes(), first.read_bytes())

    def test_yaml_looking_text_inside_other_fences_is_not_a_case(self) -> None:
        content = b"````text\n```yaml\nversion: 0\nvariants: {}\n```\n````\n"
        self.assertEqual(examples.markdown_examples("guide.md", content), [])

    def run_lua(self, source: str) -> subprocess.CompletedProcess[str]:
        executable = shutil.which("luajit")
        if executable is None:
            self.skipTest("LuaJIT is unavailable")
        with tempfile.TemporaryDirectory() as directory:
            script = Path(directory) / "check.lua"
            script.write_text(source, encoding="utf-8")
            return subprocess.run([executable, str(script)], check=True,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                  text=True, timeout=10)

    def test_lua_string_preserves_hostile_label_bytes_as_data(self) -> None:
        hostile = '\r\n\x00123"\\]]; error("injected") -- [=[é☃'
        completed = self.run_lua("io.write(" + examples.lua_string(hostile) + ")\n")
        self.assertEqual(completed.stdout, hostile.replace("\r\n", "\n"))

    def test_generated_script_compiles_paths_once_and_reports_original_rejection_location(self) -> None:
        hostile_label = 'mom/docs/guide"; error("injected") --.md'
        cases = [
            examples.Example(hostile_label, 17, b"version: 0\nvariants: {}\n"),
            examples.Example("mom/02 Examples/example.yaml", 1, b"version: 0\nvariants: {}\n"),
        ]
        staged = [(f"scripts/mom_example_validation/input_{index:04d}.yaml", case)
                  for index, case in enumerate(cases, 1)]
        for rejected in (False, True):
            with self.subTest(rejected=rejected):
                stub = """
local calls, quits = 0, 0
package.preload['openmw.core'] = function()
  return {quit = function() quits = quits + 1 end}
end
package.preload['scripts.mom.compiler.startup_compile'] = function()
  return {compile = function(options)
    calls = calls + 1
    assert(options.phase == 'GLOBAL')
    assert(#options.configPaths == 1)
    assert(options.configPaths[1] == string.format('scripts/mom_example_validation/input_%04d.yaml', calls))
"""
                if rejected:
                    stub += """
    if calls == 1 then
      return {status = 'rejected', fatal = {message = 'invalid authoring form', errors = {'bad row'}}}
    end
"""
                stub += """
    return {status = 'accepted', manifest = {actionIds = calls == 1 and {'one'} or {}},
      diagnostics = {summary = {diagnostics = {total = 1,
        samples = {{severity = 'warn', code = 'selector_unresolved', message = 'record unavailable'}}}}}}
  end}
end
-- Unknown imports fail: in particular no App, runtime or world service is available.
local function loadScript()
""" + examples.native_script(staged) + """
end
local script = loadScript()
assert(script.interface == nil and script.engineHandlers.onSave == nil)
script.engineHandlers.onUpdate()
script.engineHandlers.onUpdate()
assert(calls == 2 and quits == 1)
print('MOM_LOAD_EXAMPLES_RESULT:passed cases=2 operations=0 records=0 empty=2 diagnostics=0')
"""
                completed = self.run_lua(stub)
                self.assertEqual(examples.result_passed(0, completed.stdout, 2), not rejected)
                self.assertIn(cases[0].label, completed.stdout)
                if rejected:
                    self.assertIn('MOM_EXAMPLE_ERROR ' + cases[0].label + ': invalid authoring form',
                                  completed.stdout)
                    self.assertIn('MOM_EXAMPLES_RESULT:failed cases=2 failed=1', completed.stdout)
                else:
                    self.assertIn('MOM_EXAMPLES_RESULT:passed cases=2 actions=1 empty=1 diagnostics=2',
                                  completed.stdout)
                    self.assertIn('selector_unresolved: record unavailable', completed.stdout)

    def test_passing_receipt_is_unique_complete_and_matches_the_case_count(self) -> None:
        global_receipt = '[Global] MOM_EXAMPLES_RESULT:passed cases=2 actions=1 empty=1 diagnostics=0\n'
        load_receipt = '[Load] MOM_LOAD_EXAMPLES_RESULT:passed cases=2 operations=1 records=1 empty=1 diagnostics=0\n'
        passed = global_receipt + load_receipt
        self.assertTrue(examples.result_passed(0, passed, 2))
        for status, log, count in (
            (1, passed, 2), (0, '', 2), (0, passed + passed, 2),
            (0, passed, 1), (0, passed, 0), (0, 'MOM_PURE_RESULT:passed\n', 2),
            (0, passed + 'MOM_EXAMPLES_RESULT:failed cases=2 failed=1\n', 2),
            (0, passed.replace('empty=1', 'empty=3'), 2),
            (0, passed.replace('diagnostics=0', 'diagnostics=-1'), 2),
            (0, global_receipt, 2), (0, load_receipt, 2),
            (0, passed + load_receipt, 2),
            (0, global_receipt + load_receipt.replace('cases=2', 'cases=1'), 2),
            (0, global_receipt + load_receipt.replace('empty=1', 'empty=3'), 2),
        ):
            with self.subTest(status=status, log=log, count=count):
                self.assertFalse(examples.result_passed(status, log, count))

    def test_parser_requires_an_explicit_engine_and_has_a_unique_default_workdir(self) -> None:
        first = argparse.ArgumentParser()
        examples.configure_parser(first)
        with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit):
            first.parse_args([])
        second = argparse.ArgumentParser()
        examples.configure_parser(second)
        first_args = first.parse_args(['--openmw', '/opt/openmw'])
        second_args = second.parse_args(['--openmw', '/opt/openmw'])
        self.assertNotEqual(first_args.workdir, second_args.workdir)

    def test_run_uses_only_compile_script_safe_settings_and_requires_engine_receipt(self) -> None:
        for receipt in (True, False):
            with self.subTest(receipt=receipt), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                resources = root / 'resources'
                (resources / 'vfs-mw').mkdir(parents=True)
                data = root / 'data'
                data.mkdir()
                for master in ('Morrowind.esm', 'Tribunal.esm', 'Bloodmoon.esm'):
                    (data / master).write_bytes(b'fixture')
                global_config = root / 'global.cfg'
                global_config.write_text(f'data="{data}"\n')
                base = root / 'base.cfg'
                base.write_text(f'resources="{resources}"\n')
                engine = root / 'openmw'
                engine.write_bytes(b'')
                engine.chmod(0o755)
                workdir = root / 'examples'
                parser = argparse.ArgumentParser()
                examples.configure_parser(parser)
                arguments = parser.parse_args([
                    '--openmw', str(engine), '--workdir', str(workdir),
                    '--global-config', str(global_config), '--openmw-base-config', str(base),
                ])
                example_data = root / 'example-data'
                mesh = example_data / 'meshes/rv/scamp.nif'
                mesh.parent.mkdir(parents=True)
                mesh.write_bytes(b'\x00mesh\xff')
                (example_data / 'helper.omwscripts').write_text('GLOBAL: scripts/helper.lua\n')
                (example_data / 'scripts').mkdir()
                (example_data / 'scripts/helper.lua').write_text('error("must not execute")\n')
                case = examples.Example('docs/example.md', 12, b'version: 0\nvariants: {}\n', example_data)

                def complete(command: list[str], **options: object) -> dict[str, object]:
                    self.assertEqual(options['environment']['DISPLAY'], ':fixture')
                    self.assertEqual(options['timeout_seconds'], 300)
                    self.assertEqual(command[0], str(engine))
                    log = ('MOM_EXAMPLES_RESULT:passed cases=1 actions=0 empty=1 diagnostics=0\n'
                           'MOM_LOAD_EXAMPLES_RESULT:passed cases=1 operations=0 records=0 empty=1 diagnostics=0\n'
                           if receipt else 'OpenMW exited without running the check\n')
                    (workdir / 'config/openmw.log').write_text(log)
                    return {'returnCode': 0, 'timedOut': False}

                with (mock.patch.object(examples, 'collect_examples', return_value=[case]),
                      mock.patch.object(process, 'VirtualDisplay') as display,
                      mock.patch.object(process, 'run_process', side_effect=complete),
                      redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO())):
                    display.return_value.__enter__.return_value = ':fixture'
                    self.assertEqual(examples.run(arguments), 0 if receipt else 1)
                config = (workdir / 'config/openmw.cfg').read_text()
                self.assertEqual([line for line in config.splitlines() if line.startswith('content=')], [
                    'content=Morrowind.esm', 'content=Tribunal.esm', 'content=Bloodmoon.esm',
                    'content=mom_examples.omwscripts',
                ])
                self.assertIn('unsafe stdlib access = false', (workdir / 'config/settings.cfg').read_text())
                self.assertEqual((workdir / 'generated-data/scripts/mom_example_validation/input_0001.yaml').read_bytes(), case.content)
                self.assertEqual((workdir / 'generated-data/meshes/rv/scamp.nif').read_bytes(), mesh.read_bytes())
                self.assertNotIn(str(example_data), config)
                self.assertFalse((workdir / 'generated-data/helper.omwscripts').exists())
                self.assertFalse((workdir / 'generated-data/scripts/helper.lua').exists())
                self.assertEqual((workdir / 'generated-data/mom_examples.omwscripts').read_text(),
                                 'LOAD: scripts/mom_example_validation/check_load.lua\n'
                                 'GLOBAL: scripts/mom_example_validation/check.lua\n')
                self.assertTrue((workdir / 'generated-data' / examples.LOAD_SCRIPT_PATH).is_file())
                display.return_value.__exit__.assert_called_once()

    def test_load_script_compiles_the_same_files_with_write_protected_catalogs(self) -> None:
        cases = [examples.Example('docs/mixed.md', 12, b'version: 0\nvariants: {}\n')]
        staged = [('scripts/mom_example_validation/input_0001.yaml', cases[0])]
        for rejected in (False, True):
            with self.subTest(rejected=rejected):
                source = """
local calls, writes = 0, 0
local book = {id = 'book', name = 'original'}
local records = setmetatable({book, book = book}, {
  __newindex = function() writes = writes + 1; error('native write attempted') end,
})
package.preload['openmw.content'] = function() return {books = {records = records}} end
package.preload['openmw.util'] = function()
  return {makeReadOnly = function(value)
    local proxy = newproxy(true)
    local meta = getmetatable(proxy)
    meta.__index = value
    meta.__len = function() return #value end
    meta.__newindex = function() error('read-only') end
    return proxy
  end}
end
package.preload['scripts.mom.contracts.content_types'] = function()
  return {Book = {namespace = 'books'}, Static = {namespace = 'statics'}}
end
package.preload['scripts.mom.compiler.startup_compile'] = function()
  return {compile = function(options)
    calls = calls + 1
    assert(options.phase == 'LOAD' and options.vfr == false and #options.configPaths == 1)
    assert(options.configPaths[1] == 'scripts/mom_example_validation/input_0001.yaml')
    assert(options.content.gameSettings == nil and options.content.statics == nil)
    assert(#options.content.books.records == 1)
    assert(options.content.books.records.book.name == 'original')
    assert(not pcall(function() options.content.books.records.book = {} end))
    assert(not pcall(function() options.content.books.records[1] = {} end))
"""
                if rejected:
                    source += "return {status = 'rejected', errors = {'invalid content field'}}\n"
                else:
                    source += "return {status = 'accepted', plan = {writes = {{id = 'book'}}, metrics = {inputCount = 2}, diagnostics = {}}}\n"
                source += """
  end}
end
local function loadScript()
""" + examples.load_script(staged) + """
end
local script = loadScript()
assert(script.interface == nil and script.engineHandlers.onUpdate == nil)
script.engineHandlers.onContentFilesLoaded()
script.engineHandlers.onContentFilesLoaded()
assert(calls == 1 and writes == 0 and records.book.name == 'original')
print('MOM_EXAMPLES_RESULT:passed cases=1 actions=0 empty=1 diagnostics=0')
"""
                completed = self.run_lua(source)
                self.assertEqual(examples.result_passed(0, completed.stdout, 1), not rejected)
                if rejected:
                    self.assertIn('MOM_EXAMPLE_ERROR docs/mixed.md:12 LOAD: invalid content field',
                                  completed.stdout)
                else:
                    self.assertIn('MOM_LOAD_EXAMPLES_RESULT:passed cases=1 operations=2 records=1 empty=0 diagnostics=0',
                                  completed.stdout)


if __name__ == '__main__':
    unittest.main()
