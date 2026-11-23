from __future__ import annotations

import shutil
import subprocess
import sys
import unittest
from pathlib import Path

HARNESS_ROOT = Path(__file__).resolve().parents[2]
REPO_ROOT = HARNESS_ROOT.parent.parent
LUA = shutil.which('luajit')


class StressSelectionTests(unittest.TestCase):
    @unittest.skipUnless(LUA, 'LuaJIT is required for the pure stress selection test')
    def test_stress_only_runs_each_scaled_case_once(self) -> None:
        completed = subprocess.run(
            [sys.executable, str(HARNESS_ROOT / 'host/standalone.py'),
             '--lua', LUA, '--stress-only'],
            cwd=REPO_ROOT, capture_output=True, text=True, timeout=120,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        cases = [line.split('MOM_STRESS_CASE:', 1)[1]
                 for line in completed.stdout.splitlines() if 'MOM_STRESS_CASE:' in line]
        self.assertEqual(cases, [
            'ledger v1: stress 1000-op save load and index maintenance',
            'runtime core: stress 500-candidate arbitration and 1000-item deadline queue',
            'runtime execution: stress 200-target cell reconciliation',
        ])
        self.assertIn('MOM pure contract tests passed: 3 case(s)', completed.stdout)


if __name__ == '__main__':
    unittest.main()
