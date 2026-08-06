from __future__ import annotations

import math

import pytest

from babylon_sim.calibration import MachineCalibration
from babylon_sim.control import ControlCommand
from babylon_sim.model import ExcavatorModel
from babylon_sim.simulation import SimulationStatus, Simulator


def _simulator(model: ExcavatorModel, calibration: MachineCalibration) -> Simulator:
    return Simulator(model, calibration)


def _command(
    channels: tuple[float, float, float, float], sequence_number: int = 0
) -> ControlCommand:
    return ControlCommand(
        timestamp=sequence_number * 0.1,
        sequence_number=sequence_number,
        channels=channels,
        source="test",
        input_client_sequence=sequence_number,
    )


def test_four_channels_advance_with_acceleration_limits(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    simulator = _simulator(model, calibration)
    simulator.start()
    state = simulator.step(_command((1.0, -1.0, 0.5, -0.5)), dt=0.1)
    assert state.joint_velocity == pytest.approx((0.08, -0.05, 0.065, -0.08))
    assert state.joint_position == pytest.approx((0.004, -0.0025, 0.00325, -0.004))
    assert state.joint_acceleration == pytest.approx((0.8, -0.5, 0.65, -0.8))


def test_joint_positions_clamp_and_report(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    simulator = _simulator(model, calibration)
    simulator.start()
    state = simulator.step(_command((1.0, 1.0, 1.0, 1.0)), dt=100.0)
    maxima = tuple(limit.max_position for limit in calibration.joint_limits)
    assert state.joint_position == maxima
    assert state.joint_velocity == (0.0, 0.0, 0.0, 0.0)
    for limit in calibration.joint_limits:
        assert f"joint_limit:{limit.name}" in state.quality_flags


def test_disconnect_stops_without_position_jump(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    simulator = _simulator(model, calibration)
    simulator.start()
    simulator.step(_command((0.5, 0.5, 0.5, 0.5)), dt=0.1)
    before = simulator.snapshot()
    state = simulator.step(
        ControlCommand.disconnected(timestamp=0.2, sequence_number=2, source="browser"),
        dt=0.1,
    )
    assert state.joint_position == before.joint_position
    assert state.joint_velocity == (0.0, 0.0, 0.0, 0.0)
    assert "emergency_stop" in state.quality_flags
    assert all(math.isfinite(value) for value in state.joint_acceleration)


def test_pause_hold_and_reset(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    simulator = _simulator(model, calibration)
    simulator.start()
    moving = simulator.step(_command((1.0, 0.0, 0.0, 0.0)), dt=0.1)
    paused = simulator.pause()
    held = simulator.hold(
        ControlCommand.disconnected(timestamp=0.1, sequence_number=1, source="browser")
    )
    assert paused.joint_position == moving.joint_position
    assert held.joint_position == moving.joint_position
    assert held.joint_velocity == (0.0, 0.0, 0.0, 0.0)
    assert simulator.status is SimulationStatus.PAUSED
    reset = simulator.reset()
    assert reset.timestamp == 0.0
    assert reset.joint_position == (0.0, 0.0, 0.0, 0.0)
    assert "state_reset" in reset.quality_flags
