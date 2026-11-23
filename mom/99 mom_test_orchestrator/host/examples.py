"""Compile every native example in LOAD and GLOBAL without executing either plan."""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import math
import os
from pathlib import Path
import re
import sys

import launch
import process


REPOSITORY_ROOT = Path(__file__).resolve().parents[3]
RESULT_MARKER = "MOM_EXAMPLES_RESULT:"
LOAD_RESULT_MARKER = "MOM_LOAD_EXAMPLES_RESULT:"
SCRIPT_CONTENT = "mom_examples.omwscripts"
SCRIPT_PATH = "scripts/mom_example_validation/check.lua"
LOAD_SCRIPT_PATH = "scripts/mom_example_validation/check_load.lua"
FENCE = re.compile(rb" {0,3}(`{3,}|~{3,})[ \t]*([^\s`~]*)[ \t]*\r?\n?$")
VERSION_ZERO = re.compile(rb"version[ \t]*:[ \t]*0[ \t]*(?:#[^\r\n]*)?$")
PASS_RECEIPT = re.compile(
    r"passed cases=(\d+) actions=(\d+) empty=(\d+) diagnostics=(\d+)$"
)
LOAD_PASS_RECEIPT = re.compile(
    r"passed cases=(\d+) operations=(\d+) records=(\d+) empty=(\d+) diagnostics=(\d+)$"
)


class ExamplesError(ValueError):
    pass


@dataclass(frozen=True)
class Example:
    source: str
    line: int
    content: bytes
    data_root: Path | None = None

    @property
    def label(self) -> str:
        return f"{self.source}:{self.line}"


def _complete(content: bytes) -> bool:
    lines = content.lstrip(b"\r\n").splitlines()
    return bool(lines and VERSION_ZERO.fullmatch(lines[0]))


def markdown_examples(source: str, content: bytes) -> list[Example]:
    """Select fenced YAML beginning with top-level version 0, without parsing it."""
    examples = []
    opening: tuple[bytes, int, bytes, int] | None = None
    lines = content.splitlines(keepends=True)
    for index, line in enumerate(lines):
        if opening is None:
            match = FENCE.fullmatch(line)
            if match:
                delimiter, language = match.groups()
                opening = delimiter[:1], len(delimiter), language.lower(), index + 1
            continue
        character, length, language, start = opening
        close = re.fullmatch(
            rb" {0,3}" + re.escape(character) + b"{" + str(length).encode() + rb",}[ \t]*\r?\n?",
            line,
        )
        if close:
            body = b"".join(lines[start:index])
            if language == b"yaml" and _complete(body):
                examples.append(Example(source, start + 1, body))
            opening = None
    if opening is not None:
        _, _, language, start = opening
        if language == b"yaml" and _complete(b"".join(lines[start:])):
            raise ExamplesError(f"{source}:{start + 1}: complete YAML example has no closing fence")
    return examples


def collect_examples(repository: Path = REPOSITORY_ROOT) -> list[Example]:
    examples = []
    for name in ("01 Mod Patches", "02 Examples", "04 SSS Conversions"):
        directory = repository / "mom" / name
        for path in sorted(directory.rglob("*")):
            if path.is_file() and path.suffix.lower() in {".yaml", ".yml"}:
                config_root = next((parent for parent in path.parents
                                    if parent.is_relative_to(directory)
                                    and parent.name.lower() == "config"
                                    and parent.parent.name.lower() == "mom"
                                    and parent.parent.parent.name.lower() == "scripts"), None)
                if config_root is not None:
                    examples.append(Example(path.relative_to(repository).as_posix(), 1,
                                            path.read_bytes(), config_root.parents[2]))
    for path in sorted((repository / "mom/docs").glob("*.md")):
        examples.extend(markdown_examples(path.relative_to(repository).as_posix(), path.read_bytes()))
    if not examples:
        raise ExamplesError("no shipped native YAML or complete documentation examples found")
    return examples


def lua_string(value: str) -> str:
    # Encode bytes, not Lua source. Decimal escapes have fixed width so a
    # following digit cannot extend the escape, including in hostile filenames.
    return '"' + "".join(
        chr(byte) if 32 <= byte <= 126 and byte not in {34, 92}
        else f"\\{byte:03d}"
        for byte in value.encode("utf-8")
    ) + '"'


