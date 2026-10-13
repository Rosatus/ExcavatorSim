"""SY155W wire -> calibrated serial-chain oracle, independent of mapper inverse."""

from __future__ import annotations

import itertools
import json
import math
import os
import struct
import sys
import tempfile
import unittest
from dataclasses import replace
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conventions import BodyPose, TelemetrySample, parse_packet
from gateway import FrameScheduler, emit_frames, model_console, protocol_codec
from qml_compat import QmlCanMapper, QmlMappingError, quat_inverse, quat_multiply
from qml_profile import QmlProfileError, load_qml_profile
from test_qml_compat import qx, qy
from test_sy80u import Capture, packet

# Default XTR13/GB12 pivot-to-tip vector, independently read from the soil
# contract. The receiver's bucket -Z axis is the SY135 pivot-to-tip reference.
TIP = (0.0, -1.2760000309944153, 0.668)


def articulated_sample(tick=1000, joints=(58.0, -47.0, -99.0, 97.0), body=(0.0, 0.0, 0.0)):
    pitch, roll, yaw = body
    r = math.radians(roll) / 2
    upper = quat_multiply(qy(yaw), quat_multiply(qx(pitch), (0, 0, math.sin(r), math.cos(r))))
    bodies = {name: BodyPose(upper, (1.0, 2.0, 3.0)) for name in ("chassis", "upper")}
    parent = upper
    for name, angle in zip(("boom", "boom2", "arm", "bucket"), joints, strict=True):
        parent = quat_multiply(parent, qx(angle))
        bodies[name] = BodyPose(parent, (1.0, 2.0, 3.0))
    return TelemetrySample(tick, bodies, 0.3, 0.5, 0.5, "sy155w")


def decode_chain(frames, calibration):
    """Raw RT signed R/P slots -> parser -> 135-style absolute IMUs -> local joints."""
    slots = {
        i: tuple(x * 0.01 for x in struct.unpack("<hhH", frames[i][0][:6]))
        for i in (0x18F00000, 0x18F10000, 0x18F40000, 0x18F20000, 0x18F30000)
    }
    c = calibration
    body_pitch = -slots[0x18F00000][1] + c.roll_error_IMU_Car
    boom = slots[0x18F10000][1] + c.pitch_error_IMU_Boom - body_pitch
    second_absolute = slots[0x18F40000][1] + c.pitch_error_IMU_Boom2 - body_pitch
    arm = (
        -slots[0x18F40000][1]
        - c.pitch_error_IMU_Boom2
        + slots[0x18F20000][1]
        + c.pitch_error_IMU_Arm
    )
    alpha = math.radians(
        slots[0x18F30000][1] + c.pitch_error_IMU_Bkt - slots[0x18F20000][1] - c.pitch_error_IMU_Arm
    )
    mn, nq, qk, mk = c.m_lMN, c.m_lNQ, c.m_lQK, c.m_lMK
    mq = math.sqrt(mn * mn + nq * nq - 2 * mn * nq * math.cos(alpha))

    def acos(v):
        return math.degrees(math.acos(max(-1, min(1, v))))

    bucket_phi = (
        360
        - c.m_angNQF
        - acos((qk * qk + mq * mq - mk * mk) / (2 * qk * mq))
        - acos((mq * mq + nq * nq - mn * mn) / (2 * mq * nq))
        - c.m_angKQV
    )
    # Recover source pivot from receiver's equivalent tip-ray frame.
    bucket = bucket_phi - 180 - math.degrees(math.atan2(TIP[1], -TIP[2]))
    return boom, second_absolute - boom, arm, bucket


