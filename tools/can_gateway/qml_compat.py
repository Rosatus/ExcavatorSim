"""QML-canonical pose projection for CAN emission.

This module implements the inverse of the immutable GuideSystem 3D pipeline:
Godot upper/link transforms -> parser-reported IMU/RTK values -> QML Exca,
joint angles and slew-center position. Calibration is a separate stage
(`calibration.py`): this module only frames the geometry and alignment, and
delegates every calibrated quantity to that stage.
"""

from __future__ import annotations

import math
from dataclasses import dataclass

from calibration import (
    CalibrationError,
    invert_sensor2ang,
    invert_two_boom_sensor2ang,
    main_antenna_enu,
    wire_body_angles,
)
from conventions import (
    METERS_PER_DEG_LAT,
    ORIGIN_ALT_M,
    ORIGIN_LAT_DEG,
    ORIGIN_LON_DEG,
    TelemetrySample,
    quat_to_yup_euler_deg,
)
from qml_profile import QmlCompatibilityProfile

Matrix3 = tuple[
    tuple[float, float, float],
    tuple[float, float, float],
    tuple[float, float, float],
]
Vector3 = tuple[float, float, float]
Quaternion = tuple[float, float, float, float]

C_GODOT_TO_VEHICLE: Matrix3 = (
    (1.0, 0.0, 0.0),
    (0.0, 0.0, -1.0),
    (0.0, 1.0, 0.0),
)
Q_QML_HEADING_ZERO: Matrix3 = (
    (0.0, 1.0, 0.0),
    (-1.0, 0.0, 0.0),
    (0.0, 0.0, 1.0),
)


# Calibration and projection violate the same contract ("this sample cannot be
# represented"), so they share one failure type and callers keep a single
# `except QmlMappingError` clause.
QmlMappingError = CalibrationError


@dataclass(frozen=True)
class QmlPoseProjection:
    imu_rpy_deg: dict[str, tuple[float, float, float]]
    body_pose_deg: tuple[float, float, float]  # pitch, roll, heading after QML calibration
    qml_joint_deg: tuple[float, float, float]
    exca: Matrix3
    main_antenna_enu_m: Vector3
    vice_antenna_enu_m: Vector3
    velocity_enu_mps: tuple[float, float, float, float]
    wire_heading_deg: float
    satellite_status: int
    boom_swing_deg: float = 0.0  # Godot local +Y == QML local +Z == DBC SWING
    boom2_joint_deg: float = 0.0

    def main_geodetic(self) -> tuple[float, float, float]:
        return enu_to_geodetic(self.main_antenna_enu_m)

    def vice_geodetic(self) -> tuple[float, float, float]:
        return enu_to_geodetic(self.vice_antenna_enu_m)


@dataclass(frozen=True)
class QmlRtkState:
    """Duck-typed RTK encoder input backed by one canonical projection."""

    projection: QmlPoseProjection

    def geodetic(self) -> tuple[float, float, float]:
        return self.projection.main_geodetic()

    def vice_antenna_geodetic(self) -> tuple[float, float, float]:
        return self.projection.vice_geodetic()

    def heading_degrees(self) -> float:
        return self.projection.wire_heading_deg

    def velocity_enu(self) -> tuple[float, float, float, float]:
        return self.projection.velocity_enu_mps


