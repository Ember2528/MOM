"""Check the real shared compiler through reloadlua, reset and two save slots.

Profiles freeze production bytes and enable mom.omwscripts. A host worker edits
the same mixed YAML between activations for the two input-change cases; no
production module or engine API is replaced.
"""
from __future__ import annotations

import argparse
import json
import math
import os
from pathlib import Path
import re
import shutil
import threading

import artifacts
import examples
import launch
import process

ROOT = Path(__file__).resolve().parents[3]
MARKER = "MOM_SHARED_PHASE_GATE:"
CASES = ("success", "invalid_content", "invalid_runtime", "later_override",
         "missing_status", "malformed_status", "global_input_changed", "load_input_changed")
CONFIG = "scripts/mom/config/shared_lifecycle.yaml"
READY = "scripts/mom_shared_phase_gate/host_ready.txt"


def fixture(case: str) -> dict:
    actions = [
        {"record": {"type": "Book", "id": "bk_lustyargonianmaid", "patch": {
            "name": "Shared compiler book", "text": "LOAD definition text.", "weight": 0.25}}},
        {"record": {"type": "Static", "id": "mom_shared_named_static", "create": True,
                    "template": "furn_de_tapestry_04", "patch": {"model": "meshes/f/furn_de_tapestry_03.nif"}}},
        {"select": {"type": "Static"}, "disableOriginal": True,
         "attach": [["*", "meshes/f/furn_de_tapestry_03.nif", "meshes/f/furn_de_tapestry_04.nif"]]},
        {"place": [["Balmora, Eight Plates", "mom_shared_named_static", [12345, 12345, 12345], {}]]},
    ]
    if case == "invalid_content":
        actions[0]["record"]["patch"]["weight"] = "invalid"
    if case == "invalid_runtime":
        actions.append({"modify": [["Balmora, Eight Plates", "urn_01", {"invalid_field": True}]]})
    return {"version": 0, "variants": {"shared": {
        "requires": ["Morrowind.esm"],
        "requiresAny": ["Tribunal.esm", "mom_missing_phase_fixture.esp"],
        "requiresNot": ["mom_missing_phase_fixture.esp"],
        "actions": actions}}}


BEFORE = r"""
local content = require('openmw.content')
return {engineHandlers = {onContentFilesLoaded = function()
  local records, book = content.gameSettings.records, content.books.records.bk_lustyargonianmaid
  records.iMOMSharedLoadPasses = (records.iMOMSharedLoadPasses or 0) + 1
  records.sMOMSharedOriginalName, records.sMOMSharedOriginalText = book.name, book.text
  records.fMOMSharedOriginalWeight = book.weight
  records.sMOMSharedIngredientModel = content.ingredients.records.ingred_marshmerrow_01.model
end}}
"""


def after_script(case: str) -> str:
    changes = ""
    if case == "later_override":
        changes = """
  content.books.records.bk_lustyargonianmaid = {
    template = content.books.records.bk_lustyargonianmaid, name = 'Later LOAD owner'}
  content.statics.records.furn_de_tapestry_03 = {
    template = content.statics.records.furn_de_tapestry_03, model = 'meshes/f/furn_de_tapestry_03.nif'}
"""
    elif case in {"missing_status", "malformed_status"}:
        value = "nil" if case == "missing_status" else "'invalid status'"
        changes = f"  content.gameSettings.records[require('scripts.mom.compiler.load_status').KEY] = {value}\n"
    return "local content = require('openmw.content')\nreturn {engineHandlers = {onContentFilesLoaded = function()\n" + changes + "end}}\n"


