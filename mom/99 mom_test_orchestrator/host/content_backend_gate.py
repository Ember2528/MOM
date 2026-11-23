"""Native proof of LOAD record/list planning and staged full-copy execution.

The isolated profile mounts only production backend modules and this gate. It
never enables MOM's production LOAD/GLOBAL entry points or ordinary configs.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

import artifacts
import launch
import process

ROOT = Path(__file__).resolve().parents[3]
MARKER = 'MOM_CONTENT_BACKEND_GATE:PASSED'

LOAD = r"""
local content = require('openmw.content')
local planner = require('scripts.mom.compiler.content.planner')
local executor = require('scripts.mom.compiler.content.executor')
local schema = require('scripts.mom.compiler.content.schema')
local backend = require('scripts.mom.compiler.content.compile')
local canonical = require('scripts.mom.contracts.canonical')
local util = require('openmw.util')
local function colorFromRGB(value)
  return util.color.rgb((value % 256) / 255, (math.floor(value / 256) % 256) / 255,
    (math.floor(value / 65536) % 256) / 255)
end
local function expect(value, message) assert(value, message) end
local function first(namespace)
  local record = assert(namespace.records[1], 'missing vanilla template')
  return record, record.id
end
local function run()
  local static = first(content.statics)
  local light = first(content.lights)
  local book = first(content.books)
  local creatures = first(content.levelledCreatures)
  local oldModel = static.model
  local otherModel
  for index = 2, #content.statics.records do
    local candidate = content.statics.records[index].model
    if candidate ~= oldModel and candidate ~= '' then otherModel = candidate; break end
  end
  expect(otherModel, 'distinct native static model missing')
  content.statics.records.mom_backend_gate_a = static
  content.statics.records.mom_backend_gate_b = static
  content.lights.records.mom_backend_gate_light = light
  content.books.records.mom_backend_gate_book = book
  content.levelledCreatures.records.mom_backend_gate_list = {template = creatures,
    creatures = {{id = 'rat', level = 1}, {id = 'rat', level = 1}, {id = 'scrib', level = 2}},
    chanceNone = 0.37, calculateFromAllLevels = true}
  local beforeChance = content.levelledCreatures.records.mom_backend_gate_list.chanceNone
  local beforeBookModel = content.books.records.mom_backend_gate_book.model
  local function selected(rows)
    return {sourceAttempts = {{status = 'resolved', path = 'native mixed fixture', actions = rows}}}
  end
  local function modelAction(source)
    return {family = 'place_ref', spec = {disableOriginal = true, select = {type = 'Static'},
      attach = {{'*', source, otherModel}}}}
  end
  local lowered, loweringErrors = backend.compile(selected({modelAction('mom_backend_gate_a')}), {content = content})
  expect(lowered, loweringErrors and table.concat(loweringErrors, '; '))
  expect(#lowered.writes == 1 and lowered.writes[1].id == 'mom_backend_gate_a'
    and lowered.writes[1].patch.model == otherModel, 'typed exact model lowering differs')
  local meshLowered = assert(backend.compile(selected({modelAction(oldModel)}), {content = content}))
  expect(meshLowered.metrics.recordCatalogScans.Static == 1 and #meshLowered.writes >= 2,
    'native content collection model indexing differs')
  expect(content.statics.records.mom_backend_gate_a.model == oldModel, 'model lowering wrote content')
  local missing, missingErrors = backend.compile(selected({modelAction('mom_missing_source')}), {content = content})
  expect(missing == nil and missingErrors[1]:find('matches no LOAD records', 1, true),
    'missing LOAD model intent fell through')
  local nodes = {
    {kind = 'record', source = 'native static', payload = {type = 'Static', id = 'mom_backend_gate_a', patch = {model = otherModel}}},
    {kind = 'record', source = 'native light', payload = {type = 'Light', id = 'mom_backend_gate_light',
      patch = {radius = 777, duration = -1, color = 3153936, isOffByDefault = true}}},
    {kind = 'record', source = 'native book', payload = {type = 'Book', id = 'mom_backend_gate_book',
      patch = {name = 'MOM native book', text = 'MOM content backend native text', weight = 0.25,
        value = 2000000, enchantCapacity = 1.25}}},
    {kind = 'record', source = 'native named record', payload = {type = 'Static', id = 'mom_backend_gate_created',
      template = 'mom_backend_gate_b', create = true, patch = {model = otherModel}}},
    {kind = 'leveled', source = 'native list', payload = {type = 'CreatureLevelledList', id = 'mom_backend_gate_list',
      operations = {{op = 'append', entries = {{id = 'rat', level = 1}}},
        {op = 'add_if_absent', entries = {{id = 'rat', level = 1}, {id = 'rat', level = 3}}}}}},
  }
  local plan, errors = planner.compile(nodes, {content = content})
  expect(plan, errors and table.concat(errors, '\n'))
  expect(content.statics.records.mom_backend_gate_a.model == oldModel, 'planning mutated static')
  expect(content.books.records.mom_backend_gate_book.text == book.text, 'planning mutated book')
  local result = executor.execute(plan, {content = content, colorFromRGB = colorFromRGB})
  expect(result.status == 'committed', result.status .. ': ' .. table.concat(result.errors, '; ') .. ' / ' .. table.concat(result.cleanupErrors, '; '))
  expect(result.changedCount == 5, 'native changed count differs')
  expect(content.statics.records.mom_backend_gate_a.id == 'mom_backend_gate_a', 'record identity changed')
  expect(content.statics.records.mom_backend_gate_a.model == otherModel, 'static model did not change')
  expect(content.statics.records.mom_backend_gate_created.model == otherModel, 'named record missing')
  local modifiedLight = content.lights.records.mom_backend_gate_light
  expect(modifiedLight.radius == 777 and modifiedLight.duration == -1 and modifiedLight.isOffByDefault, 'light properties differ')
  expect(schema.read(modifiedLight, 'color') == 3153936, 'packed RGB did not round-trip')
  local modifiedBook = content.books.records.mom_backend_gate_book
  expect(modifiedBook.name == 'MOM native book' and modifiedBook.text == 'MOM content backend native text', 'book text/name differ')
  expect(modifiedBook.model == beforeBookModel and modifiedBook.weight == 0.25, 'book template fields differ')
  expect(schema.equal('enchantCapacity', modifiedBook.enchantCapacity, 1.3), 'book capacity did not normalize to tenths')
  local list = content.levelledCreatures.records.mom_backend_gate_list
  expect(#list.creatures == 5 and list.creatures[4].id == 'rat' and list.creatures[5].level == 3, 'native list weight/order differs')
  expect(list.chanceNone == beforeChance and list.calculateFromAllLevels, 'untouched chance/flags changed')
  local prefix = 'mom__content_' .. assert(canonical.hashBody(plan.contentHash)) .. '_'
  for index, row in ipairs(plan.writes) do
    local records = assert(schema.store(content, row.type))
    expect(records[prefix .. index .. '_backup'] == nil and records[prefix .. index .. '_stage'] == nil, 'temporary record leaked')
  end
  -- Packed RGB and integral properties need exact comparisons even at large
  -- magnitudes; a one-unit edit must not be classified as a float no-op.
  content.lights.records.mom_backend_gate_precision = {template = light,
    color = colorFromRGB(16777215), radius = 2000000, duration = 2000000}
  local precisionPlan, precisionErrors = planner.compile({
    {kind = 'record', payload = {type = 'Light', id = 'mom_backend_gate_precision',
      patch = {color = 16777214, radius = 2000001, duration = 2000001}}},
    {kind = 'record', payload = {type = 'Book', id = 'mom_backend_gate_book', patch = {value = 2000001}}},
  }, {content = content})
  expect(precisionPlan, precisionErrors and table.concat(precisionErrors, '\n'))
  expect(precisionPlan.metrics.changedCount == 2, 'one-unit native edits were classified as no-op')
  local precisionResult = executor.execute(precisionPlan, {content = content, colorFromRGB = colorFromRGB})
  expect(precisionResult.status == 'committed', table.concat(precisionResult.errors, '; '))
  local precisionLight = content.lights.records.mom_backend_gate_precision
  expect(schema.read(precisionLight, 'color') == 16777214 and precisionLight.radius == 2000001
    and precisionLight.duration == 2000001 and content.books.records.mom_backend_gate_book.value == 2000001,
    'one-unit integer/RGB edits did not round-trip')
  -- Existing engines differ in whether their percentage parser multiplies a
  -- float or a double. Explicit decimal percentages must agree in both.
  for _, case in ipairs({{0, 0}, {0.29, 0.29}, {0.57, 0.57}, {0.58, 0.58},
      {0.335, 0.33}, {0.999, 0.99}, {1, 1}}) do
    local chanceNodes = {{kind = 'leveled', payload = {type = 'CreatureLevelledList',
      id = 'mom_backend_gate_list', patch = {chanceNone = case[1]}}}}
    local chancePlan, chanceErrors = planner.compile(chanceNodes, {content = content})
    expect(chancePlan, chanceErrors and table.concat(chanceErrors, '\n'))
    expect(chancePlan.writes[1].patch.chanceNone == case[2], 'probability plan has wrong stored percent')
    local chanceResult = executor.execute(chancePlan, {content = content})
    expect(chanceResult.status == 'committed', 'native probability ' .. case[1] .. ': ' .. table.concat(chanceResult.errors, '; '))
    expect(math.abs(content.levelledCreatures.records.mom_backend_gate_list.chanceNone - case[2]) < 0.000001,
      'native probability entered an adjacent stored percent')
    local unchangedPlan = assert(planner.compile(chanceNodes, {content = content}))
    expect(executor.execute(unchangedPlan, {content = content}).status == 'noop', 'stored probability did not remain a no-op')
  end
  local capacityPlan, capacityErrors = planner.compile({{kind = 'record', payload = {type = 'Book',
    id = 'mom_backend_gate_book', patch = {enchantCapacity = 1000000, weight = 1000000}}}}, {content = content})
  expect(capacityPlan, capacityErrors and table.concat(capacityErrors, '\n'))
  expect(executor.execute(capacityPlan, {content = content}).status == 'committed')
  local capacityStepPlan = assert(planner.compile({{kind = 'record', payload = {type = 'Book',
    id = 'mom_backend_gate_book', patch = {enchantCapacity = 1000000.1, weight = 1000000.0625}}}}, {content = content}))
  expect(capacityStepPlan.metrics.changedCount == 1, 'representable capacity/weight edit was lost')
  local capacityStepResult = executor.execute(capacityStepPlan, {content = content})
  expect(capacityStepResult.status == 'committed', table.concat(capacityStepResult.errors, '; '))
  expect(content.books.records.mom_backend_gate_book.enchantCapacity > 1000000
    and content.books.records.mom_backend_gate_book.weight == 1000000.0625, 'representable float32 edit was lost')
  local capacityPlan, capacityErrors = planner.compile({{kind = 'record', payload = {type = 'Book',
    id = 'mom_backend_gate_book', patch = {enchantCapacity = 214748352}}}}, {content = content})
  expect(capacityPlan, capacityErrors and table.concat(capacityErrors, '\n'))
  local capacityResult = executor.execute(capacityPlan, {content = content})
  expect(capacityResult.status == 'committed', table.concat(capacityResult.errors, '; '))
  expect(content.books.records.mom_backend_gate_book.enchantCapacity == 214748352, 'maximum safe capacity differs')
  expect(planner.compile({{kind = 'record', payload = {type = 'Book', id = 'mom_backend_gate_book',
    patch = {enchantCapacity = 214748364.7}}}}, {content = content}) == nil, 'unsafe capacity was accepted')
  -- A real mutable store wrapped only at the mutation boundary proves that
  -- backup wrappers remain detached when a later public assignment fails.
  content.statics.records.mom_backend_gate_a = static
  local failed = false
  local records = setmetatable({}, {
    __index = function(_, key) return content.statics.records[key] end,
    __newindex = function(_, key, value)
      if key == 'mom_backend_gate_b' and value ~= nil and not failed then
        failed = true
        error('native fault injection')
      end
      content.statics.records[key] = value
    end,
  })
  local proxy = {statics = {records = records}}
  local restorePlan, restoreErrors = planner.compile({
    {kind = 'record', source = 'restore a', payload = {type = 'Static', id = 'mom_backend_gate_a', patch = {model = otherModel}}},
    {kind = 'record', source = 'restore b', payload = {type = 'Static', id = 'mom_backend_gate_b', patch = {model = otherModel}}},
  }, {content = proxy})
  expect(restorePlan, restoreErrors and table.concat(restoreErrors, '\n'))
  local restored = executor.execute(restorePlan, {content = proxy})
  expect(restored.status == 'restored_failure', 'native rollback result: ' .. restored.status)
  expect(content.statics.records.mom_backend_gate_a.model == oldModel
    and content.statics.records.mom_backend_gate_b.model == oldModel, 'native backup aliased edited record')
  local itemSupported, itemRecords = pcall(function() return content.levelledItems.records end)
  if itemSupported and itemRecords then
    local itemTemplate = assert(itemRecords[1])
    itemRecords.mom_backend_gate_items = {template = itemTemplate, items = {{id = 'gold_001', level = 1}},
      chanceNone = 0.5, calculateForEach = true}
    local itemPlan, itemErrors = planner.compile({{kind = 'leveled', source = 'native item list',
      payload = {type = 'ItemLevelledList', id = 'mom_backend_gate_items', operations = {
        {op = 'append', entries = {{id = 'gold_001', level = 1}}}}, patch = {calculateFromAllLevels = true}}}}, {content = content})
    expect(itemPlan, itemErrors and table.concat(itemErrors, '\n'))
    local itemResult = executor.execute(itemPlan, {content = content})
    expect(itemResult.status == 'committed', 'item list result ' .. itemResult.status)
    expect(#itemRecords.mom_backend_gate_items.items == 2 and itemRecords.mom_backend_gate_items.calculateForEach,
      'item list flags/entries differ')
    print('MOM_CONTENT_BACKEND_GATE:ITEMS supported')
  else
    local itemPlan, itemErrors = planner.compile({{kind = 'leveled', payload = {
      type = 'ItemLevelledList', id = 'missing', operations = {}}}}, {content = content})
    expect(itemPlan == nil and table.concat(itemErrors, ' '):find('levelledItems.records is unavailable', 1, true),
      'missing item capability was not rejected')
    print('MOM_CONTENT_BACKEND_GATE:ITEMS unavailable')
  end
  content.gameSettings.records.sMOMContentBackendGate = 'passed'
  print('MOM_CONTENT_BACKEND_GATE:LOAD passed changed=' .. result.changedCount)
end
return {engineHandlers = {onContentFilesLoaded = run}}
"""

GLOBAL = r"""
local core = require('openmw.core')
local types = require('openmw.types')
local done = false
return {engineHandlers = {onUpdate = function()
  if done then return end
  done = true
  assert(core.getGMST('sMOMContentBackendGate') == 'passed', 'LOAD backend gate did not complete')
  assert(types.Static.records.mom_backend_gate_created.id == 'mom_backend_gate_created', 'created content not visible to GLOBAL')
  assert(types.Book.records.mom_backend_gate_book.text == 'MOM content backend native text', 'book patch unavailable in GLOBAL')
  assert(types.Light.records.mom_backend_gate_light.radius == 777, 'light patch unavailable in GLOBAL')
  print('MOM_CONTENT_BACKEND_GATE:PASSED')
  core.quit()
end}}
"""
MENU = r"""
local menu = require('openmw.menu')
local started = false
return {engineHandlers = {onFrame = function()
  if not started then started = true; menu.newGame({bypass = true}) end
end}}
"""


def stage_modules(generated: Path) -> dict[str, str]:
    pending = ['scripts.mom.compiler.content.compile', 'scripts.mom.compiler.content.executor']
    sources: dict[str, bytes] = {}
    while pending:
        module = pending.pop()
        if module in sources:
            continue
        relative = Path(module.replace('.', '/') + '.lua')
        raw = (launch.MOM_DATA_DIR / relative).read_bytes()
        sources[module] = raw
        pending.extend(re.findall(r"require\(['\"](scripts\.mom\.[^'\"]+)['\"]\)", raw.decode()))
    for module, raw in sources.items():
        target = generated / (module.replace('.', '/') + '.lua')
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(raw)
    return {module: hashlib.sha256(raw).hexdigest() for module, raw in sorted(sources.items())}


def run(binary: Path, workdir: Path, timeout: float = 90,
        global_config: Path | None = None, base_config: Path | None = None) -> dict:
    binary = launch._resolve_executable(binary)
    workdir = launch.prepare_workdir(workdir)
    generated = workdir / 'generated-data'
    scripts = generated / 'scripts/mom_content_backend_gate'
    scripts.mkdir(parents=True)
    modules = stage_modules(generated)
    for name, body in [('load', LOAD), ('global', GLOBAL), ('menu', MENU)]:
        (scripts / f'{name}.lua').write_text(body)
    (generated / 'mom_content_backend_gate.omwscripts').write_text(
        'LOAD: scripts/mom_content_backend_gate/load.lua\n'
        'GLOBAL: scripts/mom_content_backend_gate/global.lua\n'
        'MENU: scripts/mom_content_backend_gate/menu.lua\n')
    data = launch.find_morrowind_data_dir(launch.resolve_global_config(global_config))
    launch.write_config(workdir / 'config/openmw.cfg',
                        base_config=launch.resolve_base_config(base_config, binary),
                        morrowind_data=data, user_data=workdir / 'userdata', generated_data=generated,
                        script_content=('mom_content_backend_gate.omwscripts',))
    (workdir / 'config/settings.cfg').write_text(
        '[Lua]\nunsafe stdlib access = false\nexecution time limit per call = 0\n'
        'instruction limit per call = 0\nmemory limit = 0\n[Video]\nresolution x = 640\nresolution y = 480\n')
    command = [str(binary), '--config', str(workdir / 'config'), '--replace=config',
               '--user-data', str(workdir / 'userdata')]
    with process.VirtualDisplay(workdir / 'xvfb.log') as display:
        completed = process.run_process(command, cwd=ROOT, environment={**os.environ, 'DISPLAY': display},
                                        stdout_path=workdir / 'stdout.log', stderr_path=workdir / 'stderr.log',
                                        timeout_seconds=timeout, termination_grace_seconds=3)
    log_path = workdir / 'config/openmw.log'
    log = log_path.read_text(errors='replace') if log_path.exists() else ''
    result = {'schemaVersion': 1, 'binary': str(binary), 'binarySha256': artifacts.sha256_file(binary),
              'workdir': str(workdir), 'command': command, 'modules': modules, **completed,
              'passed': bool(completed['returnCode'] == 0 and not completed['timedOut']
                             and log.count(MARKER) == 1 and 'MOM_CONTENT_BACKEND_GATE:LOAD passed' in log),
              'itemListsSupported': 'MOM_CONTENT_BACKEND_GATE:ITEMS supported' in log}
    artifacts.write_json(workdir / 'result.json', result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--openmw', type=Path, required=True)
    parser.add_argument('--workdir', type=Path, default=launch.default_workdir('content-backend-gate'))
    parser.add_argument('--global-config', type=Path)
    parser.add_argument('--openmw-base-config', type=Path)
    parser.add_argument('--timeout', type=float, default=90)
    arguments = parser.parse_args()
    with process.cancellation_signals():
        result = run(arguments.openmw, arguments.workdir, arguments.timeout,
                     arguments.global_config, arguments.openmw_base_config)
    print(json.dumps(result, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (ValueError, OSError, subprocess.SubprocessError, launch.LaunchError, process.ProcessError) as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(2)
