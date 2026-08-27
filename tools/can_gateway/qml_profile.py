"""Strict QML compatibility-profile and calibration loading.

The reference QML repository is an offline oracle only. Runtime profiles and
calibration bytes live with the gateway and are SHA-256 bound so a field
calibration change cannot silently alter emitted CAN semantics.
"""

from __future__ import annotations

import hashlib
import math
import sys
import tomllib
from dataclasses import dataclass
from pathlib import Path
from typing import Any

BUILTIN_PROFILE = "builtin:qml-sy135-ground-truth"
BUILTIN_PROFILE_FILE = "qml_sy135_ground_truth.toml"


class QmlProfileError(ValueError):
    """Raised when a requested compatibility profile is incomplete or stale."""


@dataclass(frozen=True)
class QmlCalibration:
    car_pitch_error_deg: float
    car_roll_error_deg: float
    car_yaw_error_deg: float
    boom_pitch_error_deg: float
    arm_pitch_error_deg: float
    bucket_pitch_error_deg: float
    go_vehicle_m: tuple[float, float, float]
    length_mn_m: float
    length_nq_m: float
    length_qk_m: float
    length_mk_m: float
    angle_nqf_deg: float
    angle_kqv_deg: float


@dataclass(frozen=True)
class QmlCompatibilityProfile:
    version: int
    target: str
    model_id: str
    calibration_sha256: str
    calibration: QmlCalibration
    neutral_qml_deg: tuple[float, float, float]
    joint_signs: tuple[float, float, float]
    neutral_relation_deg: tuple[float, float, float, float]
    bucket_mnq_range_deg: tuple[float, float]
    bucket_tolerance_deg: float
    vice_offset_vehicle_m: tuple[float, float, float]
    satellite_status: int
    off_axis_quaternion_tolerance: float
    gimbal_cosine_tolerance: float
    joint_forward_error_deg: float
    source_path: Path
    calibration_path: Path


def resource_root() -> Path:
    frozen_root = getattr(sys, "_MEIPASS", None)
    if frozen_root is not None:
        return Path(frozen_root) / "resources"
    return Path(__file__).resolve().parent / "resources"


def resolve_profile_path(value: str | Path) -> Path:
    if str(value) == BUILTIN_PROFILE:
        return resource_root() / BUILTIN_PROFILE_FILE
    return Path(value).expanduser().resolve()