def checker_script(case: str) -> str:
    return "local case = " + examples.lua_string(case) + "\n" + r"""
local core, world, types = require('openmw.core'), require('openmw.world'), require('openmw.types')
local I, util, storage = require('openmw.interfaces'), require('openmw.util'), require('openmw.storage')
local model = require('scripts.mom.contracts.model_path')
local state = storage.globalSection('MOMSharedPhaseGate')
state:setLifeTime(storage.LIFE_TIME.GameSession)
local tag, event, frames, checked, teleported = 1, 'init', 0, false, false
local function count(cell)
  local total = 0
  for _, object in ipairs(cell:getAll()) do
    if object.recordId == 'mom_shared_named_static'
        and (math.abs(object.position.x - 12345) < 0.01 or math.abs(object.position.x - 12346) < 0.01)
        and math.abs(object.position.y - 12345) < 0.01 and math.abs(object.position.z - 12345) < 0.01 then
      total = total + 1
    end
  end
  return total
end
local function expected(index)
  if case == 'success' or case == 'later_override' or case == 'global_input_changed'
      or (case == 'load_input_changed' and index == 1) then
    return true, case == 'global_input_changed' and index > 1 and 2 or 1
  end
  -- The two old save slots retain their pre-change output; rejection cannot
  -- erase an existing world effect, but must not admit another placement.
  return false, case == 'load_input_changed' and index > 2 and 1 or 0
end
local function check(player, index)
  local report, selfcheck = assert(I.MOM.compileReport({log = false})), assert(I.MOM.selfcheck())
  local running, outputs = expected(index)
  assert((report.status == 'running') == running and selfcheck.ok == running, 'wrong runtime activation outcome')
  assert(count(player.cell) == outputs, 'runtime output missing, duplicated or admitted after failure')
  assert(core.getGMST('iMOMSharedLoadPasses') == 1, 'LOAD repeated across activations')
  local book, named = types.Book.records.bk_lustyargonianmaid, types.Static.records.mom_shared_named_static
  local ingredient = assert(types.Ingredient.records.ingred_marshmerrow_01)
  if case == 'invalid_content' then
    assert(ingredient.model == core.getGMST('sMOMSharedIngredientModel'), 'rejected native payload admitted foreign content')
    assert(book.name == core.getGMST('sMOMSharedOriginalName') and book.text == core.getGMST('sMOMSharedOriginalText')
      and book.weight == core.getGMST('fMOMSharedOriginalWeight') and named == nil, 'failed validation changed content')
  else
    assert(book.name == (case == 'later_override' and 'Later LOAD owner' or 'Shared compiler book')
      and book.text == 'LOAD definition text.' and book.weight == 0.25, 'LOAD content changed/reapplied')
    assert(named and model.normalize(named.model) == 'meshes/f/furn_de_tapestry_03.nif', 'named record missing')
    assert(ingredient.id == 'ingred_marshmerrow_01' and model.normalize(ingredient.model) == 'meshes/f/furn_de_tapestry_03.nif',
      'ordinary foreign Ingredient replacement did not promote')
    local ratFound = false
    for _, entry in ipairs(types.LevelledCreature.records['ex_westgash_lev+0'].creatures) do
      if entry.id == 'rat' then assert(entry.level == 65534, 'foreign list edit lost its level'); ratFound = true end
    end
    assert(ratFound, 'foreign list declaration never reached the shared content plan')
    assert(model.normalize(types.Static.records.furn_de_tapestry_03.model)
      == (case == 'later_override' and 'meshes/f/furn_de_tapestry_03.nif' or 'meshes/f/furn_de_tapestry_04.nif'),
      'GLOBAL reclassified or reasserted the typed uniform model action')
  end
  local startup = report.startup
  if case == 'missing_status' or case == 'malformed_status' then
    assert(startup == nil, 'invalid status became a public success report')
  elseif case == 'invalid_content' then
    assert(startup and startup.status == 'failed' and startup.content.status == 'rejected')
  else
    assert(startup and startup.status == 'ready' and startup.content.status == 'committed')
    assert(startup.content.changedCount == 5 and startup.content.createdCount == 1 and startup.content.attemptedWrites == 5)
    assert(#startup.message <= 2048 and startup.promotions == nil and startup.targets == nil, 'unbounded/routing handoff leaked')
    local oldHash, writes = state:get('sourceHash'), state:get('writes')
    if oldHash == nil then state:set('sourceHash', startup.sourceHash); state:set('writes', startup.content.attemptedWrites)
    else assert(oldHash == startup.sourceHash and writes == startup.content.attemptedWrites, 'LOAD status changed/repeated') end
  end
  if case == 'load_input_changed' and index > 1 then
    assert(report.lastRejected and report.lastRejected.fatal.code == 'load_input_changed', 'changed LOAD input was not diagnosed')
  end
  state:set('activation', index); state:set('ready', index); state:set('tag', tag)
  print(string.format('MOM_SHARED_PHASE_GATE:CHECKED case=%s index=%d event=%s tag=%d', case, index, event, tag))
end
local function update()
  if checked then return end
  frames = frames + 1
  local player = world.players[1]
  if not player or not player.cell then return end
  if not teleported then
    player:teleport('Balmora, Eight Plates', util.vector3(960.696, 1020.348, -256)); teleported = true; return
  end
  if player.cell.name ~= 'Balmora, Eight Plates' or frames < 60 then return end
  local index = (state:get('activation') or 0) + 1
  local _, outputs = expected(index)
  if count(player.cell) ~= outputs and frames < 1200 then return end
  checked = true
  local ok, err = pcall(check, player, index)
  if not ok then print('MOM_SHARED_PHASE_GATE:FAILED case=' .. case .. ' ' .. tostring(err)); core.quit() end
end
return {engineHandlers = {
  onInit = function() tag = 1; event = 'init' end,
  onLoad = function(saved) tag = type(saved) == 'table' and saved.tag or 1; event = 'load' end,
  onSave = function() return {tag = tag} end,
  onUpdate = update,
}, eventHandlers = {MOMSharedPhaseTag = function(data) tag = data.tag; state:set('tag', tag) end}}
"""


