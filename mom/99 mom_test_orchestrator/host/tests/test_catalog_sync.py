from __future__ import annotations

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


HOST_ROOT = Path(__file__).resolve().parents[1]
HARNESS_ROOT = HOST_ROOT.parent
REPOSITORY_ROOT = HARNESS_ROOT.parent.parent
sys.path.insert(0, str(HOST_ROOT))

import scenario_inventory


class CatalogSynchronizationTests(unittest.TestCase):
    def lua(self) -> str:
        executable = shutil.which("lua")
        if executable is None:
            self.skipTest("system Lua is unavailable")
        return executable

    def test_lua_cases_match_generated_host_catalog_bytes(self) -> None:
        completed = subprocess.run(
            [self.lua(), str(HARNESS_ROOT / "performance" / "catalog.lua"), str(REPOSITORY_ROOT)],
            check=True,
            stdout=subprocess.PIPE,
            text=True,
            timeout=30,
        )
        generated = completed.stdout
        declared = (
            HARNESS_ROOT / "performance" / "workloads.json"
        ).read_text(encoding="utf-8")
        self.assertEqual(generated, declared)

    def test_protocol_distinguishes_empty_objects_and_arrays(self) -> None:
        script = """
local protocol = require('scripts.mom_test_orchestrator.performance.protocol')
io.write(protocol.encode({array = protocol.array(), object = protocol.object()}))
"""
        environment = dict(os.environ)
        environment["LUA_PATH"] = f"{HARNESS_ROOT}/?.lua;;"
        completed = subprocess.run(
            [self.lua(), "-e", script],
            check=True,
            env=environment,
            stdout=subprocess.PIPE,
            text=True,
            timeout=30,
        )
        self.assertEqual(json.loads(completed.stdout), {"array": [], "object": {}})

    def test_algorithmic_workloads_have_family_scoped_contract_sources(self) -> None:
        catalog = json.loads(
            (HARNESS_ROOT / "performance" / "workloads.json").read_text(
                encoding="utf-8"
            )
        )
        family_sources = {
            "runtime": "algorithmic/runtime.lua",
            "compiler": "algorithmic/compiler.lua",
            "static": "algorithmic/static.lua",
            "persistence": "algorithmic/persistence.lua",
            "container": "algorithmic/container.lua",
        }
        observed: set[str] = set()
        for workload in catalog["workloads"]:
            if "integration" in workload["modes"]:
                continue
            matched = [
                family
                for family, suffix in family_sources.items()
                if any(
                    source.endswith(suffix)
                    for source in workload["contractSources"]
                )
            ]
            self.assertEqual(len(matched), 1, workload["id"])
            observed.update(matched)
        self.assertEqual(observed, set(family_sources))

    def test_fixture_selection_is_scoped_and_preserves_campaign_sources(self) -> None:
        catalog = scenario_inventory.load_catalog(HARNESS_ROOT, self.lua())
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            paths = catalog.stage(HARNESS_ROOT, root, ["targeting_duplicates"])
            expected = "scripts/mom/config/balmora_targeting_duplicates_example.yaml"
            self.assertEqual(paths, [expected])
            self.assertEqual((root / expected).read_bytes(),
                             (HARNESS_ROOT / "fixtures/data" / expected).read_bytes())
            self.assertFalse((root / "MWSE").exists())
        ordinary_paths = {path for id in catalog.select([], []) for path in catalog.fixtures[id]}
        self.assertFalse(any("campaign" in path or "stress" in path
                             or "broad_static" in path for path in ordinary_paths))
        for phase in ("campaign_reversible_setup", "campaign_reversible_verify"):
            self.assertEqual(catalog.fixtures[phase],
                             ["scripts/mom/config/process_boundary_guard_campaign.yaml"])
        self.assertEqual(catalog.fixtures["campaign_static_baseline"], [])
        declared = {path for paths in catalog.fixtures.values() for path in paths}
        stored = {str(path.relative_to(HARNESS_ROOT / "fixtures/data"))
                  for path in (HARNESS_ROOT / "fixtures/data").rglob("*") if path.is_file()}
        self.assertEqual(declared, stored)
        self.assertEqual(catalog.suites["all"], catalog.groups["ordinary"] + catalog.groups["stress"])
        for scenarios, suites in ((["unknown"], []), ([], ["unknown"]),
                                   (["cell_exclude", "cell_exclude"], [])):
            with self.assertRaises(scenario_inventory.ScenarioInventoryError):
                catalog.select(scenarios, suites)

    def test_registered_scenarios_and_suites_have_implementations(self) -> None:
        catalog = scenario_inventory.load_catalog(
            HARNESS_ROOT,
            self.lua(),
        )
        scenario_root = HARNESS_ROOT / "scripts/mom_test_orchestrator/scenarios"
        implemented = {path.stem for path in scenario_root.glob("*.lua")}
        registered = [identifier for group in catalog.groups.values() for identifier in group]
        self.assertEqual(len(registered), len(set(registered)))
        self.assertEqual(set(registered), implemented)
        for name, identifiers in catalog.suites.items():
            with self.subTest(suite=name):
                self.assertTrue(identifiers)
                self.assertEqual(len(identifiers), len(set(identifiers)))
                self.assertLessEqual(set(identifiers), implemented)
                self.assertTrue(set(identifiers).isdisjoint(catalog.groups["campaign"]))
        self.assertEqual(catalog.select([], []), catalog.groups["ordinary"])
        self.assertEqual(catalog.suites["ordinary"], catalog.groups["ordinary"])
        self.assertEqual(catalog.suites["stress"], catalog.groups["stress"])


if __name__ == "__main__":
    unittest.main()
