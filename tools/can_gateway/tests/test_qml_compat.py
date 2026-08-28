"""Characterization tests for the QML-canonical compatibility profile."""

from __future__ import annotations

import hashlib
import math
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from conventions import BodyPose, TelemetrySample, basis_forward_from_quat  # noqa: E402
from encoders.ruifen_imu import RUFINEN_IDS, reported_rpy  # noqa: E402
from encoders.sinan_rtk import RTK_IDS_ORDERED, decode_heading, decode_status  # noqa: E402
from gateway import FrameScheduler, emit_frames  # noqa: E402
from gateway import main as gateway_main  # noqa: E402
from qml_compat import (  # noqa: E402
    QmlCanMapper,
    QmlMappingError,
    extract_qml_body_angles,
    qml_exca_from_godot_quaternion,
    sensor2ang_from_reported,
)
from qml_profile import (  # noqa: E402
    BUILTIN_PROFILE,
    QmlProfileError,
    load_qml_profile,
)


def qx(degrees: float) -> tuple[float, float, float, float]:
    half = math.radians(degrees) * 0.5
    return math.sin(half), 0.0, 0.0, math.cos(half)


def qy(degrees: float) -> tuple[float, float, float, float]:
    half = math.radians(degrees) * 0.5
    return 0.0, math.sin(half), 0.0, math.cos(half)


def _wrap_signed_degrees(value: float) -> float:
    return (value + 180.0) % 360.0 - 180.0


def _qml_render_local_joints(
    qml_joint_deg: tuple[float, float, float],
) -> tuple[float, float, float]:
    return (
        _wrap_signed_degrees(qml_joint_deg[0]),
        _wrap_signed_degrees(qml_joint_deg[1] + 180.0),
        _wrap_signed_degrees(qml_joint_deg[2] + 180.0),
    )


def make_sample(
    tick_ms: int = 1000,
    boom_world_deg: float = 35.0,
    arm_world_deg: float = -55.0,
    bucket_world_deg: float = -105.0,
) -> TelemetrySample:
    identity = (0.0, 0.0, 0.0, 1.0)
    bodies = {
        "chassis": BodyPose(identity, (0.0, 0.0, 0.0)),
        "upper": BodyPose(identity, (10.0, 2.0, -20.0)),
        "boom": BodyPose(qx(boom_world_deg), (0.0, 0.0, 0.0)),
        "arm": BodyPose(qx(arm_world_deg), (0.0, 0.0, 0.0)),
        "bucket": BodyPose(qx(bucket_world_deg), (0.0, 0.0, 0.0)),
    }
    return TelemetrySample(tick_ms, bodies, 0.0, 0.0, 0.0)


class QmlProfileTest(unittest.TestCase):
    def test_builtin_profile_is_bound_to_reference_fixture_bytes(self) -> None:
        profile = load_qml_profile(BUILTIN_PROFILE)
        actual = hashlib.sha256(profile.calibration_path.read_bytes()).hexdigest()
        self.assertEqual(actual, profile.calibration_sha256)
        self.assertEqual(actual, "47cab86524d35866a0fa4fd7490feb0ab8ca4a0645b89ddc29f6380fed421b56")

    def test_calibration_override_fails_closed_on_hash_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            changed = Path(directory) / "calibration.toml"
            changed.write_text("[angle]\nm_angKQV = 1\n", encoding="utf-8")
            with self.assertRaisesRegex(QmlProfileError, "SHA-256 mismatch"):
                load_qml_profile(BUILTIN_PROFILE, changed)

    def test_wrong_model_and_frame_contract_fail_closed(self) -> None:
        builtin = load_qml_profile(BUILTIN_PROFILE)
        original = builtin.source_path.read_text(encoding="utf-8")
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / builtin.calibration_path.name).write_bytes(
                builtin.calibration_path.read_bytes()
            )
            for name, changed, message in (
                (
                    "model.toml",
                    original.replace('model_id = "sy135"', 'model_id = "sy205"'),
                    "unsupported QML model",
                ),
                (
                    "frame.toml",
                    original.replace('body_imu = "upper"', 'body_imu = "chassis"'),
                    "frames.body_imu",
                ),
                (
                    "nan.toml",
                    original.replace("boom_sign = 1.0", "boom_sign = nan"),
                    "must be finite",
                ),
            ):
                path = root / name
                path.write_text(changed, encoding="utf-8")
                with self.subTest(name=name), self.assertRaisesRegex(QmlProfileError, message):
                    load_qml_profile(path)


