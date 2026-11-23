"""Record absolute shared-compiler startup costs; no regression thresholds or GC lane."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import statistics
import sys

import artifacts
import launch
import process

ROOT = Path(__file__).resolve().parents[3]
PROFILES = {"small": (2, 0, 1, 5, False), "runtime": (0, 0, 0, 1000, False),
            "content": (750, 0, 250, 0, False), "mixed": (250, 100, 100, 500, True)}
NEW_MODEL = "meshes/f/furn_de_tapestry_03.nif"
CAPTURE = """import json,resource,subprocess,sys
from pathlib import Path
p=subprocess.run(sys.argv[2:])
Path(sys.argv[1]).write_text(json.dumps({'peakRssBytes':resource.getrusage(resource.RUSAGE_CHILDREN).ru_maxrss*1024}))
sys.exit(p.returncode)
"""
LOAD = r"""
local content, core = require('openmw.content'), require('openmw.core')
local facade, sources = require('scripts.mom.compiler.startup_compile'), require('scripts.mom.compiler.config_sources')
local aggregate, executor = require('scripts.mom.compiler.bootstrap_config'), require('scripts.mom.compiler.content.executor')
local stats, reads = {passes=0, compiles=0, executes=0, writes=0}, {}
local loadRaw, loadAggregated, compile, execute = sources.loadRaw, aggregate.loadAggregated, facade.compile, executor.execute
sources.loadRaw = function(source, ...)
  reads[source.path] = (reads[source.path] or 0) + 1; return loadRaw(source, ...)
end
aggregate.loadAggregated = function(...) stats.passes=stats.passes+1; return loadAggregated(...) end
facade.compile = function(...)
  stats.compiles=stats.compiles+1; print('MOM_CONTENT_PROFILE:COMPILE_BEGIN'); local value=compile(...)
  print('MOM_CONTENT_PROFILE:COMPILE_END'); return value
end
executor.execute = function(plan, options)
  stats.executes=stats.executes+1
  local wrapped = {}
  for _, definition in pairs(require('scripts.mom.contracts.content_types')) do
    local ok, namespace=pcall(function() return options.content[definition.namespace] end)
    if ok and namespace then
      local records=namespace.records
      wrapped[definition.namespace]={records=setmetatable({}, {__index=function(_, id) return records[id] end,
        __newindex=function(_, id, value) stats.writes=stats.writes+1; records[id]=value end})}
    end
  end
  options.content=wrapped; print('MOM_CONTENT_PROFILE:EXECUTE_BEGIN'); local value=execute(plan, options)
  print('MOM_CONTENT_PROFILE:EXECUTE_END'); return value
