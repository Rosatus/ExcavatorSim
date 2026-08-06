from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import pytest

from babylon_sim.constants import ACTIVE_JOINT_NAMES, REQUIRED_FRAME_NAMES
from babylon_sim.model import ExcavatorModel, ModelValidationError


def test_loads_vendored_urdf_with_stable_contract(model: ExcavatorModel) -> None:
    assert tuple(joint.name for joint in model.active_joints) == ACTIVE_JOINT_NAMES
    assert model.frame_names == REQUIRED_FRAME_NAMES


def test_continuous_joint_configuration(model: ExcavatorModel) -> None:
    configuration = model.configuration_from_angles(
        (0.0, math.pi / 2.0, math.pi, -math.pi / 2.0)
    )
    assert tuple(configuration[0:2]) == (1.0, 0.0)
    assert np.allclose(
        configuration[2:8],
        (0.0, 1.0, -1.0, 0.0, 0.0, -1.0),
        atol=1e-7,
    )


@pytest.mark.parametrize("pose_name", ["zero", "swing_positive_90", "asymmetric"])
def test_frame_transforms_match_fixed_baseline(
    model: ExcavatorModel, fixture_root: Path, pose_name: str
) -> None:
    baseline = json.loads(
        (fixture_root / "frame-parity" / "baseline.json").read_text(encoding="utf-8")
    )
    pose = baseline["poses"][pose_name]
    actual = model.frame_transforms(pose["joint_angles"])
    assert set(actual) == set(pose["frame_transforms"])
    for frame_name, expected in pose["frame_transforms"].items():
        assert np.allclose(actual[frame_name], expected, atol=1e-12), frame_name


def test_default_pose_is_grounded(model: ExcavatorModel) -> None:
    transforms = model.frame_transforms((0.0, 0.0, 0.0, 0.0))
    assert transforms["base_link"][2][3] == pytest.approx(0.0)
    tooth_bottom = transforms["tooth_center"][2][3] - 0.06
    assert 0.05 <= tooth_bottom <= 0.30


def test_missing_urdf_is_diagnostic(tmp_path: Path) -> None:
    with pytest.raises(ModelValidationError, match="does not exist"):
        ExcavatorModel.from_urdf(tmp_path / "missing.urdf")

