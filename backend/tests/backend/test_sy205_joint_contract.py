from __future__ import annotations

import json

import numpy as np
import pytest

from babylon_sim.calibration import MachineCalibration
from babylon_sim.model import ExcavatorModel
from babylon_sim.model_registry import load_model_registry
from babylon_sim.paths import PROJECT_ROOT
from babylon_sim.runtime import RuntimeController
from babylon_sim.sy205_joint_contract import Sy205JointModel, adapt_sy205_model


@pytest.mark.parametrize("index", range(4))
@pytest.mark.parametrize("direction", [-1.0, 1.0])
def test_sy205_logical_fk_matches_original_operator_motion(
    model: ExcavatorModel, index: int, direction: float
) -> None:
    old_signs = (-1.0, -1.0, -1.0, 1.0)
    shared_signs = (-1.0, 1.0, 1.0, -1.0)
    old_angles = [0.0] * 4
    new_angles = [0.0] * 4
    old_angles[index] = old_signs[index] * direction * 0.2
    new_angles[index] = shared_signs[index] * direction * 0.2
    expected = model.frame_transforms(old_angles)
    observed = adapt_sy205_model(model).frame_transforms(new_angles)
    for frame, transform in expected.items():
        np.testing.assert_allclose(observed[frame], transform, atol=1e-12)


def test_sy205_runtime_and_replay_share_logical_axes(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration, model_id="sy205")
    try:
        assert isinstance(runtime.model, Sy205JointModel)
        assert runtime.model is not model
        assert runtime.replay is not None
        assert isinstance(runtime.replay.replay_model, Sy205JointModel)
        rig = json.loads(
            (PROJECT_ROOT / "godot/client/resources/physics/sy205_physics_rig.json").read_text(
                encoding="utf-8"
            )
        )
        for limit, joint in zip(runtime.calibration.joint_limits, rig["joints"], strict=True):
            assert (limit.min_position, limit.max_position) == tuple(joint["limit_rad"])
        assert runtime.model.asset_signs == tuple(
            joint["axis"][1] if index == 0 else joint["axis"][0]
            for index, joint in enumerate(rig["joints"])
        )
        q = (0.1, 0.2, -0.3, 0.4)
        np.testing.assert_allclose(
            runtime.calibration.cylinder_lengths(q),
            calibration.cylinder_lengths((q[0], -q[1], -q[2], -q[3])),
            atol=1e-12,
        )
    finally:
        runtime.stop()


def test_sy135_runtime_keeps_original_model_calibration_and_frames() -> None:
    descriptor = load_model_registry().resolve("sy135")
    model = ExcavatorModel.from_urdf(descriptor.urdf_path, model_version=descriptor.model_version)
    calibration = MachineCalibration.from_json(descriptor.calibration_path)
    q = (0.1, 0.2, -0.3, 0.4)
    before = model.frame_transforms(q)
    runtime = RuntimeController(model, calibration, model_id="sy135")
    try:
        assert runtime.model is model
        assert runtime.calibration is calibration
        assert type(runtime.model) is ExcavatorModel
        assert runtime.model.frame_transforms(q) == before
        assert runtime.replay is not None
        assert type(runtime.replay.replay_model) is ExcavatorModel
        assert runtime.replay.replay_model.frame_transforms(q) == before
    finally:
        runtime.stop()
