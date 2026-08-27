from __future__ import annotations

import pytest

from babylon_sim.control import (
    AxisProfile,
    ControlCommand,
    command_from_keys,
    map_operator_command_to_joints,
    shape_axis,
)


def test_axis_shaping_applies_dead_zone_sensitivity_and_inversion() -> None:
    profile = AxisProfile(dead_zone=0.1, sensitivity=0.5, inverted=True)
    assert shape_axis(0.05, profile) == 0.0
    assert shape_axis(1.0, profile) == pytest.approx(-0.5)


def test_exact_signed_keyboard_mapping_and_cancellation() -> None:
    command = command_from_keys({"y", "j", "i", "o", "l"}, timestamp=1.0, sequence_number=2)
    assert command.channels == (1.0, -1.0, 1.0, 0.0)


def test_disconnected_command_is_zero_and_correlated() -> None:
    command = ControlCommand.disconnected(
        timestamp=1.0,
        sequence_number=3,
        source="browser",
        input_client_sequence=9,
    )
    assert command.channels == (0.0, 0.0, 0.0, 0.0)
    assert command.connected is False
    assert command.input_client_sequence == 9
    assert "input_disconnected" in command.diagnostics


def test_operator_command_maps_to_joint_coordinates_once() -> None:
    operator = ControlCommand(
        timestamp=1.0,
        sequence_number=4,
        channels=(1.0, -0.5, 0.25, -1.0),
        source="godot",
    )
    mapped = map_operator_command_to_joints(operator, (-1.0, -1.0, -1.0, 1.0))
    assert mapped.channels == (-1.0, 0.5, -0.25, -1.0)
    assert mapped.sequence_number == operator.sequence_number