def stage_examples(generated: Path, examples: list[Example]) -> list[tuple[str, Example]]:
    # Mount no example data directories wholesale: they may include executable
    # helpers, original-format configs, or plugins. Only resource namespaces
    # needed by the compiler enter this isolated validation VFS.
    resources: dict[str, tuple[Path, bytes, Path]] = {}
    data_roots = sorted({example.data_root.resolve() for example in examples
                         if example.data_root is not None})
    for data_root in data_roots:
        for namespace in sorted(data_root.iterdir()):
            if not namespace.is_dir() or namespace.name.lower() not in {"meshes", "textures", "sound"}:
                continue
            for source in sorted(namespace.rglob("*")):
                if not source.is_file():
                    continue
                relative = source.relative_to(data_root)
                key, content = relative.as_posix().lower(), source.read_bytes()
                previous = resources.get(key)
                if previous is not None and previous[1] != content:
                    raise ExamplesError(f"conflicting example resource {key}: {previous[2]} and {source}")
                if previous is None:
                    resources[key] = relative, content, source
    for relative, content, _source in resources.values():
        destination = generated / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(content)

    staged = []
    for index, example in enumerate(examples, 1):
        virtual_path = f"scripts/mom_example_validation/input_{index:04d}.yaml"
        path = generated / virtual_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(example.content)
        staged.append((virtual_path, example))
    return staged


def native_script(staged: list[tuple[str, Example]]) -> str:
    cases = "local cases = {\n" + "".join(
        f"  {{path = {lua_string(path)}, label = {lua_string(example.label)}}},\n"
        for path, example in staged
    ) + "}\n"
    return cases + r'''
local core = require('openmw.core')
local compiler = require('scripts.mom.compiler.startup_compile')
local done = false

local function text(value)
  return tostring(value or ''):gsub('%c', ' '):sub(1, 2048)
end

local function diagnostics(label, result)
  local summary = result.diagnostics and result.diagnostics.summary or {}
  local report = summary.diagnostics or {}
  local samples = report.samples or {}
  for index = 1, math.min(#samples, 8) do
    local sample = samples[index]
    print('MOM_EXAMPLE_DIAGNOSTIC ' .. text(label) .. ' '
      .. text(sample.severity) .. ' ' .. text(sample.code) .. ': ' .. text(sample.message))
  end
  if report.samplesTruncated then
    print('MOM_EXAMPLE_DIAGNOSTIC ' .. text(label) .. ': further diagnostics in compiler log')
  end
  return tonumber(report.total) or #samples
end

local function run()
  if done then return end
  done = true
  local failed, actions, empty, diagnosticCount = 0, 0, 0, 0
  for index = 1, #cases do
    local case = cases[index]
    local ok, result = pcall(compiler.compile, {phase = 'GLOBAL', configPaths = {case.path}})
    if not ok or type(result) ~= 'table' or result.status ~= 'accepted'
        or type(result.manifest) ~= 'table' or type(result.manifest.actionIds) ~= 'table' then
      failed = failed + 1
      local reason = result
      if type(result) == 'table' then
        local fatal = result.fatal or {}
        reason = fatal.message or fatal.code or 'compiler returned no accepted manifest'
        diagnostics(case.label, result)
        for detail = 1, math.min(#(fatal.errors or {}), 8) do
          print('MOM_EXAMPLE_ERROR ' .. text(case.label) .. ': ' .. text(fatal.errors[detail]))
        end
      end
      print('MOM_EXAMPLE_ERROR ' .. text(case.label) .. ': ' .. text(reason))
    else
      local count = #result.manifest.actionIds
      actions = actions + count
      if count == 0 then empty = empty + 1 end
      diagnosticCount = diagnosticCount + diagnostics(case.label, result)
      print('MOM_EXAMPLE_ACCEPTED ' .. text(case.label) .. ' actions=' .. tostring(count))
    end
  end
  if failed == 0 and #cases > 0 then
    print('MOM_EXAMPLES_RESULT:passed cases=' .. tostring(#cases)
      .. ' actions=' .. tostring(actions) .. ' empty=' .. tostring(empty)
      .. ' diagnostics=' .. tostring(diagnosticCount))
  else
    print('MOM_EXAMPLES_RESULT:failed cases=' .. tostring(#cases) .. ' failed=' .. tostring(failed))
  end
  core.quit()
end

return {engineHandlers = {onUpdate = run}}
'''