class Sy155CanTest(unittest.TestCase):
    def setUp(self):
        self.profile = load_qml_profile("builtin:qml-sy155w-ground-truth")

    def test_second_boom_calibration_is_required_and_editable(self):
        original = self.profile.calibration_path.read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "calibration.toml"
            for value, message in ((None, "requires"), ("nan", "finite"), ("true", "numeric")):
                replacement = "" if value is None else f"pitch_boom2 = {value}"
                path.write_text(
                    original.replace("pitch_boom2 = 0.4713", replacement), encoding="utf-8-sig"
                )
                with self.assertRaisesRegex(QmlProfileError, message):
                    load_qml_profile("builtin:qml-sy155w-ground-truth", path)
            path.write_text(
                original.replace("pitch_boom2 = 0.4713", "pitch_boom2 = 2.4713"),
                encoding="utf-8-sig",
            )
            edited = load_qml_profile("builtin:qml-sy155w-ground-truth", path)
            before = QmlCanMapper(self.profile).project(articulated_sample())
            after = QmlCanMapper(edited).project(articulated_sample())
            self.assertAlmostEqual(
                after.imu_rpy_deg["boom2"][1] - before.imu_rpy_deg["boom2"][1], 2
            )
            for link in ("body", "boom", "arm", "bucket"):
                self.assertEqual(before.imu_rpy_deg[link], after.imu_rpy_deg[link])

    def assert_pose(self, sample):
        capture = Capture()
        emit_frames(
            [capture],
            FrameScheduler(dict.fromkeys(("imu", "slew", "travel", "rtk"), 50)),
            sample,
            model="sy155w",
            qml_mapper=QmlCanMapper(self.profile),
        )
        self.assertEqual(len(capture.frames), 8)
        self.assertEqual(capture.frames[0x18F40000][1], "ch3")
        self.assertEqual(len(capture.frames[0x18F40000][0]), 8)
        angles = decode_chain(capture.frames, self.profile.calibration)
        for (parent, child), angle in zip(
            (("upper", "boom"), ("boom", "boom2"), ("boom2", "arm"), ("arm", "bucket")),
            angles,
            strict=True,
        ):
            actual = quat_multiply(
                quat_inverse(sample.bodies[parent].quat_xyzw), sample.bodies[child].quat_xyzw
            )
            dot = abs(sum(a * b for a, b in zip(actual, qx(angle), strict=True)))
            self.assertLess(math.degrees(2 * math.acos(min(1, dot))), 0.04, (child, angle))

    def test_wire_oracle_all_joint_extremes_tilt_and_heading(self):
        for pose in itertools.product(
            (28.0, 58.0, 78.0), (-77.0, -47.0, -37.0), (-129.0, -99.0, -79.0), (57.0, 97.0, 137.0)
        ):
            for body in ((0.0, 0.0, 0.0), (12.0, -8.0, 170.0), (-9.0, 7.0, -160.0)):
                self.assert_pose(articulated_sample(joints=pose, body=body))

    def test_wrapped_pitch_boundary_is_exact(self):
        for boom in (-179.5287, 180.4713, -179.5327):
            capture = Capture()
            emit_frames(
                [capture],
                FrameScheduler(dict.fromkeys(("imu", "slew", "travel", "rtk"), 50)),
                articulated_sample(joints=(boom, -47, -99, 97)),
                model="sy155w",
                qml_mapper=QmlCanMapper(self.profile),
            )
            self.assertEqual(struct.unpack_from("<h", capture.frames[0x18F10000][0], 2)[0], -18000)

    def test_packet_version_and_bad_shapes(self):
        raw = packet(articulated_sample())
        self.assertEqual(len(raw), 204)
        self.assertEqual(parse_packet(raw).model_id, "sy155w")
        for bad in (raw[:-1], raw + b"\0", raw[:4] + b"\2" + raw[5:], raw[:6] + b"\1\0" + raw[8:]):
            self.assertIsNone(parse_packet(bad))
        bad = bytearray(raw)
        struct.pack_into("<f", bad, 156, float("nan"))
        self.assertIsNone(parse_packet(bad))

    def test_rejected_sample_rolls_back_and_recovers(self):
        mapper = QmlCanMapper(self.profile)
        scheduler = FrameScheduler(dict.fromkeys(("imu", "slew", "travel", "rtk"), 50))
        sink = Capture()
        bad = articulated_sample()
        bad.bodies["boom2"] = replace(bad.bodies["boom2"], quat_xyzw=qy(15))
        with self.assertRaises(QmlMappingError):
            emit_frames([sink], scheduler, bad, model="sy155w", qml_mapper=mapper)
        self.assertEqual(sink.frames, {})
        self.assertIsNone(mapper._previous_tick_ms)
        emit_frames([sink], scheduler, articulated_sample(), model="sy155w", qml_mapper=mapper)
        self.assertEqual(len(sink.frames), 8)

    def test_catalog_storage_and_strict_dbc(self):
        args = SimpleNamespace(
            imu_hz=50, rtk_hz=10, slew_hz=50, travel_hz=10, mode="godot-managed", dbc_dir=[]
        )
        old, _ = model_console(args, "sy135")
        new, _ = model_console(args, "sy155w")
        self.assertNotEqual(old.store.path, new.store.path)
        codec = protocol_codec("sy155w")
        definition = codec.unique_message_by_frame(0x18F40000)
        self.assertTrue(definition.is_extended)
        expected = codec.encode_frame(
            0x18F10000,
            {
                "Pitch_Angle": 12.5,
                "Roll_Angle": -2.0,
                "Yaw_Angle": 0.0,
                "Reserved_1": 0.0,
                "Reserved_2": 0.0,
            },
        )
        actual = codec.encode_frame(
            0x18F40000,
            {
                "Pitch_Angle": 12.5,
                "Roll_Angle": -2.0,
                "Yaw_Angle": 0.0,
                "Reserved_1": 0.0,
                "Reserved_2": 0.0,
            },
        )
        self.assertEqual(actual, expected)

    @unittest.skipUnless(os.environ.get("CAN_POSE_CAPTURE_155"), "requires real Godot capture")
    def test_real_post_step_capture(self):
        entries = json.loads(Path(os.environ["CAN_POSE_CAPTURE_155"]).read_text())
        self.assertTrue(any(row["label"] == "fold_negative" for row in entries))
        for row in entries:
            sample = parse_packet(bytes.fromhex(row["packet_hex"]))
            self.assertIsNotNone(sample, row["label"])
            self.assert_pose(sample)
