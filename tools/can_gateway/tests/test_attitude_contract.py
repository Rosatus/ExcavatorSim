"""Attitude-contract acceptance tests: Y-up euler decomposition, IMU
zero-mount compensation, and downstream Sensor2Ang parity.
Run: python -m unittest discover -s tools/can_gateway/tests"""

from __future__ import annotations

import json
import math
import struct
import sys
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from conventions import (  # noqa: E402
    IMU_MOUNT_COMPENSATION_DEG,
    PACKET_MAGIC,
    MachineState,
    parse_packet,
    quat_to_yup_euler_deg,
)
from encoders.ruifen_imu import encode_ruifen_frame, reported_rpy  # noqa: E402

REPO = TOOLS_DIR.parents[1]


def q_axis_angle(axis, deg):
    a = math.radians(deg) / 2.0
    s = math.sin(a)
    x, y, z = axis
    return (x * s, y * s, z * s, math.cos(a))


def q_mul(a, b):
    ax, ay, az, aw = a
    bx, by, bz, bw = b
    return (
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by + ay * bw + az * bx - ax * bz,
        aw * bz + az * bw + ax * by - ay * bx,
        aw * bw - ax * bx - ay * by - az * bz,
    )


X = (1.0, 0.0, 0.0)
Y = (0.0, 1.0, 0.0)

# sy135 baked rest rotations about X (rest_transforms_godot), CASCaded down
# the pivot chain: runtime world quat of arm = Rx(35-55)=Rx(-20), etc.
SY135_REST_X_DEG = {"boom": 35.0, "arm": -20.0, "bucket": -95.0}


def q_rest(link: str, extra_deg: float = 0.0) -> tuple:
    return q_axis_angle(X, SY135_REST_X_DEG[link] + extra_deg)


def make_packet_quats(link_quats: dict[str, tuple]) -> bytes:
    """Build a CTN1 packet with per-body quaternions (order: chassis, upper, boom, arm, bucket)."""
    names = ("chassis", "upper", "boom", "arm", "bucket")
    raw = struct.pack("<IBBHQ", PACKET_MAGIC, 1, 0, 0, 1000)
    for name in names:
        quat = link_quats.get(name, (0.0, 0.0, 0.0, 1.0))
        origin_index = float(names.index(name))
        raw += struct.pack("<4f3f", *quat, origin_index, 0.0, 0.0)
    raw += struct.pack("<5f", 0.0, 0.0, 0.0, 0.0, 0.0)
    return raw


def state_for(quats: dict[str, tuple], model: str = "sy135") -> MachineState:
    return MachineState(parse_packet(make_packet_quats(quats)), model=model)


class YupEulerDecompositionTest(unittest.TestCase):
    def test_lift_30_reads_pitch_minus30(self) -> None:
        # rest quat (Rx 35) plus 30 deg lift -> frame elev 65, comp +35 => -30
        st = state_for({"boom": q_rest("boom", 30.0)})
        roll, pitch, yaw = st.link_rpy("boom")
        self.assertAlmostEqual(pitch, -30.0, delta=0.01)  # raised reads negative
        self.assertLess(abs(roll), 0.01)
        self.assertLess(abs(yaw), 0.01)

    def test_heading_45_reads_yaw_45(self) -> None:
        st = state_for({"chassis": q_axis_angle(Y, 45), "upper": q_axis_angle(Y, 45)})
        _roll, pitch, yaw = st.link_rpy("body")
        self.assertAlmostEqual(yaw, 45.0, delta=0.01)
        self.assertLess(abs(pitch), 0.01)

    def test_yaw90_lift30_no_gimbal_lock(self) -> None:
        q = q_mul(q_axis_angle(Y, 90), q_rest("boom", 30.0))
        st = state_for({"chassis": q_axis_angle(Y, 90), "upper": q_axis_angle(Y, 90), "boom": q})
        _roll, pitch, yaw = st.link_rpy("boom")
        self.assertAlmostEqual(pitch, -30.0, delta=0.05)
        self.assertAlmostEqual(yaw, 90.0, delta=0.05)