def menu_script(case: str) -> str:
    return "local hostChange = " + ("true" if case.endswith("input_changed") else "false") + "\n" + r"""
local menu, core, storage = require('openmw.menu'), require('openmw.core'), require('openmw.storage')
local vfs = require('openmw.vfs')
local control = storage.playerSection('MOMSharedPhaseMenu')
control:setLifeTime(storage.LIFE_TIME.GameSession)
local frames = 0
local function findSave(description)
  local matches = {}
  for directory, saves in pairs(menu.getAllSaves()) do
    for slot, info in pairs(saves) do
      if info.description == description then matches[#matches + 1] = {directory, slot} end
    end
  end
  assert(#matches == 1, 'expected one save: ' .. description)
  return matches[1]
end
local function run()
  if menu.getState() ~= menu.STATE.Running then return end
  frames = frames + 1
  if frames < 5 then return end
  local state = storage.globalSection('MOMSharedPhaseGate')
  local ready, phase = state:get('ready') or 0, control:get('phase') or 0
  if ready == 0 then return end
  if phase == 0 then menu.saveGame('MOM shared compiler A'); control:set('phase', 1)
  elseif phase == 1 then
    control:set('saveA', findSave('MOM shared compiler A')); core.sendGlobalEvent('MOMSharedPhaseTag', {tag = 2}); control:set('phase', 2)
  elseif phase == 2 then
    if state:get('tag') ~= 2 then return end
    menu.saveGame('MOM shared compiler B'); control:set('phase', 3)
  elseif phase == 3 then
    if hostChange then
      local file = assert(vfs.open('scripts/mom_shared_phase_gate/host_ready.txt'))
      local readyText = file:read('*all'); file:close()
      if readyText ~= 'changed' then return end
    end
    control:set('saveB', findSave('MOM shared compiler B')); control:set('previous', ready)
    control:set('phase', 4); menu.newGame({bypass = true})
  elseif phase == 4 then
    if ready <= control:get('previous') then return end
    assert(state:get('tag') == 1, 'reset kept previous save state')
    local save = control:get('saveA'); control:set('previous', ready); control:set('phase', 5); menu.loadGame(save[1], save[2])
  elseif phase == 5 then
    if ready <= control:get('previous') then return end
    assert(state:get('tag') == 1, 'save A was not restored')
    local save = control:get('saveB'); control:set('previous', ready); control:set('phase', 6); menu.loadGame(save[1], save[2])
  elseif phase == 6 then
    if ready <= control:get('previous') then return end
    assert(state:get('tag') == 2, 'save B was not restored')
    print('MOM_SHARED_PHASE_GATE:PASSED activations=' .. tostring(ready)); menu.quit()
  end
  frames = 0
end
return {engineHandlers = {onFrame = run}}
"""


