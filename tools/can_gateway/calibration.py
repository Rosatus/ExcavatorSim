"""GuideSystem-format calibration and its application stage.

The parameter set and the TOML schema are exactly GuideSystem's
(``[angle] [imu_car] [imu_component] [length] [offset]``), so a field
calibration change stays a data change: the gateway reads the same file the
machine's guidance system reads, and every formula that consumes those numbers
lives here instead of being spread through the projection code.

``Calibration::CalibrationParams`` in GuideSystem also carries ``m_angDMX``
(铲尖 DM 线与铲背面夹角). It is a machine-level default that GuideSystem never
writes into ``calibration.toml`` and the gateway projection never consumes, so
it is deliberately not part of this contract.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, replace
from typing import Any

Matrix3 = tuple[
    tuple[float, float, float],
    tuple[float, float, float],
    tuple[float, float, float],
]
Vector3 = tuple[float, float, float]


class CalibrationError(ValueError):
    """Invalid calibration data, or a calibrated quantity that cannot be
    represented by the target contract."""


@dataclass(frozen=True)
class CalibrationParams:
    """One immutable calibration set, field-for-field with GuideSystem."""

    # [length] (m)
    m_lMN: float
    m_lNQ: float
    m_lQK: float
    m_lMK: float
    m_lFQ: float
    m_lCF: float
    m_lQV: float
    bucketWidth: float
    # [angle] (deg)
    m_angNQF: float
    m_angKQV: float
    # [imu_car] body IMU mounting error (deg)
    roll_error_IMU_Car: float
    pitch_error_IMU_Car: float
    yaw_error_IMU_Car: float
    # [imu_component] work-equipment IMU mounting error (deg)
    pitch_error_IMU_Boom: float
    pitch_error_IMU_Arm: float
    pitch_error_IMU_Bkt: float
    # [offset] (m)
    OC_Tx: float
    OC_Ty: float
    OC_Tz: float
    GO_Tx: float
    GO_Ty: float
    GO_Tz: float
    pitch_error_IMU_Boom2: float | None = None

    @property
    def go_vehicle_m(self) -> Vector3:
        """GNSS-to-work-equipment origin offset in the vehicle frame."""
        return (self.GO_Tx, self.GO_Ty, self.GO_Tz)

    @property
    def oc_vehicle_m(self) -> Vector3:
        """Antenna-to-vehicle-origin offset in the vehicle frame."""
        return (self.OC_Tx, self.OC_Ty, self.OC_Tz)


# ── Application stage ────────────────────────────────────────────────────────
# Every function below consumes one immutable CalibrationParams. Nothing here
# reads the profile, the sample or the wire format: calibration is applied in a
# single place and the projection stage only frames the inputs and outputs.


def wire_body_angles(
    body_pitch_deg: float,
    body_roll_deg: float,
    body_heading_deg: float,
    params: CalibrationParams,
) -> tuple[float, float, float]:
    """Parser-facing body P/R/H for one calibrated body attitude.

    GuidancePeriodicService adapts parser R/P before lib_kin
    (``bodyIMUR = -parser_pitch``, ``bodyIMUP = parser_roll``), so the
    parser-facing inverse is ``P - car_roll`` / ``R + car_pitch``.
    """
    wire_pitch = body_pitch_deg - params.roll_error_IMU_Car
    wire_roll = body_roll_deg + params.pitch_error_IMU_Car
    wire_heading = _wrap_degrees(body_heading_deg - params.yaw_error_IMU_Car)
    return wire_pitch, wire_roll, wire_heading


def sensor2ang_from_reported(
    body_phi_pitch_deg: float,
    boom_pitch_deg: float,
    arm_pitch_deg: float,
    bucket_pitch_deg: float,
    params: CalibrationParams,
) -> tuple[float, float, float]:
    """Forward GuideSystem ``lib_kin.Sensor2Ang`` over reported wire pitches."""
    boom_imu = -boom_pitch_deg
    arm_imu = -arm_pitch_deg
    bucket_imu = -bucket_pitch_deg
    boom_phi = boom_imu + params.pitch_error_IMU_Boom - body_phi_pitch_deg
    arm_phi = 180.0 - (
        boom_imu + params.pitch_error_IMU_Boom - arm_imu - params.pitch_error_IMU_Arm
    )
    mnq = bucket_imu + params.pitch_error_IMU_Bkt - arm_imu - params.pitch_error_IMU_Arm
    return boom_phi, arm_phi, bucket_phi_from_mnq(mnq, params)


def bucket_phi_from_mnq(mnq_deg: float, params: CalibrationParams) -> float:
    """Bucket four-bar closure for a given N-Q angle (degrees)."""
    mn = params.m_lMN
    nq = params.m_lNQ
    qk = params.m_lQK
    mk = params.m_lMK
    mq_sq = mn * mn + nq * nq - 2.0 * nq * mn * math.cos(math.radians(mnq_deg))
    mq = math.sqrt(max(0.0, mq_sq))
    if mq <= 1e-12:
        raise CalibrationError("QML bucket linkage produced a zero MQ length")
    cos_mqn = _clamp_unit((mq * mq + nq * nq - mn * mn) / (2.0 * mq * nq))
    cos_kqm = _clamp_unit((qk * qk + mq * mq - mk * mk) / (2.0 * qk * mq))
    return (
        360.0
        - params.m_angNQF
        - math.degrees(math.acos(cos_kqm) + math.acos(cos_mqn))
        - params.m_angKQV
    )


def invert_sensor2ang(
    body_phi_pitch_deg: float,
    qml_joint_deg: tuple[float, float, float],
    params: CalibrationParams,
    *,
    mnq_range_deg: tuple[float, float],
    tolerance_deg: float,
    forward_error_deg: float,
) -> tuple[float, float, float]:
    """Canonical reported pitches that make ``lib_kin`` yield the joint targets.

    The acceptance thresholds are supplied by the caller: they are profile
    policy, not calibration data.
    """
    boom_phi, arm_phi, bucket_phi = qml_joint_deg
    boom_pitch = params.pitch_error_IMU_Boom - body_phi_pitch_deg - boom_phi
    arm_pitch = (
        boom_pitch - params.pitch_error_IMU_Boom + params.pitch_error_IMU_Arm + 180.0 - arm_phi
    )
    mnq = invert_bucket_phi(
        bucket_phi,
        params,
        mnq_range_deg=mnq_range_deg,
        tolerance_deg=tolerance_deg,
    )
    bucket_pitch = arm_pitch + params.pitch_error_IMU_Bkt - params.pitch_error_IMU_Arm - mnq
    roundtrip = sensor2ang_from_reported(
        body_phi_pitch_deg,
        boom_pitch,
        arm_pitch,
        bucket_pitch,
        params,
    )
    errors = [
        abs(actual - expected) for actual, expected in zip(roundtrip, qml_joint_deg, strict=True)
    ]
    if max(errors) > forward_error_deg:
        raise CalibrationError(f"Sensor2Ang inverse forward error too large: {errors}")
    return boom_pitch, arm_pitch, bucket_pitch


def invert_two_boom_sensor2ang(
    body_pitch: float,
    joints: tuple[float, float, float],
    boom2_relative_deg: float,
    params: CalibrationParams,
    **policy: Any,
) -> tuple[float, float, float, float]:
    """SY135 sensor convention extended by one absolute boom IMU.

    The second boom is the parent of the arm. Its pitch reports cumulative
    boom + fold elevation; the first boom retains its own sensor reading.
    """
    if params.pitch_error_IMU_Boom2 is None:
        raise CalibrationError("second boom calibration is missing")
    boom, arm, bucket = joints
    second, arm_pitch, bucket_pitch = invert_sensor2ang(
        body_pitch,
        (boom + boom2_relative_deg, arm, bucket),
        replace(params, pitch_error_IMU_Boom=params.pitch_error_IMU_Boom2),
        **policy,
    )
    first = params.pitch_error_IMU_Boom - body_pitch - boom
    return first, second, arm_pitch, bucket_pitch


def invert_bucket_phi(
    target_phi_deg: float,
    params: CalibrationParams,
    *,
    mnq_range_deg: tuple[float, float],
    tolerance_deg: float,
) -> float:
    """Monotonic bisection for the N-Q angle that renders ``target_phi_deg``."""
    low, high = mnq_range_deg
    low_value = bucket_phi_from_mnq(low, params)
    high_value = bucket_phi_from_mnq(high, params)
    increasing = high_value > low_value
    minimum, maximum = sorted((low_value, high_value))
    if not minimum <= target_phi_deg <= maximum:
        raise CalibrationError(
            f"bucket target {target_phi_deg:.6f} deg outside invertible range "
            f"[{minimum:.6f}, {maximum:.6f}]"
        )
    for _iteration in range(80):
        middle = (low + high) * 0.5
        value = bucket_phi_from_mnq(middle, params)
        if abs(value - target_phi_deg) <= tolerance_deg:
            return middle
        if (value < target_phi_deg) == increasing:
            low = middle
        else:
            high = middle
    result = (low + high) * 0.5
    error = abs(bucket_phi_from_mnq(result, params) - target_phi_deg)
    if error > tolerance_deg:
        raise CalibrationError(f"bucket inverse did not converge: error={error:.9g} deg")
    return result


def main_antenna_enu(
    slew_center_enu: Vector3,
    exca: Matrix3,
    params: CalibrationParams,
) -> Vector3:
    """Main antenna position for the contract ``GNSSA = O - Exca * GO``."""
    return _vec_sub(slew_center_enu, _mat_vec(exca, params.go_vehicle_m))


# ── Strict TOML loading ──────────────────────────────────────────────────────


def parse_calibration(document: dict[str, Any]) -> CalibrationParams:
    """Read one GuideSystem-schema calibration document, failing closed."""
    length = _table(document, "length")
    angle = _table(document, "angle")
    car = _table(document, "imu_car")
    component = _table(document, "imu_component")
    offset = _table(document, "offset")
    return CalibrationParams(
        m_lMN=_positive(length, "m_lMN"),
        m_lNQ=_positive(length, "m_lNQ"),
        m_lQK=_positive(length, "m_lQK"),
        m_lMK=_positive(length, "m_lMK"),
        m_lFQ=_positive(length, "m_lFQ"),
        m_lCF=_positive(length, "m_lCF"),
        m_lQV=_positive(length, "m_lQV"),
        bucketWidth=_positive(length, "bucketWidth"),
        m_angNQF=_number(angle, "m_angNQF"),
        m_angKQV=_number(angle, "m_angKQV"),
        roll_error_IMU_Car=_number(car, "roll"),
        pitch_error_IMU_Car=_number(car, "pitch"),
        yaw_error_IMU_Car=_number(car, "yaw"),
        pitch_error_IMU_Boom=_number(component, "pitch_boom"),
        pitch_error_IMU_Arm=_number(component, "pitch_arm"),
        pitch_error_IMU_Bkt=_number(component, "pitch_bucket"),
        OC_Tx=_number(offset, "OC_Tx"),
        OC_Ty=_number(offset, "OC_Ty"),
        OC_Tz=_number(offset, "OC_Tz"),
        GO_Tx=_number(offset, "GO_Tx"),
        GO_Ty=_number(offset, "GO_Ty"),
        GO_Tz=_number(offset, "GO_Tz"),
        pitch_error_IMU_Boom2=_number(component, "pitch_boom2")
        if "pitch_boom2" in component
        else None,
    )


def _table(document: dict[str, Any], key: str) -> dict[str, Any]:
    value = document.get(key)
    if not isinstance(value, dict):
        raise CalibrationError(f"missing calibration table [{key}]")
    return value


def _number(table: dict[str, Any], key: str) -> float:
    value = table.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise CalibrationError(f"{key} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise CalibrationError(f"{key} must be finite")
    return result


def _positive(table: dict[str, Any], key: str) -> float:
    value = _number(table, key)
    if value <= 0.0:
        raise CalibrationError(f"{key} must be positive")
    return value


# ── Local maths ──────────────────────────────────────────────────────────────


def _wrap_degrees(value: float) -> float:
    return value % 360.0


def _clamp_unit(value: float) -> float:
    return max(-1.0, min(1.0, value))


def _mat_vec(matrix: Matrix3, vector: Vector3) -> Vector3:
    return (
        sum(matrix[0][column] * vector[column] for column in range(3)),
        sum(matrix[1][column] * vector[column] for column in range(3)),
        sum(matrix[2][column] * vector[column] for column in range(3)),
    )


def _vec_sub(left: Vector3, right: Vector3) -> Vector3:
    return left[0] - right[0], left[1] - right[1], left[2] - right[2]