class ContinuousPitchUnwrapTest(unittest.TestCase):
    """Real IMUs report pitch through +/-90 continuously; the elevation
    decomposition folds there with a yaw jump. Downstream joint reconstruction
    uses bkt-arm differences, so a fold mid-dig breaks the model."""

    def test_arm_curling_past_vertical_stays_monotonic(self) -> None:
        # sy135 arm: rest world Rx(-20); digging curls further down through
        # the vertical. Wire pitch must grow monotonically (real-IMU like).
        pitches = []
        for extra in range(0, 121, 10):
            st = state_for({"arm": q_rest("arm", -float(extra))})
            pitches.append(st.link_rpy("arm")[1])
        diffs = [b - a for a, b in zip(pitches, pitches[1:])]
        self.assertTrue(all(d > 1.0 for d in diffs),
                        f"pitch not monotonically increasing through vertical: {pitches}")
        self.assertAlmostEqual(pitches[-1], 120.0, delta=0.5)

    def test_heading_rotation_does_not_trigger_unwrap(self) -> None:
        # slewing backward puts world yaw beyond +/-90 with up_y >= 0:
        # pitch must stay ~0, yaw must read the true heading.
        st = state_for({"chassis": q_axis_angle(Y, 135), "upper": q_axis_angle(Y, 135)})
        roll, pitch, yaw = st.link_rpy("body")
        self.assertAlmostEqual(yaw, 135.0, delta=0.01)
        self.assertLess(abs(pitch), 0.01)


class MountCompensationTest(unittest.TestCase):
    def test_sy135_rest_reports_zero_segment_elevation(self) -> None:
        # sy135 segments are horizontal at rest; comp cancels the baked frame
        # rotation. Runtime quats include the rest rotation (Rx 35/-55/-75).
        st = state_for({link: q_rest(link) for link in ("boom", "arm", "bucket")}, model="sy135")
        for link in ("boom", "arm", "bucket"):
            _r, pitch, _y = st.link_rpy(link)
            self.assertAlmostEqual(pitch, 0.0, delta=0.01, msg=link)

    def test_sy205_rest_reports_minus_segment_elevation(self) -> None:
        st = state_for({}, model="sy205")
        boom_pitch = st.link_rpy("boom")[1]
        arm_pitch = st.link_rpy("arm")[1]
        self.assertAlmostEqual(boom_pitch, -47.65, delta=0.05)
        # downstream polar convention: arm segment at -101.79 reads +101.79
        # after the -elevation sign flip (IMU mounted opposite the steel face)
        self.assertAlmostEqual(arm_pitch, 101.79, delta=0.05)

    def test_sy205_rest_downstream_armphi(self) -> None:
        # Sensor2Ang parity: armPhi = 180 - ((-p_b + errB) - (-p_a + errA))
        st = state_for({}, model="sy205")
        p_b = st.link_rpy("boom")[1]
        p_a = st.link_rpy("arm")[1]
        arm_phi = 180.0 - ((-p_b + 0.4713) - (-p_a - 0.1928))
        self.assertAlmostEqual(arm_phi, 30.6, delta=1.5)
        boom_phi = -p_b + 0.4713
        self.assertAlmostEqual(boom_phi, 47.6, delta=1.0)

    def test_tables_match_manifest_derivation(self) -> None:
        """Lock table values against world-cascaded manifest derivation.

        comp[link] = frame world rest elevation (segments horizontal for
        sy135), accumulating parent chain rest rotations.
        """
        sy135 = json.loads(
            (REPO / "godot/client/resources/visual/sy135_visual_manifest.json").read_text(encoding="utf-8"))
        rt = sy135["calibration"]["rest_transforms_godot"]

        def fwd_elev(name):
            m = [row[:3] for row in rt[name][:3]]
            fz = (-m[0][2], -m[1][2], -m[2][2])
            return math.degrees(math.atan2(fz[1], math.hypot(fz[0], fz[2])))

        # cascade: boom frame sits on identity chassis; arm on boom; bucket on arm
        acc = 0.0
        for link in ("boom", "arm", "bucket"):
            acc += fwd_elev(f"{link}_link")
            self.assertAlmostEqual(IMU_MOUNT_COMPENSATION_DEG["sy135"][link], round(acc, 2), delta=0.02)


class DownstreamSensor2AngParityTest(unittest.TestCase):
    """Replicate GuideSystem lib_kin.Sensor2Ang on our wire values."""

    CAL = {"boom": 0.4713, "arm": -0.1928, "bkt": 4.9748}

    def _sensor2ang(self, boom_p: float, arm_p: float, body_pitch: float = 0.0) -> tuple[float, float]:
        boom_phi = -boom_p + self.CAL["boom"] + body_pitch
        arm_phi = 180.0 - ((-boom_p + self.CAL["boom"]) - (-arm_p + self.CAL["arm"]))
        return boom_phi, arm_phi

if __name__ == "__main__":
    unittest.main()
