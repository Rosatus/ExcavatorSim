from __future__ import annotations

import pytest

from babylon_sim.calibration import MachineCalibration
from babylon_sim.constants import ACTIVE_JOINT_NAMES


def test_loads_motion_calibration(calibration: MachineCalibration) -> None:
    assert tuple(limit.name for limit in calibration.joint_limits) == ACTIVE_JOINT_NAMES
    assert calibration.calibration_version == "m1-provisional-3"
    assert calibration.quality == "provisional"
    assert all(limit.max_acceleration > 0.0 for limit in calibration.joint_limits)


def test_rejects_incompatible_schema() -> None:
    with pytest.raises(ValueError, match=r"machine-calibration-v1.*machine-calibration-v2"):
        MachineCalibration.from_mapping({"schema_version": "machine-calibration-v1"})


def test_cylinder_mapping_is_deterministic(calibration: MachineCalibration) -> None:
    first = calibration.cylinder_lengths((0.0, 0.1, -0.2, 0.3))
    second = calibration.cylinder_lengths((0.0, 0.1, -0.2, 0.3))
    changed = calibration.cylinder_lengths((0.0, 0.2, -0.1, 0.4))
    assert first == second
    assert len(first) == 3
    assert first != changed
