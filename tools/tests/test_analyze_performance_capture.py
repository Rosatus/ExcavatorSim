"""Analysis must not turn paused frames or unavailable GPU timings into evidence."""

from __future__ import annotations

import copy
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from analyze_performance_capture import (
    REQUIRED_COLUMNS,
    SCHEMA,
    analyze_capture,
    render_markdown,
)


def capture_fixture() -> dict:
    columns = sorted(REQUIRED_COLUMNS)

    def row(t: float, interval: float, paused: int = 0, focused: int = 1, soil: float = 0) -> list:
        values = dict.fromkeys(columns, 0)
        values.update(
            t_ms=t,
            frame_interval_ms=interval,
            paused=paused,
            focused=focused,
            soil_total_ms=soil,
            render_gpu_ms=-1,
        )
        return [values[key] for key in columns]

    return {
        "schema": SCHEMA,
        "complete": True,
        "frame_columns": columns,
        "frames": [
            row(1, 1),
            row(17, 16),
            row(77, 60, soil=40),
            row(1077, 1000, paused=1),
            row(2077, 1000, focused=0),
        ],
        "events": [{"kind": "marker", "t_ms": 80, "label": "test"}],
        "contexts": [{"model_id": "sy135", "queue_depth": 2, "pending_readiness_count": 3}],
    }


class AnalyzeCaptureTests(unittest.TestCase):
    def test_active_frames_and_marker_window(self) -> None:
        result = analyze_capture(capture_fixture())
        self.assertEqual(result["active_frames"], 2)
        self.assertEqual(result["excluded_frames"], 3)
        self.assertAlmostEqual(result["average_fps"], 2000 / 76)
        self.assertEqual(result["metrics_ms"]["frame_interval_ms"]["p99"], 60)
        self.assertEqual(result["metrics_ms"]["render_gpu_ms"]["count"], 0)
        self.assertEqual(result["markers"][0]["worst_frame"]["t_ms"], 77)
        self.assertEqual(result["slow_frame_clues"]["soil_at_least_half_interval"], 1)
        self.assertIn("不可用", render_markdown(result))

    def test_rejects_incomplete_or_invalid_samples(self) -> None:
        report = capture_fixture()
        for mutation in ["incomplete", "columns", "length", "nan", "backward"]:
            with self.subTest(mutation=mutation):
                bad = copy.deepcopy(report)
                if mutation == "incomplete":
                    bad["complete"] = False
                elif mutation == "columns":
                    bad["frame_columns"][0] = "unknown"
                elif mutation == "length":
                    bad["frames"][0].pop()
                elif mutation == "nan":
                    bad["frames"][0][0] = float("nan")
                else:
                    bad["frames"][2][bad["frame_columns"].index("t_ms")] = 0
                with self.assertRaises(ValueError):
                    analyze_capture(bad)

    def test_empty_active_capture_is_not_a_fast_result(self) -> None:
        report = capture_fixture()
        report["frames"] = []
        result = analyze_capture(report)
        self.assertEqual(result["active_frames"], 0)
        self.assertEqual(result["metrics_ms"]["frame_interval_ms"]["count"], 0)
        self.assertIsNone(result["markers"][0]["worst_frame"])
        self.assertIn("没有完整", result["warnings"][0])

    def test_full_diagnostics_are_explicitly_flagged(self) -> None:
        report = capture_fixture()
        report["metadata"] = {"soil_diagnostics_enabled": True}
        result = analyze_capture(report)
        self.assertTrue(result["full_diagnostics_enabled"])
        self.assertIn("额外诊断负载", render_markdown(result))
        report["metadata"] = []
        with self.assertRaises(ValueError):
            analyze_capture(report)


if __name__ == "__main__":
    unittest.main()