class QmlCanMapper:
    def __init__(self, profile: QmlCompatibilityProfile) -> None:
        self.profile = profile
        self._previous_tick_ms: int | None = None
        self._previous_main_enu_m: Vector3 | None = None

    def project(self, sample: TelemetrySample) -> QmlPoseProjection:
        required = {"chassis", "upper", "boom", "arm", "bucket"}
        if self.profile.model_id == "sy155w":
            required.add("boom2")
        missing = required.difference(sample.bodies)
        if missing:
            raise QmlMappingError(f"telemetry sample missing bodies: {sorted(missing)}")
        _validate_sample_finite(sample, required)

        upper = sample.bodies["upper"]
        exca = qml_exca_from_godot_quaternion(upper.quat_xyzw)
        body_pitch, body_roll, body_heading = extract_qml_body_angles(
            exca, self.profile.gimbal_cosine_tolerance
        )
        calibration = self.profile.calibration
        wire_body_pitch, wire_body_roll, wire_heading = wire_body_angles(
            body_pitch, body_roll, body_heading, calibration
        )

        joint_delta_deg = self._joint_deltas(sample)
        neutral = self.profile.neutral_qml_deg
        signs = self.profile.joint_signs
        qml_joints = (
            neutral[0] + signs[0] * joint_delta_deg[0],
            neutral[1] + signs[1] * joint_delta_deg[1],
            neutral[2] + signs[2] * joint_delta_deg[2],
        )
        inverse_policy = dict(
            mnq_range_deg=self.profile.bucket_mnq_range_deg,
            tolerance_deg=self.profile.bucket_tolerance_deg,
            forward_error_deg=self.profile.joint_forward_error_deg,
        )
        boom2_joint = 0.0
        boom2_pitch = 0.0
        if self.profile.model_id == "sy155w":
            boom2_joint = self.profile.boom2_neutral_qml_deg + joint_delta_deg[3]
            boom_pitch, boom2_pitch, arm_pitch, bucket_pitch = invert_two_boom_sensor2ang(
                body_pitch,
                qml_joints,
                boom2_joint,
                calibration,
                **inverse_policy,
            )
        else:
            boom_pitch, arm_pitch, bucket_pitch = invert_sensor2ang(
                body_pitch,
                qml_joints,
                calibration,
                **inverse_policy,
            )

        imu_rpy: dict[str, tuple[float, float, float]] = {
            "body": (wire_body_roll, wire_body_pitch, body_heading),
        }
        if self.profile.model_id == "sy80u":
            # SY80 VAL swaps parser axes once more before the common service:
            # kin pitch = DBC roll + eR; kin roll = DBC pitch - eP.
            imu_rpy["body"] = (wire_body_pitch, -wire_body_roll, body_heading)
        for link, reported_pitch in zip(
            ("boom", "arm", "bucket"),
            (boom_pitch, arm_pitch, bucket_pitch),
            strict=True,
        ):
            roll, _legacy_pitch, yaw = quat_to_yup_euler_deg(sample.bodies[link].quat_xyzw)
            imu_rpy[link] = (roll, reported_pitch, yaw)
        if self.profile.model_id == "sy155w":
            roll, _, yaw = quat_to_yup_euler_deg(sample.bodies["boom2"].quat_xyzw)
            imu_rpy["boom2"] = (roll, boom2_pitch, yaw)

        slew_center_enu = godot_point_to_enu(upper.origin_m)
        main_enu = main_antenna_enu(slew_center_enu, exca, calibration)
        vice_enu = _vec_add(
            main_enu,
            _mat_vec(exca, self.profile.vice_offset_vehicle_m),
        )
        velocity = self._velocity(sample.tick_ms, main_enu)
        _require_finite("main antenna ENU", main_enu)
        _require_finite("vice antenna ENU", vice_enu)
        _require_finite("antenna velocity", velocity)
        _validate_geodetic_encoding("main antenna", enu_to_geodetic(main_enu))
        _validate_geodetic_encoding("vice antenna", enu_to_geodetic(vice_enu))
        projection = QmlPoseProjection(
            imu_rpy_deg=imu_rpy,
            body_pose_deg=(body_pitch, body_roll, body_heading),
            qml_joint_deg=qml_joints,
            exca=exca,
            main_antenna_enu_m=main_enu,
            vice_antenna_enu_m=vice_enu,
            velocity_enu_mps=velocity,
            wire_heading_deg=wire_heading,
            satellite_status=self.profile.satellite_status,
            boom_swing_deg=self._boom_swing(sample),
            boom2_joint_deg=boom2_joint,
        )
        self._previous_tick_ms = sample.tick_ms
        self._previous_main_enu_m = main_enu
        return projection

    def _velocity(
        self,
        tick_ms: int,
        main_enu_m: Vector3,
    ) -> tuple[float, float, float, float]:
        if self._previous_tick_ms is None or self._previous_main_enu_m is None:
            return 0.0, 0.0, 0.0, 0.0
        delta_ms = tick_ms - self._previous_tick_ms
        if delta_ms <= 0:
            raise QmlMappingError(
                "QML profile requires increasing telemetry ticks, "
                f"got {tick_ms} after {self._previous_tick_ms}"
            )
        scale = 1000.0 / delta_ms
        ve = (main_enu_m[0] - self._previous_main_enu_m[0]) * scale
        vn = (main_enu_m[1] - self._previous_main_enu_m[1]) * scale
        vu = (main_enu_m[2] - self._previous_main_enu_m[2]) * scale
        return ve, vn, vu, math.sqrt(ve * ve + vn * vn + vu * vu)

    def _joint_deltas(self, sample: TelemetrySample) -> tuple[float, ...]:
        pairs = (("upper", "boom"), ("boom", "arm"), ("arm", "bucket"))
        neutral = self.profile.neutral_relation_deg[1:]
        if self.profile.model_id == "sy155w":
            pairs = (("upper", "boom"), ("boom2", "arm"), ("arm", "bucket"), ("boom", "boom2"))
            neutral = (*neutral, self.profile.boom2_neutral_relation_deg)
        values = []
        for (parent, child), neutral_deg in zip(pairs, neutral, strict=True):
            relation = quat_multiply(
                quat_inverse(sample.bodies[parent].quat_xyzw),
                sample.bodies[child].quat_xyzw,
            )
            if self.profile.model_id == "sy80u" and child == "boom":
                half = math.radians(self._boom_swing(sample)) * 0.5
                relation = quat_multiply((0.0, -math.sin(half), 0.0, math.cos(half)), relation)
            neutral_quat = quat_x_degrees(neutral_deg)
            delta = quat_normalize(quat_multiply(quat_inverse(neutral_quat), relation))
            if delta[3] < 0.0:
                delta = -delta[0], -delta[1], -delta[2], -delta[3]
            off_axis = math.hypot(delta[1], delta[2])
            if off_axis > self.profile.off_axis_quaternion_tolerance:
                raise QmlMappingError(
                    f"{parent}->{child} relation is not a local-X twist: "
                    f"off-axis quaternion={off_axis:.6g}"
                )
            values.append(math.degrees(2.0 * math.atan2(delta[0], delta[3])))
        return tuple(values)

    def _boom_swing(self, sample: TelemetrySample) -> float:
        if self.profile.model_id != "sy80u":
            return 0.0
        relation = quat_multiply(
            quat_inverse(sample.bodies["upper"].quat_xyzw),
            sample.bodies["boom"].quat_xyzw,
        )
        matrix = quat_to_matrix(relation)
        # R = Ry(side swing) Rx(boom). The first column is independent of boom.
        return math.degrees(math.atan2(-matrix[2][0], matrix[0][0]))