def freeze_production(destination: Path) -> dict[str, str]:
    hashes = {}
    for source in sorted(launch.MOM_DATA_DIR.rglob("*")):
        if source.is_file() and source.suffix in {".lua", ".omwscripts"}:
            relative = source.relative_to(launch.MOM_DATA_DIR)
            target = destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(source.read_bytes())
            hashes[relative.as_posix()] = artifacts.sha256_file(target)
    return hashes


def stage_case(destination: Path, case: str) -> None:
    scripts = destination / "scripts/mom_shared_phase_gate"
    scripts.mkdir(parents=True, exist_ok=True)
    for name, body in (("before", BEFORE), ("after", after_script(case)),
                       ("global", checker_script(case)), ("menu", menu_script(case))):
        (scripts / f"{name}.lua").write_text(body)
    (destination / READY).write_text("pending")
    (destination / "mom_shared_before.omwscripts").write_text("LOAD: scripts/mom_shared_phase_gate/before.lua\n")
    (destination / "mom_shared_after.omwscripts").write_text(
        "LOAD: scripts/mom_shared_phase_gate/after.lua\nGLOBAL: scripts/mom_shared_phase_gate/global.lua\n"
        "MENU: scripts/mom_shared_phase_gate/menu.lua\n")
    config = destination / CONFIG
    config.parent.mkdir(parents=True, exist_ok=True)
    config.write_text(json.dumps(fixture(case)))
    imported = destination / 'scripts/variationframework/banners/data/shared_ingredient.yaml'
    imported.parent.mkdir(parents=True, exist_ok=True)
    imported.write_text(json.dumps({'kinds': ['Ingredient'],
        'record_variants': {'ingred_marshmerrow_01': {'meshes': ['f/furn_de_tapestry_03.nif']}},
        'weights': {'default': [0, 1]}}))
    lists = destination / 'scripts/variationframework/leveled_creatures/data/shared_list.yaml'
    lists.parent.mkdir(parents=True, exist_ok=True)
    lists.write_text(json.dumps({'require_content': 'Morrowind.esm', 'injections': [
        {'list': 'ex_westgash_lev+0', 'add': [{'id': 'rat', 'level': 65534}]}]}))



def validate_log(log: str, case: str, return_code: int) -> dict:
    checks = re.findall(re.escape(MARKER) + r"CHECKED case=(\w+) index=(\d+) event=(\w+) tag=(\d+)", log)
    expected = [(case, str(i), event, str(tag)) for i, (event, tag) in enumerate(
        (("load", 1), ("init", 1), ("load", 1), ("load", 2)), 1)]
    receipts = re.findall(re.escape(MARKER) + r"PASSED activations=(\d+)", log)
    reloaded = bool(re.search(r"Reload(?:ing)? Lua(?: scripts)?|reloadlua", log, re.I))
    publications = len(re.findall(r"\[MOM\]\[INFO\]\[content\] (?:committed|noop)\b", log))
    passed = (return_code == 0 and checks == expected and receipts == ["4"] and reloaded
              and MARKER + "FAILED" not in log and publications == (0 if case == "invalid_content" else 1))
    return {"passed": passed, "checks": len(checks), "reloadObserved": reloaded, "contentPublications": publications}


def mutate_input(generated: Path, case: str) -> None:
    path = generated / CONFIG
    document = json.loads(path.read_text())
    actions = document["variants"]["shared"]["actions"]
    if case == "global_input_changed":
        actions.append({"place": [["Balmora, Eight Plates", "mom_shared_named_static", [12346, 12345, 12345], {}]]})
    else:
        actions[0]["record"]["patch"]["name"] = "Changed LOAD name"
    artifacts.atomic_write(path, json.dumps(document).encode())
    artifacts.atomic_write(generated / READY, b"changed")