class QmlPoseMappingTest(unittest.TestCase):
    def setUp(self) -> None:
        self.profile = load_qml_profile(BUILTIN_PROFILE)

    def test_neutral_pose_roundtrips_qml_body_joints_and_slew_center(self) -> None:
        projection = QmlCanMapper(self.profile).project(make_sample())
        self.assertTupleEqual(
            tuple(round(value, 6) for value in projection.body_pose_deg), (0.0, 0.0, 0.0)
        )
        for actual, expected in zip(
            projection.qml_joint_deg, self.profile.neutral_qml_deg, strict=True
        ):
            self.assertAlmostEqual(actual, expected, places=6)

        body_roll, body_pitch, body_yaw = projection.imu_rpy_deg["body"]
        calibration = self.profile.calibration
        # GuidancePeriodicService constructs IMUInput(-parser_pitch,
        # parser_roll, ..., A900), then lib_kin applies calibration.
        self.assertAlmostEqual(body_pitch + calibration.car_roll_error_deg, 0.0, places=6)
        self.assertAlmostEqual(body_roll - calibration.car_pitch_error_deg, 0.0, places=6)
        self.assertAlmostEqual(body_yaw, 0.0, places=6)

        reported = tuple(projection.imu_rpy_deg[name][1] for name in ("boom", "arm", "bucket"))
        roundtrip = sensor2ang_from_reported(0.0, *reported, calibration)
        for actual, expected in zip(roundtrip, self.profile.neutral_qml_deg, strict=True):
            self.assertAlmostEqual(actual, expected, places=5)

        reconstructed_center = tuple(
            projection.main_antenna_enu_m[row]
            + sum(
                projection.exca[row][column] * calibration.go_vehicle_m[column]
                for column in range(3)
            )
            for row in range(3)
        )
        self.assertTupleEqual(
            tuple(round(value, 6) for value in reconstructed_center), (10.0, 20.0, 2.0)
        )
        self.assertEqual(projection.satellite_status, 4)

    def test_qml_rendered_neutral_local_joints_match_godot_relations(self) -> None:
        projection = QmlCanMapper(self.profile).project(make_sample())

        # WorkingModel3DView applies boomPhi directly, then armPhi + 180 and
        # bktPhi + 180. Compare those rendered local-X rotations with the
        # actual Godot upper->boom->arm->bucket neutral relations.
        qml_render_local = _qml_render_local_joints(projection.qml_joint_deg)
        godot_local = (35.0, -90.0, -50.0)
        for actual, expected in zip(qml_render_local, godot_local, strict=True):
            self.assertAlmostEqual(actual, expected, places=6)

    def test_positive_arm_joint_changes_only_qml_arm(self) -> None:
        # The arm and all descendants inherit the +10 degree local arm twist.
        projection = QmlCanMapper(self.profile).project(
            make_sample(arm_world_deg=-45.0, bucket_world_deg=-95.0)
        )
        expected = list(self.profile.neutral_qml_deg)
        expected[1] += 10.0
        for actual, wanted in zip(projection.qml_joint_deg, expected, strict=True):
            self.assertAlmostEqual(actual, wanted, places=6)

    def test_each_joint_delta_has_qml_positive_and_negative_parity(self) -> None:
        for index in range(3):
            for delta in (-15.0, 15.0):
                angles = [35.0, -55.0, -105.0]
                for affected in range(index, 3):
                    angles[affected] += delta
                projection = QmlCanMapper(self.profile).project(
                    make_sample(
                        boom_world_deg=angles[0],
                        arm_world_deg=angles[1],
                        bucket_world_deg=angles[2],
                    )
                )
                expected = list(self.profile.neutral_qml_deg)
                expected[index] += delta
                with self.subTest(joint=index, delta=delta):
                    for actual, wanted in zip(projection.qml_joint_deg, expected, strict=True):
                        self.assertAlmostEqual(actual, wanted, places=6)
                    godot_local = (
                        angles[0],
                        angles[1] - angles[0],
                        angles[2] - angles[1],
                    )
                    for actual, wanted in zip(
                        _qml_render_local_joints(projection.qml_joint_deg),
                        godot_local,
                        strict=True,
                    ):
                        self.assertAlmostEqual(actual, wanted, places=6)

    def test_identity_and_cardinal_forward_axes_are_godot_minus_z(self) -> None:
        self.assertTupleEqual(basis_forward_from_quat((0.0, 0.0, 0.0, 1.0)), (0.0, 0.0, -1.0))
        half = math.sqrt(0.5)
        forward = basis_forward_from_quat((0.0, half, 0.0, half))
        self.assertAlmostEqual(forward[0], -1.0, places=6)
        self.assertAlmostEqual(forward[2], 0.0, places=6)

    def test_identity_upper_matches_qml_heading_zero_basis(self) -> None:
        exca = qml_exca_from_godot_quaternion((0.0, 0.0, 0.0, 1.0))
        self.assertEqual(exca, ((0.0, 1.0, 0.0), (-1.0, 0.0, 0.0), (0.0, 0.0, 1.0)))

    def test_godot_cardinal_yaw_maps_to_qml_heading_contract(self) -> None:
        for godot_yaw, expected_heading in ((90.0, 270.0), (-90.0, 90.0)):
            exca = qml_exca_from_godot_quaternion(qy(godot_yaw))
            _pitch, _roll, heading = extract_qml_body_angles(exca, 1e-6)
            self.assertAlmostEqual(heading, expected_heading, places=6)

    def test_qml_roll_gimbal_pose_is_rejected(self) -> None:
        singular = ((0.0, 0.0, 1.0), (0.0, 1.0, 0.0), (-1.0, 0.0, 0.0))
        with self.assertRaisesRegex(QmlMappingError, "gimbal"):
            extract_qml_body_angles(singular, 1e-6)