end
return {engineHandlers={onContentFilesLoaded=function()
  -- Identical fixture construction is outside the LOAD bracket/write counters.
  local static, book, list=content.statics.records.furn_de_tapestry_04, content.books.records[1], content.levelledCreatures.records[1]
  for i=1, recordCount do content.statics.records['mom_profile_static_'..i]=static end
  for i=1, bookCount do content.books.records['mom_profile_book_'..i]=book end
  for i=1, listCount do content.levelledCreatures.records['mom_profile_list_'..i]={template=list,
    creatures={{id='rat',level=1}},chanceNone=0.37} end
  if uniform then content.statics.records.mom_profile_uniform=static end
  content.gameSettings.records.iMOMProfileLoadCalls=(content.gameSettings.records.iMOMProfileLoadCalls or 0)+1
  print('MOM_CONTENT_PROFILE:TOTAL_BEGIN'); local status, failure=facade.load({vfr=false})
  print('MOM_CONTENT_PROFILE:TOTAL_END'); assert(status, failure)
  local count=0; for _, n in pairs(reads) do assert(n==1,'LOAD source read repeated'); count=count+n end
  assert(count==4 and stats.passes==1 and stats.compiles==1 and stats.executes==1)
  assert(status.content.changedCount==expectedContent and stats.writes==expectedContent*5,'unexpected native writes')
  print(string.format('MOM_CONTENT_PROFILE:LOAD reads=%d passes=%d writes=%d changed=%d hash=%s',
    count,stats.passes,stats.writes,status.content.changedCount,status.sourceHash))
end}}
"""
GLOBAL = r"""
local core, facade = require('openmw.core'), require('scripts.mom.compiler.startup_compile')
local sources, aggregate = require('scripts.mom.compiler.config_sources'), require('scripts.mom.compiler.bootstrap_config')
local reads, passes, done = {}, 0, false
local loadRaw, loadAggregated=sources.loadRaw, aggregate.loadAggregated
sources.loadRaw=function(source, ...) reads[source.path]=(reads[source.path] or 0)+1; return loadRaw(source, ...) end
aggregate.loadAggregated=function(...) passes=passes+1; return loadAggregated(...) end
local function run()
  if done then return end; done=true
  local t=core.getRealTime(); local candidate=facade.installed({vfr=false}); local duration=core.getRealTime()-t
  assert(candidate.status=='accepted', candidate.fatal and candidate.fatal.message)
  local count=0; for _, n in pairs(reads) do assert(n==1,'GLOBAL source read repeated'); count=count+n end
  assert(count==4 and passes==1 and #candidate.manifest.actionIds==expectedRuntime,'wrong GLOBAL partition/read counts')
  assert(core.getGMST('iMOMProfileLoadCalls')==1 and candidate.loadFingerprint==candidate.startup.sourceHash)
  assert(candidate.startup.content.changedCount==expectedContent,'content result changed between contexts')
  print(string.format('MOM_CONTENT_PROFILE:GLOBAL compile=%.9f reads=%d passes=%d actions=%d hash=%s',
    duration,count,passes,#candidate.manifest.actionIds,candidate.loadFingerprint))
end
return {engineHandlers={onUpdate=function()
  if done then return end
  local ok,err=pcall(run); if not ok then print('MOM_CONTENT_PROFILE:FAILED '..tostring(err)) end; core.quit()
end}}
"""
MENU = "local menu=require('openmw.menu'); local done=false; return {engineHandlers={onFrame=function() if not done then done=true; menu.newGame({bypass=true}) end end}}"


def stage(generated: Path, profile: str) -> dict:
    records, books, lists, runtime, uniform = PROFILES[profile]
    actions = [{"record": {"type": "Static", "id": f"mom_profile_static_{i}", "patch": {"model": NEW_MODEL}}} for i in range(1, records + 1)]
    actions += [{"record": {"type": "Book", "id": f"mom_profile_book_{i}", "patch": {"name": f"Profile book {i}", "weight": 0.25}}} for i in range(1, books + 1)]
    actions += [{"leveled": {"type": "CreatureLevelledList", "id": f"mom_profile_list_{i}", "operations": [
        {"op": "append", "entries": [{"id": "rat", "level": level}]} for level in range(1, 5)]}} for i in range(1, lists + 1)]
    if uniform:
        actions.append({"select": {"type": "Static"}, "disableOriginal": True, "attach": [["*", "mom_profile_uniform", NEW_MODEL]]})
    changed = len(actions)
    actions += [{"select": {"cell": "Balmora, Guild of Mages", "recordId": "urn_01"}, "modify": {"scale": {"to": 1 + i / 1000}}} for i in range(1, runtime + 1)]
    inputs = {}
    for i in range(4):
        path = generated / f"scripts/mom/config/profile_{i}.yaml"; path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps({"version": 0, "variants": {"profile": {"actions": actions[i::4]}}}, separators=(",", ":")))
        inputs[str(path.relative_to(generated))] = artifacts.sha256_file(path)
    header = f"local recordCount,bookCount,listCount,uniform,expectedContent,expectedRuntime={records},{books},{lists},{str(uniform).lower()},{changed},{runtime}\n"
    for name, body in (("load", LOAD), ("global", GLOBAL), ("menu", MENU)):
        path = generated / f"scripts/mom_content_profile/{name}.lua"; path.parent.mkdir(parents=True, exist_ok=True); path.write_text(header + body)
    (generated / "mom_content_profile.omwscripts").write_text("LOAD: scripts/mom_content_profile/load.lua\nGLOBAL: scripts/mom_content_profile/global.lua\nMENU: scripts/mom_content_profile/menu.lua\n")
    return {"records": records, "books": books, "lists": lists, "listOperations": lists * 4, "runtimeActions": runtime,
            "loadActions": changed, "sourceBytes": sum((generated / p).stat().st_size for p in inputs), "inputs": inputs}


def run(binary: Path, workdir: Path, frozen: Path, profile: str, sample: int, timeout: float) -> dict:
    workdir = launch.prepare_workdir(workdir); generated = workdir / "generated-data"
    shutil.copytree(frozen, generated); fixture = stage(generated, profile)
    launch.write_config(workdir / "config/openmw.cfg", base_config=launch.resolve_base_config(None, binary),
                        morrowind_data=launch.find_morrowind_data_dir(launch.resolve_global_config(None)),
                        user_data=workdir / "userdata", generated_data=generated, script_content=("mom_content_profile.omwscripts",))
    (workdir / "config/settings.cfg").write_text("[Lua]\nunsafe stdlib access = false\nexecution time limit per call = 0\ninstruction limit per call = 0\nmemory limit = 0\n[Video]\nresolution x = 640\nresolution y = 480\n")
    engine = [str(binary), "--config", str(workdir / "config"), "--replace=config", "--user-data", str(workdir / "userdata")]
    command = [sys.executable, "-c", CAPTURE, str(workdir / "peak.json"), *engine]
    with process.VirtualDisplay(workdir / "xvfb.log") as display:
        capture = process.run_process(command, cwd=ROOT, environment={**os.environ, "DISPLAY": display},
            stdout_path=workdir / "stdout.log", stderr_path=workdir / "stderr.log", timeout_seconds=timeout, termination_grace_seconds=3)
    log = (workdir / "config/openmw.log").read_text(errors="replace")
    values = {}
    for phase in ("LOAD", "GLOBAL"):
        matches = re.findall(r"MOM_CONTENT_PROFILE:" + phase + r" ([^\r\n]+)", log)
        if len(matches) == 1:
            values[phase] = {key: (value if key == "hash" else float(value)) for key, value in re.findall(r"(\w+)=([^ ]+)", matches[0])}
    if "LOAD" in values:
        for bracket in ("TOTAL", "COMPILE", "EXECUTE"):
            stamps = re.findall(r"\[(\d\d):(\d\d):(\d\d\.\d+) [^\]]+\].*MOM_CONTENT_PROFILE:" + bracket + r"_(BEGIN|END)", log)
            if len(stamps) == 2 and [v[3] for v in stamps] == ["BEGIN", "END"]:
                times = [int(h) * 3600 + int(m) * 60 + float(s) for h, m, s, _ in stamps]
                values["LOAD"][bracket.lower()] = (times[1] - times[0]) % 86400
    peak = json.loads((workdir / "peak.json").read_text()) if (workdir / "peak.json").exists() else {}
    value = {"profile": profile, "sample": sample, "fixture": fixture, "stages": values, **capture, **peak,
             "passed": capture["returnCode"] == 0 and not capture["timedOut"] and len(values) == 2 and "total" in values.get("LOAD", {})}
    artifacts.write_json(workdir / "result.json", value)
    return value


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__); parser.add_argument("--openmw", type=Path, required=True)
    parser.add_argument("--workdir", type=Path, required=True); parser.add_argument("--profile", choices=PROFILES, action="append")
    parser.add_argument("--samples", type=int, default=3); parser.add_argument("--timeout", type=float, default=90)
    args = parser.parse_args(); binary = launch._resolve_executable(args.openmw); root = launch.prepare_workdir(args.workdir)
    if args.samples < 1: parser.error("samples must be positive")
    frozen = root / "frozen"; modules = {}
    for path in sorted((launch.MOM_DATA_DIR / "scripts/mom").rglob("*.lua")):
        relative = path.relative_to(launch.MOM_DATA_DIR); target = frozen / relative
        target.parent.mkdir(parents=True, exist_ok=True); target.write_bytes(path.read_bytes()); modules[str(relative)] = artifacts.sha256_file(path)
    rows = []
    with process.cancellation_signals():
        for profile in args.profile or PROFILES:
            for sample in range(1, args.samples + 1): rows.append(run(binary, root / f"{profile}-{sample}", frozen, profile, sample, args.timeout))
    summary = {profile: {"loadSeconds": statistics.median(r["stages"]["LOAD"]["total"] for r in rows if r["profile"] == profile),
        "globalSeconds": statistics.median(r["stages"]["GLOBAL"]["compile"] for r in rows if r["profile"] == profile),
        "peakRssBytes": max(r.get("peakRssBytes", 0) for r in rows if r["profile"] == profile)} for profile in (args.profile or PROFILES) if all(r["passed"] for r in rows if r["profile"] == profile)}
    value = {"schemaVersion": 1, "binary": str(binary), "binarySha256": artifacts.sha256_file(binary), "modules": modules,
             "runs": rows, "summary": summary, "passed": all(r["passed"] for r in rows),
             "timingMethod": "LOAD engine log brackets (1 ms precision); GLOBAL core.getRealTime monotonic; seeding excluded from LOAD bracket",
             "rssMethod": "Linux per-run RUSAGE_CHILDREN ru_maxrss; whole engine process peak, not retained Lua memory"}
    artifacts.write_json(root / "result.json", value); print(json.dumps({"passed": value["passed"], "summary": summary, "result": str(root / "result.json")}))
    return 0 if value["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
