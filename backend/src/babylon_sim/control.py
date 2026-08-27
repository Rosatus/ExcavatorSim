"""Normalized control commands and device-independent axis shaping."""

from __future__ import annotations

import math
from collections.abc import Iterable
from dataclasses import dataclass

from .constants import ACTIVE_JOINT_NAMES


@dataclass(frozen=True)
class AxisProfile:
    dead_zone: float = 0.08
    sensitivity: float = 1.0
    inverted: bool = False

    def __post_init__(self) -> None:
        if not 0.0 <= self.dead_zone < 1.0:
            raise ValueError("dead_zone must be in [0, 1)")
        if not math.isfinite(self.sensitivity) or self.sensitivity <= 0.0:
            raise ValueError("sensitivity must be finite and positive")


@dataclass(frozen=True)
class ControlCommand:
    timestamp: float
    sequence_number: int
    channels: tuple[float, ...]
    source: str
    connected: bool = True
    input_client_sequence: int | None = None
    diagnostics: tuple[str, ...] = ()

    def __post_init__(self) -> None:
        if not math.isfinite(self.timestamp):
            raise ValueError("control timestamp must be finite")
        if self.sequence_number < 0:
            raise ValueError("control sequence_number must be non-negative")
        if not self.source:
            raise ValueError("control source must not be empty")
        if len(self.channels) != len(ACTIVE_JOINT_NAMES):
            raise ValueError(f"control command requires {len(ACTIVE_JOINT_NAMES)} channels")
        if any(not math.isfinite(value) or abs(value) > 1.0 for value in self.channels):
            raise ValueError("control channels must be finite values in [-1, 1]")
        if not self.connected and any(value != 0.0 for value in self.channels):
            raise ValueError("a disconnected control command must contain zero channels")
        if self.input_client_sequence is not None and self.input_client_sequence < 0:
            raise ValueError("input_client_sequence must be non-negative")

    @classmethod
    def disconnected(
        cls,
        *,
        timestamp: float,
        sequence_number: int,
        source: str,
        input_client_sequence: int | None = None,
    ) -> ControlCommand:
        return cls(
            timestamp=timestamp,
            sequence_number=sequence_number,
            channels=(0.0,) * len(ACTIVE_JOINT_NAMES),
            source=source,
            connected=False,
            input_client_sequence=input_client_sequence,
            diagnostics=("input_disconnected",),
        )


DEFAULT_AXIS_PROFILES = tuple(AxisProfile() for _ in ACTIVE_JOINT_NAMES)
KEYBOARD_BINDINGS = (("y", "h"), ("u", "j"), ("i", "k"), ("o", "l"))


def shape_axis(value: float, profile: AxisProfile) -> float:
    if not math.isfinite(value):
        raise ValueError("raw axis value must be finite")
    clamped = min(abs(value), 1.0)
    if clamped <= profile.dead_zone:
        return 0.0
    normalized = (clamped - profile.dead_zone) / (1.0 - profile.dead_zone)
    scaled = min(normalized * profile.sensitivity, 1.0)
    sign = -1.0 if value < 0.0 else 1.0
    return -sign * scaled if profile.inverted else sign * scaled


def normalize_axes(
    raw_axes: Iterable[float],
    *,
    timestamp: float,
    sequence_number: int,
    source: str,
    input_client_sequence: int | None = None,
    profiles: tuple[AxisProfile, ...] = DEFAULT_AXIS_PROFILES,
) -> ControlCommand:
    axes = tuple(float(value) for value in raw_axes)
    if len(axes) != len(ACTIVE_JOINT_NAMES) or len(profiles) != len(ACTIVE_JOINT_NAMES):
        raise ValueError(f"raw axes and profiles must contain {len(ACTIVE_JOINT_NAMES)} values")
    return ControlCommand(
        timestamp=timestamp,
        sequence_number=sequence_number,
        channels=tuple(
            shape_axis(value, profile) for value, profile in zip(axes, profiles, strict=True)
        ),
        source=source,
        input_client_sequence=input_client_sequence,
    )


def map_operator_command_to_joints(
    command: ControlCommand,
    signs: tuple[float, float, float, float],
) -> ControlCommand:
    if len(signs) != len(ACTIVE_JOINT_NAMES) or any(sign not in (-1.0, 1.0) for sign in signs):
        raise ValueError("operator-to-joint signs must contain exactly four values in {-1, 1}")
    return ControlCommand(
        timestamp=command.timestamp,
        sequence_number=command.sequence_number,
        channels=tuple(value * sign for value, sign in zip(command.channels, signs, strict=True)),
        source=command.source,
        connected=command.connected,
        input_client_sequence=command.input_client_sequence,
        diagnostics=command.diagnostics,
    )


def command_from_keys(
    pressed_keys: Iterable[str], *, timestamp: float, sequence_number: int
) -> ControlCommand:
    pressed = {key.lower() for key in pressed_keys}
    channels = tuple(
        float((positive in pressed) - (negative in pressed))
        for positive, negative in KEYBOARD_BINDINGS
    )
    return ControlCommand(
        timestamp=timestamp,
        sequence_number=sequence_number,
        channels=channels,
        source="keyboard",
    )