class _CollectingSink:
    def __init__(self) -> None:
        self.frames: list[tuple[int, bytes]] = []

    def append(self, can_id: int, payload: bytes) -> None:
        self.frames.append((can_id, payload))

    def close(self) -> None:
        pass


class QmlGatewayIntegrationTest(unittest.TestCase):
    def setUp(self) -> None:
        self.profile = load_qml_profile(BUILTIN_PROFILE)

    def test_emit_frames_uses_projection_for_imu_heading_and_rtk_status(self) -> None:
        sample = make_sample()
        expected = QmlCanMapper(self.profile).project(sample)
        sink = _CollectingSink()
        scheduler = FrameScheduler({"imu": 100.0, "slew": 100.0, "rtk": 10.0, "travel": 10.0})
        emit_frames([sink], scheduler, sample, qml_mapper=QmlCanMapper(self.profile))
        frames = dict(sink.frames)

        decoded_rpy = {}
        for link, can_id in RUFINEN_IDS.items():
            actual_rpy = reported_rpy(frames[can_id])
            decoded_rpy[link] = actual_rpy
            for actual, wanted in zip(actual_rpy, expected.imu_rpy_deg[link], strict=True):
                self.assertAlmostEqual(actual, wanted, delta=0.011)

        calibration = self.profile.calibration
        decoded_qml_joints = sensor2ang_from_reported(
            decoded_rpy["body"][1] + calibration.car_roll_error_deg,
            decoded_rpy["boom"][1],
            decoded_rpy["arm"][1],
            decoded_rpy["bucket"][1],
            calibration,
        )
        for actual, wanted in zip(
            _qml_render_local_joints(decoded_qml_joints),
            (35.0, -90.0, -50.0),
            strict=True,
        ):
            self.assertAlmostEqual(actual, wanted, delta=0.04)

        self.assertEqual(decode_status(frames[RTK_IDS_ORDERED[1]])["satelliteStatus"], 4)
        self.assertAlmostEqual(
            decode_heading(frames[RTK_IDS_ORDERED[9]]),
            expected.wire_heading_deg,
            delta=0.011,
        )

    def test_mapping_error_emits_no_partial_frame_family(self) -> None:
        sample = make_sample()
        bodies = dict(sample.bodies)
        bodies["arm"] = BodyPose(
            (0.0, math.sin(math.radians(5.0)), 0.0, math.cos(math.radians(5.0))), (0.0, 0.0, 0.0)
        )
        invalid = TelemetrySample(sample.tick_ms, bodies, 0.0, 0.0, 0.0)
        sink = _CollectingSink()
        scheduler = FrameScheduler({"imu": 100.0, "slew": 100.0, "rtk": 10.0, "travel": 10.0})
        with self.assertRaises(QmlMappingError):
            emit_frames([sink], scheduler, invalid, qml_mapper=QmlCanMapper(self.profile))
        self.assertEqual(sink.frames, [])

    def test_non_finite_origin_is_rejected_before_any_frame_is_sent(self) -> None:
        sample = make_sample()
        bodies = dict(sample.bodies)
        upper = bodies["upper"]
        bodies["upper"] = BodyPose(upper.quat_xyzw, (math.nan, 0.0, 0.0))
        invalid = TelemetrySample(sample.tick_ms, bodies, 0.0, 0.0, 0.0)
        sink = _CollectingSink()
        scheduler = FrameScheduler({"imu": 100.0, "slew": 100.0, "rtk": 10.0, "travel": 10.0})
        with self.assertRaisesRegex(QmlMappingError, "non-finite"):
            emit_frames(
                [sink],
                scheduler,
                invalid,
                qml_mapper=QmlCanMapper(self.profile),
            )
        self.assertEqual(sink.frames, [])

    def test_same_tick_different_packet_is_not_returned_from_cache(self) -> None:
        mapper = QmlCanMapper(self.profile)
        mapper.project(make_sample())
        with self.assertRaisesRegex(QmlMappingError, "increasing telemetry ticks"):
            mapper.project(make_sample(boom_world_deg=40.0))

    def test_profile_a800_velocity_uses_approved_dbc_little_endian(self) -> None:
        mapper = QmlCanMapper(self.profile)
        scheduler = FrameScheduler({"imu": 100.0, "slew": 100.0, "rtk": 10.0, "travel": 10.0})
        sink = _CollectingSink()
        first = make_sample(tick_ms=1000)
        emit_frames([sink], scheduler, first, qml_mapper=mapper)
        second = make_sample(tick_ms=1100)
        bodies = dict(second.bodies)
        upper = bodies["upper"]
        bodies["upper"] = BodyPose(
            upper.quat_xyzw,
            (upper.origin_m[0] + 1.0, upper.origin_m[1], upper.origin_m[2]),
        )
        moved = TelemetrySample(second.tick_ms, bodies, 0.0, 0.0, 0.0)
        sink.frames.clear()
        emit_frames([sink], scheduler, moved, qml_mapper=mapper)
        payload = dict(sink.frames)[RTK_IDS_ORDERED[8]]
        reference_values = tuple(
            int.from_bytes(payload[index : index + 2], "little", signed=True) * 0.01
            for index in range(0, 8, 2)
        )
        self.assertEqual(reference_values, (10.0, 0.0, 0.0, 10.0))

    def test_cli_rejects_missing_profile_before_transport_setup(self) -> None:
        result = gateway_main(["--compat-profile", "missing-profile.toml"])
        self.assertEqual(result, 1)


if __name__ == "__main__":
    unittest.main()
