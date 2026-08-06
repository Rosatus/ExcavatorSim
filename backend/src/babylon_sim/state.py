"""Immutable authoritative motion state shared by runtime and wire adapters."""

from __future__ import annotations

from collections.abc import Mapping
from dataclasses import dataclass, field
from math import isfinite
from types import MappingProxyType

from .constants import ACTIVE_JOINT_NAMES

Matrix4 = tuple[tuple[float, float, float, float], ...]


@dataclass(frozen=True)
class SimulationState:
    timestamp: float
    sequence_number: int
    source: str
    model_version: str
    calibration_version: str
    joint_position: tuple[float, ...]
    joint_velocity: tuple[float, ...]
    joint_acceleration: tuple[float, ...]
    frame_transforms: Mapping[str, Matrix4] = field(default_factory=dict)
    quality_flags: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not isfinite(self.timestamp) or self.timestamp < 0.0:
            raise ValueError("timestamp must be finite and non-negative")
        if self.sequence_number < 0:
            raise ValueError("sequence_number must be non-negative")
        if not self.source or not self.model_version or not self.calibration_version:
            raise ValueError("source and version fields must not be empty")
        expected = len(ACTIVE_JOINT_NAMES)
        vectors = (self.joint_position, self.joint_velocity, self.joint_acceleration)
        if any(len(vector) != expected for vector in vectors):
            raise ValueError(f"joint vectors must contain {expected} values")
        if any(not isfinite(value) for vector in vectors for value in vector):
            raise ValueError("joint state values must be finite")
        normalized_transforms: dict[str, Matrix4] = {}
        for frame_name, transform in self.frame_transforms.items():
            if not frame_name:
                raise ValueError("frame transform names must not be empty")
            if len(transform) != 4 or any(len(row) != 4 for row in transform):
                raise ValueError(f"frame transform for {frame_name!r} must be 4x4")
            matrix = tuple(tuple(float(value) for value in row) for row in transform)
            if any(not isfinite(value) for row in matrix for value in row):
                raise ValueError(f"frame transform for {frame_name!r} must be finite")
            normalized_transforms[frame_name] = matrix  # type: ignore[assignment]
        object.__setattr__(self, "frame_transforms", MappingProxyType(normalized_transforms))
        object.__setattr__(self, "quality_flags", tuple(dict.fromkeys(self.quality_flags)))