def load_script(staged: list[tuple[str, Example]]) -> str:
    cases = "local cases = {\n" + "".join(
        f"  {{path = {lua_string(path)}, label = {lua_string(example.label)}}},\n"
        for path, example in staged
    ) + "}\n"
    return cases + r'''
local content = require('openmw.content')
local util = require('openmw.util')
local types = require('scripts.mom.contracts.content_types')
local compiler = require('scripts.mom.compiler.startup_compile')
local done = false

local function text(value)
  return tostring(value or ''):gsub('%c', ' '):sub(1, 2048)
end

local function readOnlyContent()
  local view = {}
  for _, definition in pairs(types) do
    local ok, records = pcall(function() return content[definition.namespace].records end)
    if ok and records then
      -- A numeric snapshot preserves collection iteration on both runtimes.
      -- util.makeReadOnly is an existing API and rejects writes to this view.
      local values = {}
      for index = 1, #records do values[index] = records[index] end
      setmetatable(values, {__index = function(_, id) return records[id] end})
      view[definition.namespace] = util.makeReadOnly({records = util.makeReadOnly(values)})
    end
  end
  -- No gameSettings namespace is exposed, so validation cannot publish status.
  return util.makeReadOnly(view)
end

local function run()
  if done then return end
  done = true
  local readOnly = readOnlyContent()
  local failed, operations, records, empty, diagnosticCount = 0, 0, 0, 0, 0
  for _, case in ipairs(cases) do
    local ok, result = pcall(compiler.compile, {
      phase = 'LOAD', configPaths = {case.path}, content = readOnly, vfr = false,
    })
    if not ok or type(result) ~= 'table' or result.status ~= 'accepted'
        or type(result.plan) ~= 'table' or type(result.plan.writes) ~= 'table' then
      failed = failed + 1
      local errors = type(result) == 'table' and (result.errors or result.fatal and result.fatal.errors) or nil
      for index = 1, math.min(#(errors or {}), 8) do
        print('MOM_EXAMPLE_ERROR ' .. text(case.label) .. ' LOAD: ' .. text(errors[index]))
      end
      if #(errors or {}) == 0 then
        local reason = type(result) == 'table' and result.fatal and result.fatal.message or result
        print('MOM_EXAMPLE_ERROR ' .. text(case.label) .. ' LOAD: ' .. text(reason))
      end
    else
      local plan = result.plan
      local count = tonumber(plan.metrics and plan.metrics.inputCount) or #plan.writes
      operations, records = operations + count, records + #plan.writes
      if count == 0 then empty = empty + 1 end
      diagnosticCount = diagnosticCount + #(plan.diagnostics or {})
      for index = 1, math.min(#(plan.diagnostics or {}), 8) do
        local row = plan.diagnostics[index]
        print('MOM_EXAMPLE_DIAGNOSTIC ' .. text(case.label) .. ' LOAD '
          .. text(row.severity) .. ' ' .. text(row.code) .. ': ' .. text(row.message))
      end
      print('MOM_EXAMPLE_ACCEPTED ' .. text(case.label) .. ' contentOperations=' .. tostring(count)
        .. ' records=' .. tostring(#plan.writes))
    end
  end
  if failed == 0 and #cases > 0 then
    print('MOM_LOAD_EXAMPLES_RESULT:passed cases=' .. tostring(#cases)
      .. ' operations=' .. tostring(operations) .. ' records=' .. tostring(records)
      .. ' empty=' .. tostring(empty) .. ' diagnostics=' .. tostring(diagnosticCount))
  else
    print('MOM_LOAD_EXAMPLES_RESULT:failed cases=' .. tostring(#cases) .. ' failed=' .. tostring(failed))
  end
end

return {engineHandlers = {onContentFilesLoaded = run}}
'''


