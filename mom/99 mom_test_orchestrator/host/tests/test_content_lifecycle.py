from __future__ import annotations

import json
from pathlib import Path
import sys
import tempfile
import unittest

HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST))
import content_lifecycle as gate


class ContentLifecycleTests(unittest.TestCase):
    def log(self, case: str) -> str:
        publication = '' if case == 'invalid_content' else '[MOM][INFO][content] committed\n'
        return publication + 'Reloading Lua scripts\n' + ''.join(
            f'{gate.MARKER}CHECKED case={case} index={index} event={event} tag={tag}\n'
            for index, (event, tag) in enumerate((('load', 1), ('init', 1), ('load', 1), ('load', 2)), 1)
        ) + gate.MARKER + 'PASSED activations=4\n'

    def test_receipt_requires_all_real_lifecycle_events_and_unique_publication(self) -> None:
        for case in gate.CASES:
            log = self.log(case)
            self.assertTrue(gate.validate_log(log, case, 0)['passed'])
            for bad in (log.replace('Reloading Lua scripts', ''), log.replace('index=3', 'index=2'),
                        log + gate.MARKER + 'PASSED activations=4\n', log + gate.MARKER + 'FAILED example\n',
                        log + '[MOM][INFO][content] committed\n', log.replace('event=init', 'event=load')):
                self.assertFalse(gate.validate_log(bad, case, 0)['passed'])
            self.assertFalse(gate.validate_log(log, case, 1)['passed'])

    def test_profiles_stage_one_mixed_source_and_actual_production_registration(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            gate.stage_case(root, 'success')
            config = json.loads((root / gate.CONFIG).read_text())
            actions = config['variants']['shared']['actions']
            self.assertEqual([next(k for k in a if k in {'record', 'attach', 'place'}) for a in actions],
                             ['record', 'record', 'attach', 'place'])
            self.assertEqual(actions[2]['select']['type'], 'Static')
            self.assertEqual(actions[2]['attach'][0],
                             ['*', 'meshes/f/furn_de_tapestry_03.nif', 'meshes/f/furn_de_tapestry_04.nif'])
            self.assertFalse((root / 'scripts/mom/content').exists())
            after = (root / 'mom_shared_after.omwscripts').read_text()
            self.assertIn('GLOBAL: scripts/mom_shared_phase_gate/global.lua', after)
            self.assertNotIn('startup_transport', gate.after_script('missing_status'))
            self.assertIn('compiler.load_status', gate.after_script('missing_status'))
            self.assertNotIn('sandbox.bypass', gate.menu_script('success'))

    def test_content_diagnostics_do_not_count_as_repeated_publications(self) -> None:
        log = '[MOM][INFO][content] content_member_unverified: rat\n' + self.log('success')
        result = gate.validate_log(log, 'success', 0)
        self.assertTrue(result['passed'])
        self.assertEqual(result['contentPublications'], 1)

    def test_host_mutation_changes_only_the_selected_declaration_domain(self) -> None:
        for case in ('global_input_changed', 'load_input_changed'):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                gate.stage_case(root, case)
                before = json.loads((root / gate.CONFIG).read_text())['variants']['shared']['actions']
                gate.mutate_input(root, case)
                after = json.loads((root / gate.CONFIG).read_text())['variants']['shared']['actions']
                self.assertEqual((root / gate.READY).read_text(), 'changed')
                if case == 'global_input_changed':
                    self.assertEqual(after[:4], before)
                    self.assertEqual(len(after), len(before) + 1)
                    self.assertIn('place', after[-1])
                else:
                    self.assertEqual(after[1:], before[1:])
                    self.assertEqual(after[0]['record']['patch']['name'], 'Changed LOAD name')
                    self.assertEqual(after[0]['record']['patch']['text'], before[0]['record']['patch']['text'])


if __name__ == '__main__':
    unittest.main()
