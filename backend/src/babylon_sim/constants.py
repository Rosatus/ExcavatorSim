"""Stable domain constants that do not import the Pinocchio runtime."""

from __future__ import annotations

ACTIVE_JOINT_NAMES = ("swing_joint", "boom_joint", "arm_joint", "bucket_joint")
IMU_FRAME_NAMES = ("swing_imu_link", "boom_imu_link", "arm_imu_link", "bucket_imu_link")
REQUIRED_FRAME_NAMES = (
    "base_link",
    "upper_structure_link",
    "boom_link",
    "arm_link",
    "bucket_link",
    "tooth_center",
    "tooth_left",
    "tooth_right",
    "gnss_link",
    *IMU_FRAME_NAMES,
)

MODEL_VERSION = "docs-urdf-v3"
CALIBRATION_SCHEMA_VERSION = "machine-calibration-v2"
STATE_SCHEMA_VERSION = "babylon-sim-state-v2"
SOFTWARE_VERSION = "0.1.0"

SIMULATION_HZ = 100
SIMULATION_DT_SECONDS = 1.0 / SIMULATION_HZ
DISPLAY_HZ = 30
INPUT_HEARTBEAT_SECONDS = 0.04
INPUT_LEASE_SECONDS = 0.2