def result_passed(status: int, log: str, expected_cases: int) -> bool:
    receipts = [line.split(RESULT_MARKER, 1)[1].strip()
                for line in log.splitlines() if RESULT_MARKER in line]
    if status != 0 or expected_cases < 1 or len(receipts) != 1:
        return False
    match = PASS_RECEIPT.fullmatch(receipts[0])
    load_receipts = [line.split(LOAD_RESULT_MARKER, 1)[1].strip()
                     for line in log.splitlines() if LOAD_RESULT_MARKER in line]
    if len(load_receipts) != 1:
        return False
    load_match = LOAD_PASS_RECEIPT.fullmatch(load_receipts[0])
    return bool(match and int(match[1]) == expected_cases and int(match[3]) <= expected_cases
                and load_match and int(load_match[1]) == expected_cases
                and int(load_match[4]) <= expected_cases)


def configure_parser(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--openmw", type=Path, required=True,
                        help="explicit OpenMW executable; no harness patch is required")
    parser.add_argument("--global-config", type=Path)
    parser.add_argument("--openmw-base-config", type=Path)
    parser.add_argument("--workdir", type=Path, default=launch.default_workdir("examples"))
    parser.add_argument("--timeout", type=float, default=300)


def run(arguments: argparse.Namespace) -> int:
    try:
        with process.cancellation_signals():
            return _run(arguments)
    except (OSError, launch.LaunchError) as exc:
        raise ExamplesError(str(exc)) from exc


def _run(arguments: argparse.Namespace) -> int:
    if not math.isfinite(arguments.timeout) or arguments.timeout <= 0:
        raise ExamplesError("timeout must be finite and positive")
    binary = launch._resolve_executable(arguments.openmw)
    global_config = launch.resolve_global_config(arguments.global_config)
    base_config = launch.resolve_base_config(arguments.openmw_base_config, binary)
    data = launch.find_morrowind_data_dir(global_config)
    examples = collect_examples()
    workdir = launch.prepare_workdir(arguments.workdir)
    generated = workdir / "generated-data"
    staged = stage_examples(generated, examples)
    script = generated / SCRIPT_PATH
    script.write_text(native_script(staged), encoding="utf-8")
    (generated / LOAD_SCRIPT_PATH).write_text(load_script(staged), encoding="utf-8")
    (generated / SCRIPT_CONTENT).write_text(
        f"LOAD: {LOAD_SCRIPT_PATH}\nGLOBAL: {SCRIPT_PATH}\n", encoding="utf-8")
    launch.write_config(
        workdir / "config/openmw.cfg", base_config=base_config,
        morrowind_data=data, user_data=workdir / "userdata", generated_data=generated,
        script_content=(SCRIPT_CONTENT,),
    )
    (workdir / "config/settings.cfg").write_text(
        "[Lua]\nunsafe stdlib access = false\nexecution time limit per call = 0\n"
        "instruction limit per call = 0\nmemory limit = 0\n", encoding="utf-8",
    )
    command = [str(binary), "--config", str(workdir / "config"), "--replace=config",
               "--user-data", str(workdir / "userdata")]
    with process.VirtualDisplay(workdir / "xvfb.log") as display:
        completed = process.run_process(
            command, cwd=REPOSITORY_ROOT, environment={**os.environ, "DISPLAY": display},
            stdout_path=workdir / "stdout.log", stderr_path=workdir / "stderr.log",
            timeout_seconds=arguments.timeout, termination_grace_seconds=5,
        )
    log_path = workdir / "config/openmw.log"
    log = log_path.read_text(encoding="utf-8", errors="replace") if log_path.is_file() else ""
    for line in log.splitlines():
        if any(marker in line for marker in (
            "MOM_EXAMPLE_ACCEPTED ", "MOM_EXAMPLE_DIAGNOSTIC ", "MOM_EXAMPLE_ERROR ",
            RESULT_MARKER, LOAD_RESULT_MARKER,
        )):
            print(line)
    print("Compile-only check uses vanilla masters; content-gated variants may be inactive. "
          "It does not exercise absent plugins or world effects.")
    if completed["timedOut"]:
        print(f"Example compilation timed out; see {workdir}", file=sys.stderr)
        return 124
    if not result_passed(int(completed["returnCode"]), log, len(examples)):
        print(f"Example compilation failed; see {log_path} and {workdir / 'stderr.log'}", file=sys.stderr)
        return 1
    print(f"Compiled {len(examples)} examples in both LOAD and GLOBAL; evidence: {workdir}")
    return 0
