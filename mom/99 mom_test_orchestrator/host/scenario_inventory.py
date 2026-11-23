from __future__ import annotations

from dataclasses import dataclass
import os
from pathlib import Path
import shutil
import subprocess


class ScenarioInventoryError(RuntimeError):
    pass


@dataclass(frozen=True)
class ScenarioCatalog:
    groups: dict[str, list[str]]
    suites: dict[str, list[str]]
    fixtures: dict[str, list[str]]
    integration: list[str]

    def select(self, scenarios: list[str], suites: list[str]) -> list[str]:
        selected = list(scenarios)
        for suite in suites:
            if suite not in self.suites:
                raise ScenarioInventoryError(f"unknown suite: {suite}")
            selected.extend(self.suites[suite])
        if not selected:
            selected = self.groups["ordinary"].copy()
        if len(selected) != len(set(selected)):
            raise ScenarioInventoryError("scenario selection contains duplicates")
        unknown = set(selected) - self.fixtures.keys()
        if unknown:
            raise ScenarioInventoryError(f"unknown scenarios: {', '.join(sorted(unknown))}")
        return selected

    def stage(self, harness_root: Path, generated_data: Path, scenarios: list[str]) -> list[str]:
        paths = sorted({path for id in scenarios for path in self.fixtures[id]})
        for path in paths:
            destination = generated_data / path
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(harness_root / "fixtures" / "data" / path, destination)
        return paths


def load_catalog(harness_root: Path, lua: str = "lua") -> ScenarioCatalog:
    executable = shutil.which(lua)
    if executable is None:
        raise ScenarioInventoryError(f"Lua executable is unavailable: {lua}")
    script = """
local catalog = require('scripts.mom_test_orchestrator.scenario_inventory')
for _, group in ipairs({'campaign', 'ordinary', 'stress'}) do
  for _, id in ipairs(catalog[group]) do
    io.write('scenario\\t', group, '\\t', id, '\\n')
    assert(catalog.fixtures[id], 'missing fixture declaration: ' .. id)
    for _, path in ipairs(catalog.fixtures[id]) do
      io.write('fixture\\t', id, '\\t', path, '\\n')
    end
  end
end
for _, suite in ipairs({'ordinary', 'smoke', 'stress', 'all'}) do
  for _, id in ipairs(catalog.suites[suite]) do
    io.write('suite\\t', suite, '\\t', id, '\\n')
  end
end
for _, id in ipairs(catalog.integration) do io.write('integration\\t', id, '\\n') end
"""
    environment = dict(os.environ)
    environment["LUA_PATH"] = f"{harness_root}/?.lua;;"
    completed = subprocess.run(
        [executable, "-e", script], check=False, env=environment,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=30,
    )
    if completed.returncode != 0:
        raise ScenarioInventoryError(
            f"scenario catalog load failed: {completed.stderr.strip()}"
        )
    groups = {group: [] for group in ("campaign", "ordinary", "stress")}
    suites: dict[str, list[str]] = {}
    fixtures: dict[str, list[str]] = {}
    integration: list[str] = []
    for line in completed.stdout.splitlines():
        row = line.split("\t")
        if len(row) == 3 and row[0] == "scenario":
            _, group, id = row
            if group not in groups or not id.isidentifier() or id in fixtures:
                raise ScenarioInventoryError(f"invalid scenario: {line!r}")
            groups[group].append(id)
            fixtures[id] = []
        elif len(row) == 3 and row[0] == "fixture":
            _, id, path = row
            relative = Path(path)
            if (id not in fixtures or relative.is_absolute() or ".." in relative.parts
                    or not (harness_root / "fixtures/data" / relative).is_file()):
                raise ScenarioInventoryError(f"invalid fixture: {line!r}")
            fixtures[id].append(path)
        elif len(row) == 3 and row[0] == "suite" and row[2] in fixtures:
            suites.setdefault(row[1], []).append(row[2])
        elif len(row) == 2 and row[0] == "integration" and row[1] in fixtures:
            integration.append(row[1])
        else:
            raise ScenarioInventoryError(f"invalid catalog row: {line!r}")
    if not all(groups.values()):
        raise ScenarioInventoryError("scenario catalog contains an empty group")
    return ScenarioCatalog(groups, suites, fixtures, integration)
