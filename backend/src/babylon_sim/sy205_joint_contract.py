"""Adapt the legacy SY205 asset coordinates to the product's SY135 joint convention.

The raw URDF and its import/parity fixtures retain asset coordinates. Only the
SY205 compatibility runtime uses this adapter; SY135 and the CAN gateway do not.
"""

from __future__ import annotations

import json
from collections.abc import Iterable
from dataclasses import dataclass, replace

import numpy as np

from .calibration import JointLimit, MachineCalibration
from .model import ExcavatorModel
from .paths import PROJECT_ROOT


@dataclass
class Sy205JointModel(ExcavatorModel):
    asset_signs: tuple[float, ...] = (1.0, -1.0, -1.0, -1.0)

    def configuration_from_angles(self, joint_angles: Iterable[float]) -> np.ndarray:
        angles = tuple(joint_angles)
        if len(angles) != len(self.asset_signs):
            raise ValueError("expected four joint angles")
        return super().configuration_from_angles(
            float(angle) * sign for angle, sign in zip(angles, self.asset_signs, strict=True)
        )


def adapt_sy205_model(model: ExcavatorModel) -> Sy205JointModel:
    """Wrap a raw asset model without mutating it or changing its URDF."""
    if model.model_version != "sy205-glb-urdf-v4":
        raise ValueError("SY205 joint adapter requires the reviewed SY205 asset")
    return Sy205JointModel(
        urdf_path=model.urdf_path,
        pin_model=model.pin_model,
        pin_data=model.pin_model.createData(),
        active_joints=model.active_joints,
        frame_names=model.frame_names,
        model_version=model.model_version,
    )


def sy205_runtime_calibration(calibration: MachineCalibration) -> MachineCalibration:
    """Use the same bounded joint contract as the SY205 Godot runtime."""
    rig = json.loads(
        (PROJECT_ROOT / "godot/client/resources/physics/sy205_physics_rig.json").read_text(
            encoding="utf-8"
        )
    )
    limits = tuple(
        JointLimit(
            name=joint["name"],
            min_position=joint["limit_rad"][0],
            max_position=joint["limit_rad"][1],
            max_velocity=joint["actuator"]["max_velocity_rad_s"],
            max_acceleration=joint["actuator"]["max_acceleration_rad_s2"],
        )
        for joint in rig["joints"]
    )
    # cos(q + offset) is invariant when both q and offset are negated.
    cylinders = tuple(
        replace(cylinder, angle_offset=-cylinder.angle_offset) for cylinder in calibration.cylinders
    )
    return replace(calibration, joint_limits=limits, cylinders=cylinders)
