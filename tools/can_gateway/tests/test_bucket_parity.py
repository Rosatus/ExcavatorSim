"""SY135 bucket travel parity: joint q_bucket -> CAN byte monotonicity and
frame-source consistency (bucket_link == passive linkage driven frame).
Run: python -m unittest discover -s tools/can_gateway/tests"""

from __future__ import annotations

import json
import math
import sys
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from conventions import MachineState, parse_packet  # noqa: E402
from encoders.ruifen_imu import encode_ruifen_frame, reported_rpy  # noqa: E402
from test_attitude_contract import make_packet_quats, q_axis_angle, q_mul, q_rest, X, Y  # noqa: E402

REPO = TOOLS_DIR.parents[1]


class Sy135BucketParityTest(unittest.TestCase):
    def _manifest(self) -> dict:
        return json.loads(
            (REPO / "godot/client/resources/visual/sy135_visual_manifest.json").read_text(encoding="utf-8"))

    def test_bucket_link_is_passive_driven_frame(self) -> None:
        m = self._manifest()
        pl = m.get("passive_linkage", {})
        if pl.get("mode") == "none":
            # no four-bar: bucket_link itself is the driven node; the bridge
            # must read exactly this node path.
            driven = "bucket_link"
        else:
            driven = pl["driven_frame"]
        node = m["frame_map"][driven]["node_path"]
        self.assertTrue(node.endswith("PIVOT_BUCKET_JOINT"), node)
        contact = m["excavation_contact"]
        self.assertEqual(contact["frame"], driven)

    def test_relative_angle_monotonic_across_travel(self) -> None:
        """q_bucket sweep within the elevation domain (rest -75 deg keeps the
        IMU pitch inside +/-90 like a real machine): relative bucket-vs-arm
        wire pitch changes monotonically with no jumps."""
        deltas = list(range(-15, 61, 5))
        rel_angles = []
        for d in deltas:
            quats = {
                "arm": q_rest("arm"),
                "bucket": q_mul(q_rest("bucket"), q_axis_angle(X, float(d))),
            }
            st = MachineState(parse_packet(make_packet_quats(quats)), model="sy135")
            arm_wire = reported_rpy(encode_ruifen_frame(
                MachineState.sensor_slots(*st.link_rpy("arm"))))[1]
            bkt_wire = reported_rpy(encode_ruifen_frame(
                MachineState.sensor_slots(*st.link_rpy("bucket"))))[1]
            # relative angle as downstream consumes it (both IMU frames on the
            # same rigid body chain): difference of wire pitches
            rel_angles.append(bkt_wire - arm_wire)
        diffs = [b - a for a, b in zip(rel_angles, rel_angles[1:])]
        self.assertTrue(all(dd < 1e-6 for dd in diffs),
                        f"non-monotonic relative angles: {rel_angles}")
        total = rel_angles[-1] - rel_angles[0]
        self.assertAlmostEqual(total, -75.0, delta=0.5)


if __name__ == "__main__":
    unittest.main()
