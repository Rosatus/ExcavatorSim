"""Deterministic fixed-step excavator simulation."""

from __future__ import annotations

import math
from collections.abc import Iterable
from enum import StrEnum

from .calibration import MachineCalibration
from .constants import ACTIVE_JOINT_NAMES
from .control import ControlCommand
from .model import ExcavatorModel
from .state import SimulationState


class SimulationStatus(StrEnum):
    STOPPED = "stopped"
    RUNNING = "running"
    PAUSED = "paused"
    FAULT = "fault"


class Simulator:
    def __init__(
        self,
        model: ExcavatorModel,
        calibration: MachineCalibration,
        *,
        initial_positions: Iterable[float] | None = None,
    ) -> None:
        self.model = model
        self.calibration = calibration
        self._initial_positions = self._validate_positions(
            (0.0,) * len(ACTIVE_JOINT_NAMES) if initial_positions is None else initial_positions
        )
        self._positions = self._initial_positions
        self._velocities = (0.0,) * len(ACTIVE_JOINT_NAMES)
        self._accelerations = (0.0,) * len(ACTIVE_JOINT_NAMES)
        self._timestamp = 0.0
        self._sequence_number = 0
        self.status = SimulationStatus.STOPPED
        self.fault_message: str | None = None

    def _validate_positions(self, positions: Iterable[float]) -> tuple[float, ...]:
        values = tuple(float(value) for value in positions)
        if len(values) != len(ACTIVE_JOINT_NAMES) or any(
            not math.isfinite(value) for value in values
        ):
            raise ValueError(f"initial positions must contain {len(ACTIVE_JOINT_NAMES)} values")
        return tuple(
            limit.clamp(value)
            for value, limit in zip(values, self.calibration.joint_limits, strict=True)
        )

    @property
    def timestamp(self) -> float:
        return self._timestamp

    @property
    def sequence_number(self) -> int:
        return self._sequence_number

    def start(self) -> SimulationState:
        if self.status not in {SimulationStatus.STOPPED, SimulationStatus.PAUSED}:
            raise RuntimeError(f"cannot start simulation from {self.status.value}")
        self.status = SimulationStatus.RUNNING
        return self.snapshot()

    def pause(self) -> SimulationState:
        if self.status is not SimulationStatus.RUNNING:
            raise RuntimeError(f"cannot pause simulation from {self.status.value}")
        self.status = SimulationStatus.PAUSED
        self._velocities = (0.0,) * len(ACTIVE_JOINT_NAMES)
        self._accelerations = (0.0,) * len(ACTIVE_JOINT_NAMES)
        return self.snapshot()

    def reset(self) -> SimulationState:
        self._positions = self._initial_positions
        self._velocities = (0.0,) * len(ACTIVE_JOINT_NAMES)
        self._accelerations = (0.0,) * len(ACTIVE_JOINT_NAMES)
        self._timestamp = 0.0
        self._sequence_number = 0
        self.status = SimulationStatus.STOPPED
        self.fault_message = None
        return self.snapshot(quality_flags=("state_reset",))

    def snapshot(
        self,
        *,
        source: str = "simulation",
        quality_flags: Iterable[str] = (),
    ) -> SimulationState:
        return self.model.make_state(
            self._positions,
            timestamp=self._timestamp,
            sequence_number=self._sequence_number,
            calibration_version=self.calibration.calibration_version,
            joint_velocity=self._velocities,
            joint_acceleration=self._accelerations,
            source=source,
            quality_flags=(f"calibration:{self.calibration.quality}", *quality_flags),
        )

    def hold(self, command: ControlCommand) -> SimulationState:
        flags: tuple[str, ...]
        if not command.connected:
            self._velocities = (0.0,) * len(ACTIVE_JOINT_NAMES)
            self._accelerations = (0.0,) * len(ACTIVE_JOINT_NAMES)
            flags = ("input_disconnected", "emergency_stop")
        else:
            flags = ()
        return self.snapshot(source=command.source, quality_flags=flags)

    def step(self, command: ControlCommand, *, dt: float) -> SimulationState:
        if self.status is not SimulationStatus.RUNNING:
            raise RuntimeError(f"cannot step simulation while {self.status.value}")
        if not math.isfinite(dt) or dt <= 0.0:
            raise ValueError("simulation dt must be finite and positive")
        try:
            previous_velocity = self._velocities
            quality_flags: tuple[str, ...] = ()
            if command.connected:
                next_positions: list[float] = []
                next_velocities: list[float] = []
                for position, velocity, channel, limit in zip(
                    self._positions,
                    self._velocities,
                    command.channels,
                    self.calibration.joint_limits,
                    strict=True,
                ):
                    target_velocity = channel * limit.max_velocity
                    maximum_delta = limit.max_acceleration * dt
                    velocity_delta = min(
                        max(target_velocity - velocity, -maximum_delta), maximum_delta
                    )
                    next_velocity = velocity + velocity_delta
                    if next_velocity > 0.0:
                        stopping_speed = math.sqrt(
                            2.0 * limit.max_acceleration * max(0.0, limit.max_position - position)
                        )
                        next_velocity = min(next_velocity, stopping_speed)
                    elif next_velocity < 0.0:
                        stopping_speed = math.sqrt(
                            2.0 * limit.max_acceleration * max(0.0, position - limit.min_position)
                        )
                        next_velocity = max(next_velocity, -stopping_speed)
                    requested_position = position + 0.5 * (velocity + next_velocity) * dt
                    clamped_position = limit.clamp(requested_position)
                    reached_limit = (
                        clamped_position != requested_position
                        or (clamped_position >= limit.max_position and next_velocity > 0.0)
                        or (clamped_position <= limit.min_position and next_velocity < 0.0)
                    )
                    if reached_limit:
                        next_velocity = 0.0
                        quality_flags += (f"joint_limit:{limit.name}",)
                    next_positions.append(clamped_position)
                    next_velocities.append(next_velocity)
                self._positions = tuple(next_positions)
                self._velocities = tuple(next_velocities)
            else:
                self._velocities = (0.0,) * len(ACTIVE_JOINT_NAMES)
                quality_flags = ("input_disconnected", "emergency_stop")
            self._accelerations = tuple(
                (velocity - old_velocity) / dt
                for velocity, old_velocity in zip(self._velocities, previous_velocity, strict=True)
            )
            self._timestamp += dt
            self._sequence_number += 1
            return self.snapshot(source=command.source, quality_flags=quality_flags)
        except Exception as exc:
            self.status = SimulationStatus.FAULT
            self.fault_message = str(exc)
            raise
