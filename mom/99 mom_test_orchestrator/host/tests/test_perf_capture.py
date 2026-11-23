from __future__ import annotations

from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock

HOST_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST_ROOT))

import perf_capture


class PerfCaptureTests(unittest.TestCase):
    def test_wall_control_is_the_exact_child(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            child = ["/engine/openmw", "--config", "/config"]
            command, metadata = perf_capture.command(
                "wall-control", child, Path(directory)
            )
            self.assertEqual(command, child)
            self.assertEqual(metadata["exactChild"], child)

    def test_record_and_stat_wrap_the_exact_child(self) -> None:
        identity = {"path": "/usr/bin/perf", "sha256": "x", "version": "perf test"}
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            perf_capture, "perf_identity", return_value=identity
        ):
            child = ["/engine/openmw", "--config", "/config"]
            record, metadata = perf_capture.command("record", child, Path(directory))
            self.assertEqual(record[-len(child):], child)
            self.assertIn("--call-graph", record)
            self.assertEqual(metadata["frequencyHz"], 99)

            stat, metadata = perf_capture.command("stat-core", child, Path(directory))
            self.assertEqual(stat[-len(child):], child)
            self.assertEqual(metadata["events"], list(perf_capture.CORE_EVENTS))

    def test_stat_parser_preserves_unavailable_and_multiplexed_events(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "stat.csv"
            path.write_text(
                "1000;;cycles:u;1.0;100.00;;\n"
                "2000;;instructions:u;1.0;75.00;;\n"
                "<not supported>;;branches:u;1.0;;;\n",
                encoding="utf-8",
            )
            rows = perf_capture.parse_stat(path, perf_capture.CORE_EVENTS)
            self.assertEqual(rows[0]["state"], "available")
            self.assertEqual(rows[1]["state"], "multiplexed")
            self.assertEqual(rows[2]["state"], "unavailable")
            self.assertEqual(rows[3]["state"], "missing")

    def test_stat_capture_metadata_is_relocatable_and_reports_partial_data(self) -> None:
        identity = {"path": "/usr/bin/perf", "sha256": "x", "version": "perf test"}
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            perf_capture, "perf_identity", return_value=identity
        ):
            root = Path(directory)
            _command, metadata = perf_capture.command(
                "stat-core", ["/engine/openmw"], root
            )
            self.assertEqual(metadata["statOutput"], "stat.csv")
            (root / "stat.csv").write_text(
                "1000;;cycles:u;1.0;100.00;;\n"
                "<not supported>;;instructions:u;1.0;;;\n",
                encoding="utf-8",
            )
            captured = perf_capture.postprocess(metadata, root)
            self.assertEqual(captured["status"], "partial")
            self.assertEqual(captured["counters"][0]["state"], "available")
            self.assertEqual(captured["counters"][1]["state"], "unavailable")


if __name__ == "__main__":
    unittest.main()
