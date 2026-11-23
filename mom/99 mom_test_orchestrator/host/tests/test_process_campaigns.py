from __future__ import annotations

from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


HOST_ROOT = Path(__file__).resolve().parents[1]
HARNESS_ROOT = HOST_ROOT.parent
REPOSITORY_ROOT = HARNESS_ROOT.parent.parent
sys.path.insert(0, str(HOST_ROOT))

import process_campaigns
import scenario_inventory


class ProcessCampaignTests(unittest.TestCase):
    def test_run_resolves_one_engine_for_every_restart_phase(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            workdir = Path(directory) / "campaigns"
            engine = Path(directory) / "pinned-openmw"
            arguments = process_campaigns.parser().parse_args([
                "--workdir", str(workdir),
                "--campaign", "reversible_restart",
                "--campaign", "deferred_cleanup_restart",
                "--build-openmw",
            ])
            selected_engines: list[Path] = []

            def run_phase(**kwargs: object) -> process_campaigns.PhaseOutcome:
                settings = kwargs["settings"]
                phase = kwargs["phase"]
                campaign = kwargs["campaign"]
                selected_engines.append(settings.openmw_binary)
                result = workdir / campaign.id / f"{phase.id}.json"
                return process_campaigns.PhaseOutcome("passed", None, result)

            with (
                mock.patch.object(
                    process_campaigns.launch, "resolve_openmw_binary",
                    return_value=engine,
                ) as resolve,
                mock.patch.object(process_campaigns, "run_phase", side_effect=run_phase),
                mock.patch.object(process_campaigns, "validate_campaign_artifacts"),
            ):
                self.assertEqual(process_campaigns.run(arguments), 0)

            resolve.assert_called_once_with(
                None, work_directory=workdir, build_openmw=True,
            )
            self.assertEqual(selected_engines, [engine] * 4)

    @staticmethod
    def reference(digit: str = "a", size: int = 1) -> dict[str, object]:
        digest = digit * 64
        return {
            "object": f"objects/{digest[:2]}/{digest}",
            "sha256": digest,
            "size": size,
        }

    @classmethod
    def passing_artifacts(
        cls,
        *,
        save: dict[str, object] | None = None,
    ) -> list[dict[str, object]]:
        reference = cls.reference()
        paths = set(process_campaigns.PHASE_REQUIRED_ARTIFACTS)
        if save is not None:
            paths.add("save.omwsave")
        return [
            {
                "path": path,
                **(save if path == "save.omwsave" else reference),
            }
            for path in sorted(paths)
        ]

    @classmethod
    def phase_result(
        cls,
        *,
        phase: str = "verify",
        scenario: str = "scenario",
        mode: str = "verify",
        input_save: dict[str, object] | None = None,
        save: dict[str, object] | None = None,
    ) -> dict[str, object]:
        return {
            "schemaVersion": 2,
            "kind": "mom.process-campaign.phase",
            "status": "passed",
            "campaign": "campaign",
            "phase": phase,
            "scenario": scenario,
            "mode": mode,
            "harnessExit": 0,
            "openmwExit": 0,
            "timedOut": False,
            "durationSeconds": 1.0,
            "harnessResultKind": (
                "mom.process-campaign.phase-receipt"
                if mode == "save"
                else "mom.correctness.result"
            ),
            "inputSave": input_save,
            "artifacts": cls.passing_artifacts(save=save),
            "overlay": "",
        }

    def test_machine_results_reject_incoherent_exit_evidence(self) -> None:
        phase = self.phase_result()
        self.assertIs(phase, process_campaigns.validate_phase_result(phase))
        phase["harnessExit"] = 1
        with self.assertRaisesRegex(process_campaigns.CampaignError, "verify"):
            process_campaigns.validate_phase_result(phase)

        phase = self.phase_result(
            phase="save",
            mode="save",
            save=self.reference("b"),
        )
        self.assertIs(phase, process_campaigns.validate_phase_result(phase))
        phase["harnessExit"] = 1
        with self.assertRaisesRegex(process_campaigns.CampaignError, "save"):
            process_campaigns.validate_phase_result(phase)

        result = {
            "schemaVersion": 2,
            "kind": "mom.process-campaign.result",
            "status": "passed",
            "workdir": "/tmp/work",
            "campaigns": [{
                "id": "campaign",
                "status": "failed",
                "phases": ["campaigns/campaign/phases/01/phase-result.json"],
            }],
        }
        with self.assertRaisesRegex(process_campaigns.CampaignError, "disagrees"):
            process_campaigns.validate_campaign_result(result)

    def test_campaign_artifacts_deduplicate_and_validate_save_chain(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            base = Path(directory)
            repository = base / "repository"
            repository.mkdir()
            root = process_campaigns.prepare_workdir(
                base / "campaign-artifacts",
                repository,
            )
            scratch = base / "scratch"
            scratch.mkdir()
            evidence = scratch / "evidence"
            evidence.write_bytes(b"shared phase evidence\n")
            save = scratch / "save.omwsave"
            save.write_bytes(b"canonical OpenMW save\n")
            store = process_campaigns.artifacts.ContentStore(root)
            evidence_reference = store.put(evidence)
            save_reference = store.put(save)

            def retained(
                include_save: bool,
            ) -> list[dict[str, object]]:
                paths = set(process_campaigns.PHASE_REQUIRED_ARTIFACTS)
                if include_save:
                    paths.add("save.omwsave")
                return [
                    {
                        "path": path,
                        **(
                            save_reference
                            if path == "save.omwsave"
                            else evidence_reference
                        ),
                    }
                    for path in sorted(paths)
                ]

            setup = self.phase_result(
                phase="setup",
                scenario="campaign_reversible_setup",
                mode="save",
                save=save_reference,
            )
            setup["campaign"] = "reversible_restart"
            setup["artifacts"] = retained(True)
            verify = self.phase_result(
                phase="verify",
                scenario="campaign_reversible_verify",
                input_save=save_reference,
            )
            verify["campaign"] = "reversible_restart"
            verify["artifacts"] = retained(False)
            phase_paths = [
                "campaigns/reversible_restart/phases/01_setup/phase-result.json",
                "campaigns/reversible_restart/phases/02_verify/phase-result.json",
            ]
            process_campaigns.artifacts.write_json(root / phase_paths[0], setup)
            process_campaigns.artifacts.write_json(root / phase_paths[1], verify)
            result = {
                "schemaVersion": 2,
                "kind": "mom.process-campaign.result",
                "status": "passed",
                "workdir": str(root),
                "campaigns": [{
                    "id": "reversible_restart",
                    "status": "passed",
                    "phases": phase_paths,
                }],
            }
            self.assertIs(
                result,
                process_campaigns.validate_campaign_artifacts(result),
            )
            objects = [
                path for path in (root / "objects").rglob("*")
                if path.is_file()
            ]
            self.assertEqual(len(objects), 2)

            verify["inputSave"] = None
            process_campaigns.artifacts.write_json(root / phase_paths[1], verify)
            with self.assertRaisesRegex(
                process_campaigns.CampaignError,
                "save chain",
            ):
                process_campaigns.validate_campaign_artifacts(result)

            verify["inputSave"] = save_reference
            process_campaigns.artifacts.write_json(root / phase_paths[1], verify)
            store.resolve(save_reference).write_bytes(b"corrupt")
            with self.assertRaisesRegex(
                process_campaigns.CampaignError,
                "canonical object",
            ):
                process_campaigns.validate_campaign_artifacts(result)

    def test_campaign_phases_end_in_verification_and_have_available_overlays(self) -> None:
        process_campaigns.validate_catalog()
        for campaign in process_campaigns.CAMPAIGNS:
            with self.subTest(campaign=campaign.id):
                self.assertTrue(campaign.phases)
                self.assertEqual(campaign.phases[-1].mode, "verify")
                self.assertTrue(any(phase.mode == "save" for phase in campaign.phases))
                for phase in campaign.phases:
                    self.assertEqual(len(phase.values), len(dict(phase.values)))
                    if phase.overlay is not None:
                        overlay = process_campaigns.OVERLAY_ROOT / phase.overlay
                        self.assertTrue(overlay.is_dir(), str(overlay))
                        self.assertTrue(any(path.is_file() for path in overlay.rglob("*")))

    def test_container_campaign_covers_real_between_tick_apply_and_revert_phases(self) -> None:
        container = process_campaigns.CAMPAIGN_BY_ID["container_transfer_restart"]
        phase_ids = [phase.id for phase in container.phases]
        self.assertEqual(
            phase_ids,
            ["apply_pending", "apply_committed", "revert_pending", "verify"],
        )
        self.assertFalse(
            (HARNESS_ROOT / "scripts" / "mom" / "ledger" / "store.lua").exists()
        )

    def test_phase_scenarios_are_registered_in_engine_catalog(self) -> None:
        lua = shutil.which("lua")
        if lua is None:
            self.skipTest("system Lua is unavailable")
        registered = set(
            scenario_inventory.load_catalog(
                HARNESS_ROOT,
                lua,
            ).groups["campaign"]
        )
        declared = {
            phase.scenario
            for campaign in process_campaigns.CAMPAIGNS
            for phase in campaign.phases
        }
        self.assertEqual(registered, declared)

    def test_handoff_module_merges_phase_and_process_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            phase = process_campaigns.Phase(
                "phase",
                "scenario",
                "save",
                (("existing", "new"), ("phase.value", "value")),
            )
            handoff = {"existing": "6f6c64"}
            data_dir = process_campaigns.write_handoff_module(root, handoff, phase)
            module = (
                data_dir
                / "scripts"
                / "mom_test_orchestrator"
                / "campaign_handoff.lua"
            ).read_text(encoding="ascii")
            self.assertIn('["existing"] = "6e6577"', module)
            self.assertIn('["phase.value"] = "76616c7565"', module)

            process_log = root / "openmw.log"
            process_log.write_text(
                "[MOMCampaign][VALUE] key=created hex=76616c7565\n"
                "[MOMCampaign][VALUE] key=existing hex=66696e616c\n",
                encoding="utf-8",
            )
            process_campaigns.capture_handoff_values(process_log, handoff)
            self.assertEqual(handoff, {
                "existing": "66696e616c",
                "created": "76616c7565",
            })

    def test_workdir_preserves_completed_campaigns_and_stays_outside_repository(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            repository = root / "repository"
            repository.mkdir()

            with self.assertRaisesRegex(process_campaigns.CampaignError, "unsafe"):
                process_campaigns.prepare_workdir(
                    repository / "artifacts",
                    repository,
                )

            unmarked = root / "unmarked"
            unmarked.mkdir()
            with self.assertRaisesRegex(process_campaigns.CampaignError, "already exists"):
                process_campaigns.prepare_workdir(unmarked, repository)

            marked = process_campaigns.prepare_workdir(root / "campaigns", repository)
            (marked / "stale").write_text("value", encoding="utf-8")
            with self.assertRaisesRegex(process_campaigns.CampaignError, "already exists"):
                process_campaigns.prepare_workdir(marked, repository)
            self.assertEqual((marked / "stale").read_text(encoding="utf-8"), "value")
            self.assertTrue(
                (marked / process_campaigns.WORKDIR_MARKER).is_file()
            )

    def test_phase_command_preserves_harness_and_save_arguments(self) -> None:
        command = process_campaigns.build_phase_command(
            phase=process_campaigns.Phase("verify", "scenario", "verify"),
            harness_work=Path("/tmp/work"),
            harness_result=Path("/tmp/result.json"),
            handoff_data=Path("/tmp/handoff"),
            overlay_data=Path("/tmp/overlay"),
            input_save=Path("/tmp/input.omwsave"),
            openmw_binary=Path("/opt/openmw"),
            build_openmw=False,
            harness=Path("/tmp/run_harness.sh"),
        )
        self.assertEqual(command[:7], [
            "/tmp/run_harness.sh",
            "--workdir",
            "/tmp/work",
            "--result-file",
            "/tmp/result.json",
            "--scenario",
            "scenario",
        ])
        self.assertEqual(command[-6:], [
            "--data",
            "/tmp/handoff",
            "--data",
            "/tmp/overlay",
            "--load-savegame",
            "/tmp/input.omwsave",
        ])
        self.assertIn("--no-build-openmw", command)


if __name__ == "__main__":
    unittest.main()