def load_qml_profile(
    profile_value: str | Path,
    calibration_override: str | Path | None = None,
) -> QmlCompatibilityProfile:
    profile_path = resolve_profile_path(profile_value)
    profile_doc = _load_toml(profile_path, "compatibility profile")
    identity = _table(profile_doc, "profile")
    version = _integer(identity, "version")
    target = _string(identity, "target")
    model_id = _string(identity, "model_id")
    if version != 1:
        raise QmlProfileError(f"unsupported profile version {version}")
    if target != "qml-guidance-3d":
        raise QmlProfileError(f"unsupported profile target {target!r}")
    if model_id != "sy135":
        raise QmlProfileError(f"unsupported QML model {model_id!r}")

    expected_hash = _string(identity, "calibration_sha256").lower()
    if len(expected_hash) != 64 or any(char not in "0123456789abcdef" for char in expected_hash):
        raise QmlProfileError("profile.calibration_sha256 must be 64 lowercase hex characters")
    if calibration_override is None:
        calibration_name = _string(identity, "calibration_file")
        calibration_path = (profile_path.parent / calibration_name).resolve()
    else:
        calibration_path = Path(calibration_override).expanduser().resolve()
    calibration_bytes = _read_bytes(calibration_path, "QML calibration")
    actual_hash = hashlib.sha256(calibration_bytes).hexdigest()
    if actual_hash != expected_hash:
        raise QmlProfileError(
            f"QML calibration SHA-256 mismatch: expected {expected_hash}, got {actual_hash}"
        )
    try:
        calibration_doc = tomllib.loads(calibration_bytes.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise QmlProfileError(f"invalid QML calibration {calibration_path}: {exc}") from exc
    calibration = _parse_calibration(calibration_doc)

    frames = _table(profile_doc, "frames")
    required_frames = {"body_imu": "upper", "rtk_attitude": "upper", "slew_center": "upper"}
    for key, expected in required_frames.items():
        actual = _string(frames, key)
        if actual != expected:
            raise QmlProfileError(f"frames.{key} must be {expected!r}, got {actual!r}")

    alignment = _table(profile_doc, "alignment")
    neutral = (
        _number(alignment, "boom_phi_neutral_deg"),
        _number(alignment, "arm_phi_neutral_deg"),
        _number(alignment, "bucket_phi_neutral_deg"),
    )
    signs = (
        _unit_sign(alignment, "boom_sign"),
        _unit_sign(alignment, "arm_sign"),
        _unit_sign(alignment, "bucket_sign"),
    )
    neutral_relation = _table(profile_doc, "neutral_relation")
    neutral_relation_deg = (
        _number(neutral_relation, "swing_deg"),
        _number(neutral_relation, "boom_deg"),
        _number(neutral_relation, "arm_deg"),
        _number(neutral_relation, "bucket_deg"),
    )
    bucket_inverse = _table(profile_doc, "bucket_inverse")
    bucket_range = (
        _number(bucket_inverse, "min_mnq_deg"),
        _number(bucket_inverse, "max_mnq_deg"),
    )
    if not bucket_range[0] < bucket_range[1]:
        raise QmlProfileError("bucket inverse interval must be increasing")
    bucket_tolerance = _positive(bucket_inverse, "tolerance_deg")
    gnss = _table(profile_doc, "gnss")
    vice_offset = _vector3(gnss, "vice_offset_vehicle_m")
    satellite_status = _integer(gnss, "satellite_status")
    if not 0 <= satellite_status <= 255:
        raise QmlProfileError("gnss.satellite_status must fit uint8")
    tolerance = _table(profile_doc, "tolerance")
    return QmlCompatibilityProfile(
        version=version,
        target=target,
        model_id=model_id,
        calibration_sha256=expected_hash,
        calibration=calibration,
        neutral_qml_deg=neutral,
        joint_signs=signs,
        neutral_relation_deg=neutral_relation_deg,
        bucket_mnq_range_deg=bucket_range,
        bucket_tolerance_deg=bucket_tolerance,
        vice_offset_vehicle_m=vice_offset,
        satellite_status=satellite_status,
        off_axis_quaternion_tolerance=_positive(tolerance, "off_axis_quaternion"),
        gimbal_cosine_tolerance=_positive(tolerance, "gimbal_cosine"),
        joint_forward_error_deg=_positive(tolerance, "joint_forward_error_deg"),
        source_path=profile_path,
        calibration_path=calibration_path,
    )


def _parse_calibration(doc: dict[str, Any]) -> QmlCalibration:
    angle = _table(doc, "angle")
    car = _table(doc, "imu_car")
    component = _table(doc, "imu_component")
    length = _table(doc, "length")
    offset = _table(doc, "offset")
    result = QmlCalibration(
        car_pitch_error_deg=_number(car, "pitch"),
        car_roll_error_deg=_number(car, "roll"),
        car_yaw_error_deg=_number(car, "yaw"),
        boom_pitch_error_deg=_number(component, "pitch_boom"),
        arm_pitch_error_deg=_number(component, "pitch_arm"),
        bucket_pitch_error_deg=_number(component, "pitch_bucket"),
        go_vehicle_m=(
            _number(offset, "GO_Tx"),
            _number(offset, "GO_Ty"),
            _number(offset, "GO_Tz"),
        ),
        length_mn_m=_positive(length, "m_lMN"),
        length_nq_m=_positive(length, "m_lNQ"),
        length_qk_m=_positive(length, "m_lQK"),
        length_mk_m=_positive(length, "m_lMK"),
        angle_nqf_deg=_number(angle, "m_angNQF"),
        angle_kqv_deg=_number(angle, "m_angKQV"),
    )
    return result


def _load_toml(path: Path, label: str) -> dict[str, Any]:
    raw = _read_bytes(path, label)
    try:
        return tomllib.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, tomllib.TOMLDecodeError) as exc:
        raise QmlProfileError(f"invalid {label} {path}: {exc}") from exc


def _read_bytes(path: Path, label: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as exc:
        raise QmlProfileError(f"cannot read {label} {path}: {exc}") from exc


def _table(doc: dict[str, Any], key: str) -> dict[str, Any]:
    value = doc.get(key)
    if not isinstance(value, dict):
        raise QmlProfileError(f"missing table [{key}]")
    return value


def _string(table: dict[str, Any], key: str) -> str:
    value = table.get(key)
    if not isinstance(value, str) or not value:
        raise QmlProfileError(f"{key} must be a non-empty string")
    return value


def _integer(table: dict[str, Any], key: str) -> int:
    value = table.get(key)
    if isinstance(value, bool) or not isinstance(value, int):
        raise QmlProfileError(f"{key} must be an integer")
    return value


def _number(table: dict[str, Any], key: str) -> float:
    value = table.get(key)
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise QmlProfileError(f"{key} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise QmlProfileError(f"{key} must be finite")
    return result


def _positive(table: dict[str, Any], key: str) -> float:
    value = _number(table, key)
    if value <= 0.0:
        raise QmlProfileError(f"{key} must be positive")
    return value


def _unit_sign(table: dict[str, Any], key: str) -> float:
    value = _number(table, key)
    if value not in (-1.0, 1.0):
        raise QmlProfileError(f"{key} must be -1 or +1")
    return value


def _vector3(table: dict[str, Any], key: str) -> tuple[float, float, float]:
    value = table.get(key)
    if not isinstance(value, list) or len(value) != 3:
        raise QmlProfileError(f"{key} must contain exactly three numbers")
    converted = []
    for index, item in enumerate(value):
        converted.append(_number({f"{key}[{index}]": item}, f"{key}[{index}]"))
    return converted[0], converted[1], converted[2]
