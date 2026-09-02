from __future__ import annotations

import unittest

from pc001_test_client.aggregation import FrameAccumulator
from pc001_test_client.protocol import Pc001Frame


def _frame(
    can_id: int,
    payload: bytes,
    *,
    channel: int = 3,
    is_extended: bool = True,
) -> Pc001Frame:
    wire_can_id = can_id | (0x80000000 if is_extended else 0)
    return Pc001Frame(can_id, is_extended, len(payload), payload, channel, wire_can_id)


class FrameAccumulatorTest(unittest.TestCase):
    def test_latest_value_count_and_ten_interval_rate(self) -> None:
        accumulator = FrameAccumulator()
        for index in range(12):
            accumulator.add_frame(_frame(0x18FF3A00, bytes([index])), index * 0.02)
        (snapshot,) = accumulator.drain_dirty()
        self.assertEqual(snapshot.payload, b"\x0b")
        self.assertEqual(snapshot.count, 12)
        self.assertAlmostEqual(snapshot.actual_hz or 0.0, 50.0)
        self.assertEqual(accumulator.drain_dirty(), ())

    def test_sff_eff_and_channel_are_distinct_keys(self) -> None:
        accumulator = FrameAccumulator()
        accumulator.add_frame(_frame(0x256, b"a", channel=0, is_extended=False), 1.0)
        accumulator.add_frame(_frame(0x256, b"b", channel=3), 1.0)
        self.assertEqual(len(accumulator.all_snapshots()), 2)

    def test_row_limit_drops_only_new_identities(self) -> None:
        accumulator = FrameAccumulator(max_rows=1)
        accumulator.add_frame(_frame(1, b"a"), 1.0)
        accumulator.add_frame(_frame(2, b"b"), 2.0)
        accumulator.add_frame(_frame(1, b"c"), 3.0)
        (snapshot,) = accumulator.all_snapshots()
        self.assertEqual(snapshot.payload, b"c")
        self.assertEqual(accumulator.total_frames, 3)
        self.assertEqual(accumulator.dropped_new_identities, 1)

    def test_clear_resets_rows_and_counters(self) -> None:
        accumulator = FrameAccumulator()
        accumulator.add_frame(_frame(1, b"a"), 1.0)
        accumulator.clear()
        self.assertEqual(accumulator.all_snapshots(), ())
        self.assertEqual(accumulator.total_frames, 0)


if __name__ == "__main__":
    unittest.main()

