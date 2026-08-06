"""URDF validation and deterministic Pinocchio frame kinematics."""

from __future__ import annotations

import math
import xml.etree.ElementTree as ET
from collections.abc import Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import numpy as np
import pinocchio as pin  # type: ignore[import-untyped]

from .constants import ACTIVE_JOINT_NAMES, MODEL_VERSION, REQUIRED_FRAME_NAMES
from .state import Matrix4, SimulationState


class ModelValidationError(ValueError):
    """Raised when the vendored model violates the runtime structure contract."""


@dataclass(frozen=True)
class JointDefinition:
    name: str
    parent: str
    child: str
    joint_type: str


def _as_matrix4(matrix: np.ndarray) -> Matrix4:
    rows = tuple(tuple(float(value) for value in row) for row in matrix.tolist())
    return rows  # type: ignore[return-value]


@dataclass
class ExcavatorModel:
    urdf_path: Path
    pin_model: pin.Model
    pin_data: Any
    active_joints: tuple[JointDefinition, ...]
    frame_names: tuple[str, ...]

    @classmethod
    def from_urdf(cls, urdf_path: str | Path) -> ExcavatorModel:
        path = Path(urdf_path)
        if not path.is_file():
            raise ModelValidationError(f"URDF file does not exist: {path}")
        try:
            root = ET.parse(path).getroot()
        except ET.ParseError as exc:
            raise ModelValidationError(f"invalid URDF XML: {path}") from exc
        if root.tag != "robot":
            raise ModelValidationError("URDF root element must be <robot>")

        links = {element.attrib.get("name") for element in root.findall("link")}
        joints: dict[str, JointDefinition] = {}
        for element in root.findall("joint"):
            name = element.attrib.get("name")
            parent = element.find("parent")
            child = element.find("child")
            if not name or parent is None or child is None:
                continue
            parent_name = parent.attrib.get("link")
            child_name = child.attrib.get("link")
            if not parent_name or not child_name:
                continue
            joints[name] = JointDefinition(
                name=name,
                parent=parent_name,
                child=child_name,
                joint_type=element.attrib.get("type", ""),
            )

        missing_joints = [name for name in ACTIVE_JOINT_NAMES if name not in joints]
        if missing_joints:
            raise ModelValidationError(f"missing required joints: {', '.join(missing_joints)}")
        wrong_types = [
            name
            for name in ACTIVE_JOINT_NAMES
            if joints[name].joint_type not in {"continuous", "revolute"}
        ]
        if wrong_types:
            raise ModelValidationError(
                f"active joints must be continuous or revolute: {', '.join(wrong_types)}"
            )
        referenced_links = {
            link_name
            for joint_name in ACTIVE_JOINT_NAMES
            for link_name in (joints[joint_name].parent, joints[joint_name].child)
        }
        missing_links = sorted(referenced_links - links)
        if missing_links:
            raise ModelValidationError(
                f"joint references missing links: {', '.join(missing_links)}"
            )
        missing_frames = sorted(set(REQUIRED_FRAME_NAMES) - links)
        if missing_frames:
            raise ModelValidationError(
                f"missing required links/frames: {', '.join(missing_frames)}"
            )

        try:
            pin_model = pin.buildModelFromUrdf(str(path))
        except Exception as exc:  # Pinocchio exposes multiple C++ exception types.
            raise ModelValidationError(f"Pinocchio could not load URDF: {path}") from exc
        if not set(ACTIVE_JOINT_NAMES).issubset(set(pin_model.names)):
            raise ModelValidationError("Pinocchio model is missing one or more active joints")
        if pin_model.nv != len(ACTIVE_JOINT_NAMES):
            raise ModelValidationError(
                f"expected {len(ACTIVE_JOINT_NAMES)} active velocity coordinates, "
                f"got {pin_model.nv}"
            )
        pin_frames = {frame.name for frame in pin_model.frames}
        missing_pin_frames = sorted(set(REQUIRED_FRAME_NAMES) - pin_frames)
        if missing_pin_frames:
            raise ModelValidationError(
                f"Pinocchio model is missing frames: {', '.join(missing_pin_frames)}"
            )
        return cls(
            urdf_path=path,
            pin_model=pin_model,
            pin_data=pin_model.createData(),
            active_joints=tuple(joints[name] for name in ACTIVE_JOINT_NAMES),
            frame_names=REQUIRED_FRAME_NAMES,
        )

    def configuration_from_angles(self, joint_angles: Iterable[float]) -> np.ndarray:
        angles = tuple(float(angle) for angle in joint_angles)
        if len(angles) != len(ACTIVE_JOINT_NAMES):
            raise ValueError(f"expected {len(ACTIVE_JOINT_NAMES)} joint angles")
        if any(not math.isfinite(angle) for angle in angles):
            raise ValueError("joint angles must be finite")
        configuration = pin.neutral(self.pin_model)
        for joint_name, angle in zip(ACTIVE_JOINT_NAMES, angles, strict=True):
            joint_id = self.pin_model.getJointId(joint_name)
            q_index = self.pin_model.idx_qs[joint_id]
            joint_configuration_size = self.pin_model.joints[joint_id].nq
            if joint_configuration_size == 2:
                configuration[q_index : q_index + 2] = (math.cos(angle), math.sin(angle))
            elif joint_configuration_size == 1:
                configuration[q_index] = angle
            else:
                raise ModelValidationError(
                    f"unsupported Pinocchio configuration size for {joint_name!r}: "
                    f"{joint_configuration_size}"
                )
        return np.asarray(configuration, dtype=np.float64)

    def frame_transforms(self, joint_angles: Iterable[float]) -> dict[str, Matrix4]:
        configuration = self.configuration_from_angles(joint_angles)
        data = self.pin_data
        pin.forwardKinematics(self.pin_model, data, configuration)
        pin.updateFramePlacements(self.pin_model, data)
        return {
            frame_name: _as_matrix4(data.oMf[self.pin_model.getFrameId(frame_name)].homogeneous)
            for frame_name in self.frame_names
        }

    def make_state(
        self,
        joint_angles: Iterable[float],
        *,
        timestamp: float,
        sequence_number: int,
        calibration_version: str,
        joint_velocity: Iterable[float],
        joint_acceleration: Iterable[float],
        source: str,
        quality_flags: Iterable[str] = (),
    ) -> SimulationState:
        angles = tuple(float(value) for value in joint_angles)
        velocities = tuple(float(value) for value in joint_velocity)
        accelerations = tuple(float(value) for value in joint_acceleration)
        return SimulationState(
            timestamp=timestamp,
            sequence_number=sequence_number,
            source=source,
            model_version=MODEL_VERSION,
            calibration_version=calibration_version,
            joint_position=angles,
            joint_velocity=velocities,
            joint_acceleration=accelerations,
            frame_transforms=self.frame_transforms(angles),
            quality_flags=tuple(quality_flags),
        )