def qml_exca_from_godot_quaternion(quaternion: Quaternion) -> Matrix3:
    godot_basis = quat_to_matrix(quaternion)
    canonical = _mat_mul(_mat_mul(C_GODOT_TO_VEHICLE, godot_basis), _transpose(C_GODOT_TO_VEHICLE))
    return _mat_mul(Q_QML_HEADING_ZERO, canonical)


def extract_qml_body_angles(
    exca: Matrix3,
    gimbal_cosine_tolerance: float,
) -> tuple[float, float, float]:
    roll_rad = math.asin(max(-1.0, min(1.0, -exca[2][0])))
    if abs(math.cos(roll_rad)) <= gimbal_cosine_tolerance:
        raise QmlMappingError("QML body attitude is at the roll gimbal singularity")
    alpha = math.atan2(exca[1][0], exca[0][0])
    pitch_rad = math.atan2(exca[2][1], exca[2][2])
    heading = wrap_degrees(-math.degrees(alpha) - 90.0)
    return math.degrees(pitch_rad), math.degrees(roll_rad), heading


def quat_to_matrix(quaternion: Quaternion) -> Matrix3:
    x, y, z, w = quat_normalize(quaternion)
    return (
        (1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - w * z), 2.0 * (x * z + w * y)),
        (2.0 * (x * y + w * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - w * x)),
        (2.0 * (x * z - w * y), 2.0 * (y * z + w * x), 1.0 - 2.0 * (x * x + y * y)),
    )