def run_case(binary: Path, workdir: Path, case: str, frozen: Path, args: argparse.Namespace) -> dict:
    launch.prepare_workdir(workdir)
    generated = workdir / "generated-data"
    shutil.copytree(frozen, generated, dirs_exist_ok=True)
    stage_case(generated, case)
    data = launch.find_morrowind_data_dir(launch.resolve_global_config(args.global_config))
    launch.write_config(workdir / "config/openmw.cfg", base_config=launch.resolve_base_config(args.openmw_base_config, binary),
                        morrowind_data=data, user_data=workdir / "userdata", generated_data=generated,
                        script_content=("mom_shared_before.omwscripts", "mom.omwscripts", "mom_shared_after.omwscripts"))
    (workdir / "config/settings.cfg").write_text(
        "[Lua]\nunsafe stdlib access = false\nexecution time limit per call = 0\n"
        "instruction limit per call = 0\nmemory limit = 0\n[Video]\nresolution x = 640\nresolution y = 480\n")
    console = workdir / "reload-console.txt"
    console.write_text("reloadlua\n")
    command = [str(binary), "--config", str(workdir / "config"), "--replace=config", "--user-data",
               str(workdir / "userdata"), "--script-run", str(console)]
    log_path = workdir / "config/openmw.log"
    stop, mutation = threading.Event(), []

    def change_after_first_activation() -> None:
        while not stop.wait(0.01):
            if log_path.exists() and MARKER + f"CHECKED case={case} index=1 " in log_path.read_text(errors="replace"):
                mutate_input(generated, case)
                mutation.append(True)
                return

    worker = threading.Thread(target=change_after_first_activation, daemon=True) if case.endswith("input_changed") else None
    if worker:
        worker.start()
    try:
        with process.VirtualDisplay(workdir / "xvfb.log") as display:
            completed = process.run_process(command, cwd=ROOT, environment={**os.environ, "DISPLAY": display},
                                            stdout_path=workdir / "stdout.log", stderr_path=workdir / "stderr.log",
                                            timeout_seconds=args.timeout, termination_grace_seconds=3)
    finally:
        stop.set()
        if worker:
            worker.join(timeout=2)
    log = log_path.read_text(errors="replace") if log_path.exists() else ""
    result = {"case": case, "workdir": str(workdir), "process": completed, "sourceMutated": bool(mutation),
              **validate_log(log, case, int(completed["returnCode"]))}
    result["passed"] = result["passed"] and not completed["timedOut"] and (worker is None or bool(mutation))
    artifacts.write_json(workdir / "result.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--openmw", type=Path, required=True)
    parser.add_argument("--workdir", type=Path, default=launch.default_workdir("content-lifecycle"))
    parser.add_argument("--global-config", type=Path)
    parser.add_argument("--openmw-base-config", type=Path)
    parser.add_argument("--case", action="append", choices=CASES)
    parser.add_argument("--timeout", type=float, default=60)
    args = parser.parse_args()
    if not math.isfinite(args.timeout) or args.timeout <= 0:
        parser.error("timeout must be finite and positive")
    if args.case and len(set(args.case)) != len(args.case):
        parser.error("select each case only once")
    root, binary = args.workdir.resolve(), args.openmw.resolve(strict=True)
    root.mkdir(parents=True, exist_ok=False)
    frozen = root / "frozen-production"
    hashes = freeze_production(frozen)
    selected, rows = args.case or CASES, []
    for case in selected:
        row = run_case(binary, root / case, case, frozen, args)
        rows.append(row)
        print(f"{case}: passed={row['passed']} checks={row['checks']} evidence={row['workdir']}", flush=True)
        if not row["passed"]:
            break
    passed = len(rows) == len(selected) and all(row["passed"] for row in rows)
    artifacts.write_json(root / "result.json", {"passed": passed, "binary": str(binary),
        "binarySha256": artifacts.sha256_file(binary), "production": hashes, "cases": rows})
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
