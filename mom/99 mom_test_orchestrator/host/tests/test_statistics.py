from __future__ import annotations

import sys
from pathlib import Path
import unittest

HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import statistics as harness_statistics


class StatisticsTests(unittest.TestCase):
    def test_summary_is_explicit_and_stable(self) -> None:
        summary = harness_statistics.summarize([1.0, 2.0, 10.0])
        self.assertEqual(summary["count"], 3)
        self.assertEqual(summary["median"], 2.0)
        self.assertEqual(summary["medianAbsoluteDeviation"], 1.0)
        self.assertAlmostEqual(summary["mean"], 13 / 3)
        self.assertAlmostEqual(summary["p95"], 9.2)

    def test_bootstrap_ratio_is_seeded(self) -> None:
        first = harness_statistics.hierarchical_bootstrap_median_ratio(
            [[10.0] * 3 for _ in range(3)],
            [[11.0] * 3 for _ in range(3)],
            confidence=0.95,
            resamples=1000,
            seed=7,
        )
        second = harness_statistics.hierarchical_bootstrap_median_ratio(
            [[10.0] * 3 for _ in range(3)],
            [[11.0] * 3 for _ in range(3)],
            confidence=0.95,
            resamples=1000,
            seed=7,
        )
        self.assertEqual(first, second)
        self.assertEqual(first, {"estimate": 1.1, "lower": 1.1, "upper": 1.1})

    def test_hierarchical_bootstrap_preserves_process_level_variation(self) -> None:
        interval = harness_statistics.hierarchical_bootstrap_median_difference(
            [[8.0] * 20, [10.0] * 20, [12.0] * 20],
            [[9.0] * 20, [11.0] * 20, [16.0] * 20],
            confidence=0.95,
            resamples=2000,
            seed=13,
        )
        self.assertEqual(interval["estimate"], 1.0)
        self.assertLess(interval["lower"], interval["estimate"])
        self.assertGreater(interval["upper"], interval["estimate"])

    def test_nonfinite_samples_are_rejected(self) -> None:
        with self.assertRaisesRegex(ValueError, "finite"):
            harness_statistics.summarize([float("nan")])


if __name__ == "__main__":
    unittest.main()