def quat_normalize(quaternion: Quaternion) -> Quaternion:
    norm = math.sqrt(sum(value * value for value in quaternion))
    if not math.isfinite(norm) or norm <= 1e-12:
        raise QmlMappingError("non-finite or zero quaternion")
    return (
        quaternion[0] / norm,
        quaternion[1] / norm,
        quaternion[2] / norm,
        quaternion[3] / norm,
    )


def quat_inverse(quaternion: Quaternion) -> Quaternion:
    x, y, z, w = quat_normalize(quaternion)
    return -x, -y, -z, w


def quat_multiply(left: Quaternion, right: Quaternion) -> Quaternion:
    lx, ly, lz, lw = left
    rx, ry, rz, rw = right
    return (
        lw * rx + lx * rw + ly * rz - lz * ry,
        lw * ry - lx * rz + ly * rw + lz * rx,
        lw * rz + lx * ry - ly * rx + lz * rw,
        lw * rw - lx * rx - ly * ry - lz * rz,
    )


def quat_x_degrees(angle_deg: float) -> Quaternion:
    half = math.radians(angle_deg) * 0.5
    return math.sin(half), 0.0, 0.0, math.cos(half)


def godot_point_to_enu(point: Vector3) -> Vector3:
    return point[0], -point[2], point[1]


def enu_to_geodetic(point: Vector3) -> tuple[float, float, float]:
    east, north, up = point
    lat = ORIGIN_LAT_DEG + north / METERS_PER_DEG_LAT
    lon = ORIGIN_LON_DEG + east / (METERS_PER_DEG_LAT * math.cos(math.radians(ORIGIN_LAT_DEG)))
    return lat, lon, ORIGIN_ALT_M + up


def wrap_degrees(value: float) -> float:
    return value % 360.0


def _validate_sample_finite(sample: TelemetrySample, bodies: set[str]) -> None:
    for name in bodies:
        pose = sample.bodies[name]
        _require_finite(f"{name} quaternion", pose.quat_xyzw)
        _require_finite(f"{name} origin", pose.origin_m)
    _require_finite(
        "telemetry scalars",
        (sample.swing_rad, sample.track_left_mps, sample.track_right_mps),
    )


def _validate_geodetic_encoding(
    label: str,
    geodetic: tuple[float, float, float],
) -> None:
    latitude, longitude, altitude = geodetic
    _require_finite(f"{label} geodetic", geodetic)
    if not -90.0 <= latitude <= 90.0 or not -180.0 <= longitude <= 180.0:
        raise QmlMappingError(f"{label} geodetic position is outside WGS84 bounds")
    altitude_mm = altitude * 1000.0
    if not -(2**31) <= altitude_mm < 2**31:
        raise QmlMappingError(f"{label} altitude does not fit the RTK int32 payload")


def _require_finite(label: str, values: tuple[float, ...]) -> None:
    if not all(math.isfinite(value) for value in values):
        raise QmlMappingError(f"{label} contains a non-finite value")


def _transpose(matrix: Matrix3) -> Matrix3:
    return (
        (matrix[0][0], matrix[1][0], matrix[2][0]),
        (matrix[0][1], matrix[1][1], matrix[2][1]),
        (matrix[0][2], matrix[1][2], matrix[2][2]),
    )


def _mat_mul(left: Matrix3, right: Matrix3) -> Matrix3:
    def row_product(row: int) -> tuple[float, float, float]:
        return (
            sum(left[row][inner] * right[inner][0] for inner in range(3)),
            sum(left[row][inner] * right[inner][1] for inner in range(3)),
            sum(left[row][inner] * right[inner][2] for inner in range(3)),
        )

    return row_product(0), row_product(1), row_product(2)


def _mat_vec(matrix: Matrix3, vector: Vector3) -> Vector3:
    return (
        sum(matrix[0][column] * vector[column] for column in range(3)),
        sum(matrix[1][column] * vector[column] for column in range(3)),
        sum(matrix[2][column] * vector[column] for column in range(3)),
    )


def _vec_add(left: Vector3, right: Vector3) -> Vector3:
    return left[0] + right[0], left[1] + right[1], left[2] + right[2]
