"""Motion-relevant subset of the versioned machine calibration."""

from __future__ import annotations

import json
import math
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .constants import ACTIVE_JOINT_NAMES, CALIBRATION_SCHEMA_VERSION


@dataclass(frozen=True)
class JointLimit:
    name: str
    min_position: float
    max_position: float
    max_velocity: float
    max_acceleration: float

    def __post_init__(self) -> None:
        values = (self.min_position, self.max_position, self.max_velocity, self.max_acceleration)
        if not self.name or any(not math.isfinite(value) for value in values):
            raise ValueError("joint limit name and values must be valid")
        if self.min_position >= self.max_position:
            raise ValueError(f"joint limit minimum must be below maximum for {self.name!r}")
        if self.max_velocity <= 0.0 or self.max_acceleration <= 0.0:
            raise ValueError(f"joint velocity and acceleration must be positive for {self.name!r}")

    def clamp(self, position: float) -> float:
        return min(max(position, self.min_position), self.max_position)


@dataclass(frozen=True)
class CylinderCalibration:
    name: str
    joint_name: str
    anchor_a: float
    anchor_b: float
    angle_offset: float

    def __post_init__(self) -> None:
        values = (self.anchor_a, self.anchor_b, self.angle_offset)
        if (
            not self.name
            or not self.joint_name
            or any(not math.isfinite(value) for value in values)
        ):
            raise ValueError("cylinder calibration fields must be valid")
        if self.anchor_a <= 0.0 or self.anchor_b <= 0.0:
            raise ValueError(f"cylinder anchors must be positive for {self.name!r}")

    def length(self, joint_angle: float) -> float:
        included_angle = joint_angle + self.angle_offset
        squared = (
            self.anchor_a**2
            + self.anchor_b**2
            - 2.0 * self.anchor_a * self.anchor_b * math.cos(included_angle)
        )
        return math.sqrt(max(0.0, squared))


@dataclass(frozen=True)
class MachineCalibration:
    schema_version: str
    calibration_version: str
    quality: str
    joint_limits: tuple[JointLimit, ...]
    cylinders: tuple[CylinderCalibration, ...]

    def __post_init__(self) -> None:
        if not self.schema_version or not self.calibration_version or not self.quality:
            raise ValueError("calibration versions and quality must not be empty")
        if tuple(limit.name for limit in self.joint_limits) != ACTIVE_JOINT_NAMES:
            raise ValueError(f"joint limits must follow active joint order {ACTIVE_JOINT_NAMES}")
        if tuple(cylinder.joint_name for cylinder in self.cylinders) != ACTIVE_JOINT_NAMES[1:]:
            raise ValueError("cylinders must follow boom, arm, and bucket joint order")
        names = tuple(cylinder.name for cylinder in self.cylinders)
        if len(set(names)) != len(names):
            raise ValueError("cylinder calibration names must be unique")

    @classmethod
    def from_json(cls, path: str | Path) -> MachineCalibration:
        source = Path(path)
        if not source.is_file():
            raise ValueError(f"calibration file does not exist: {source}")
        try:
            payload = json.loads(source.read_text(encoding="utf-8"))
            if not isinstance(payload, dict):
                raise TypeError("calibration root must be an object")
            return cls.from_mapping(payload)
        except (json.JSONDecodeError, KeyError, TypeError, ValueError) as exc:
            raise ValueError(f"invalid calibration file {source}: {exc}") from exc

    @classmethod
    def from_mapping(cls, payload: dict[str, Any]) -> MachineCalibration:
        observed_schema = str(payload["schema_version"])
        if observed_schema != CALIBRATION_SCHEMA_VERSION:
            raise ValueError(
                f"unsupported calibration schema {observed_schema!r}; "
                f"this build supports {CALIBRATION_SCHEMA_VERSION!r}"
            )
        limit_payload = payload["joint_limits"]
        if not isinstance(limit_payload, dict):
            raise TypeError("joint_limits must be an object")
        joint_limits = tuple(
            JointLimit(
                name=name,
                min_position=float(limit_payload[name]["min_position_rad"]),
                max_position=float(limit_payload[name]["max_position_rad"]),
                max_velocity=float(limit_payload[name]["max_velocity_rad_s"]),
                max_acceleration=float(limit_payload[name]["max_acceleration_rad_s2"]),
            )
            for name in ACTIVE_JOINT_NAMES
        )
        raw_cylinders = payload["cylinders"]
        if not isinstance(raw_cylinders, list):
            raise TypeError("cylinders must be an array")
        cylinders = tuple(
            CylinderCalibration(
                name=str(item["name"]),
                joint_name=str(item["joint"]),
                anchor_a=float(item["anchor_a_m"]),
                anchor_b=float(item["anchor_b_m"]),
                angle_offset=float(item["angle_offset_rad"]),
            )
            for item in raw_cylinders
        )
        return cls(
            schema_version=observed_schema,
            calibration_version=str(payload["calibration_version"]),
            quality=str(payload["quality"]),
            joint_limits=joint_limits,
            cylinders=cylinders,
        )

    def cylinder_lengths(self, joint_positions: Iterable[float]) -> tuple[float, ...]:
        positions = tuple(float(value) for value in joint_positions)
        if len(positions) != len(ACTIVE_JOINT_NAMES):
            raise ValueError(f"expected {len(ACTIVE_JOINT_NAMES)} joint positions")
        angles_by_name = dict(zip(ACTIVE_JOINT_NAMES, positions, strict=True))
        return tuple(
            cylinder.length(angles_by_name[cylinder.joint_name]) for cylinder in self.cylinders
        )
