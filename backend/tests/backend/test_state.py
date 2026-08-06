from __future__ import annotations

import pytest

from babylon_sim.state import SimulationState


def _state(**overrides: object) -> SimulationState:
    values: dict[str, object] = {
        "timestamp": 0.0,
        "sequence_number": 0,
        "source": "test",
        "model_version": "model",
        "calibration_version": "calibration",
        "joint_position": (0.0, 0.0, 0.0, 0.0),
        "joint_velocity": (0.0, 0.0, 0.0, 0.0),
        "joint_acceleration": (0.0, 0.0, 0.0, 0.0),
        "frame_transforms": {"base_link": ((1.0, 0.0, 0.0, 0.0),) * 4},
    }
    values.update(overrides)
    return SimulationState(**values)  # type: ignore[arg-type]


def test_state_requires_four_joint_values() -> None:
    with pytest.raises(ValueError, match="joint vectors must contain 4"):
        _state(joint_position=(0.0, 0.0))


def test_state_rejects_invalid_matrix_shape() -> None:
    with pytest.raises(ValueError, match="must be 4x4"):
        _state(frame_transforms={"base_link": ((1.0, 0.0),)})


def test_state_deduplicates_quality_flags_and_freezes_transforms() -> None:
    state = _state(quality_flags=("a", "a", "b"))
    assert state.quality_flags == ("a", "b")
    with pytest.raises(TypeError):
        state.frame_transforms["other"] = state.frame_transforms["base_link"]  # type: ignore[index]

