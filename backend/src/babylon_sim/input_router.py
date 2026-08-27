"""Thread-safe latest-value input routing with deterministic safety semantics."""

from __future__ import annotations

import math
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass

from .constants import ACTIVE_JOINT_NAMES, INPUT_LEASE_SECONDS
from .control import (
    DEFAULT_AXIS_PROFILES,
    AxisProfile,
    ControlCommand,
    map_operator_command_to_joints,
    normalize_axes,
)

DEFAULT_MAX_INPUT_SOURCES = 8
MAX_CLIENT_SEQUENCE = (1 << 64) - 1


class InputRouterError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class InputSnapshot:
    source: str
    client_sequence: int
    connected: bool
    operator_axes: tuple[float, ...]

    def __post_init__(self) -> None:
        if not isinstance(self.source, str) or not self.source:
            raise ValueError("input source must be a non-empty string")
        if (
            isinstance(self.client_sequence, bool)
            or not isinstance(self.client_sequence, int)
            or not 0 <= self.client_sequence <= MAX_CLIENT_SEQUENCE
        ):
            raise ValueError("input client_sequence must be an unsigned 64-bit integer")
        if not isinstance(self.connected, bool):
            raise ValueError("input connected must be a boolean")
        if len(self.operator_axes) != len(ACTIVE_JOINT_NAMES):
            raise ValueError(f"input axes must contain {len(ACTIVE_JOINT_NAMES)} values")
        if any(
            isinstance(value, bool) or not isinstance(value, (int, float))
            for value in self.operator_axes
        ):
            raise ValueError("input axes must be finite numbers in [-1, 1]")
        axes = tuple(float(value) for value in self.operator_axes)
        if any(not math.isfinite(value) or abs(value) > 1.0 for value in axes):
            raise ValueError("input axes must be finite numbers in [-1, 1]")
        if not self.connected and any(value != 0.0 for value in axes):
            raise ValueError("a disconnected input snapshot must contain zero axes")
        object.__setattr__(self, "operator_axes", axes)

    @property
    def is_zero(self) -> bool:
        return all(value == 0.0 for value in self.operator_axes)


@dataclass
class _SourceState:
    client_id: str
    last_sequence: int
    snapshot: InputSnapshot
    received_at: float
    armed: bool


class InputRouter:
    def __init__(
        self,
        *,
        lease_seconds: float = INPUT_LEASE_SECONDS,
        max_sources: int = DEFAULT_MAX_INPUT_SOURCES,
        clock: Callable[[], float] = time.monotonic,
        profiles: tuple[AxisProfile, ...] = DEFAULT_AXIS_PROFILES,
        operator_to_joint_signs: tuple[float, float, float, float],
    ) -> None:
        if not math.isfinite(lease_seconds) or lease_seconds <= 0.0:
            raise ValueError("input lease_seconds must be finite and positive")
        if len(profiles) != len(ACTIVE_JOINT_NAMES):
            raise ValueError(f"input profiles must contain {len(ACTIVE_JOINT_NAMES)} values")
        if isinstance(max_sources, bool) or not isinstance(max_sources, int) or max_sources <= 0:
            raise ValueError("input max_sources must be a positive integer")
        if len(operator_to_joint_signs) != len(ACTIVE_JOINT_NAMES) or any(
            sign not in (-1.0, 1.0) for sign in operator_to_joint_signs
        ):
            raise ValueError("operator-to-joint signs must contain four values in {-1, 1}")
        self.lease_seconds = float(lease_seconds)
        self.max_sources = max_sources
        self._clock = clock
        self._profiles = profiles
        self._operator_to_joint_signs = operator_to_joint_signs
        self._sources: dict[str, _SourceState] = {}
        self._client_sequences: dict[str, int] = {}
        self._active_source: str | None = None
        self._last_source: str | None = None
        self._last_client_sequence: int | None = None
        self._zero_barrier_source: str | None = None
        self._lock = threading.Lock()

    @property
    def active_source(self) -> str | None:
        with self._lock:
            return self._active_source

    def submit(
        self,
        snapshot: InputSnapshot,
        *,
        client_id: str,
        received_at: float | None = None,
    ) -> None:
        if not client_id:
            raise ValueError("input client_id must not be empty")
        now = self._now(received_at)
        with self._lock:
            self._expire_sources(now)
            last_client_sequence = self._client_sequences.get(client_id)
            if (
                last_client_sequence is not None
                and snapshot.client_sequence <= last_client_sequence
            ):
                raise InputRouterError(
                    "stale_sequence",
                    f"input client_sequence must increase beyond {last_client_sequence}",
                )
            state = self._sources.get(snapshot.source)
            if state is not None and state.client_id != client_id:
                if self._is_live(state, now):
                    raise InputRouterError(
                        "source_in_use",
                        f"input source {snapshot.source!r} is owned by another client",
                    )
                state = None
            if state is None and len(self._sources) >= self.max_sources:
                raise InputRouterError(
                    "too_many_sources", f"input router accepts at most {self.max_sources} sources"
                )
            self._last_source = snapshot.source
            self._last_client_sequence = snapshot.client_sequence
            if not snapshot.connected:
                if self._active_source == snapshot.source:
                    self._active_source = None
                    self._zero_barrier_source = snapshot.source
                self._sources.pop(snapshot.source, None)
                self._client_sequences[client_id] = snapshot.client_sequence
                return

            armed = state.armed if state is not None else False
            if snapshot.is_zero:
                armed = True
            elif not armed:
                raise InputRouterError(
                    "not_armed", "input source must publish connected zero before nonzero intent"
                )
            self._sources[snapshot.source] = _SourceState(
                client_id=client_id,
                last_sequence=snapshot.client_sequence,
                snapshot=snapshot,
                received_at=now,
                armed=armed,
            )
            self._client_sequences[client_id] = snapshot.client_sequence
            if self._active_source == snapshot.source and snapshot.is_zero:
                self._active_source = None

    def disconnect_client(self, client_id: str) -> None:
        with self._lock:
            owned_sources = {
                source for source, state in self._sources.items() if state.client_id == client_id
            }
            active_source = self._active_source
            if active_source is not None and active_source in owned_sources:
                active = self._sources[active_source]
                self._last_client_sequence = active.last_sequence
                self._zero_barrier_source = active_source
                self._active_source = None
            for source in owned_sources:
                del self._sources[source]
            self._client_sequences.pop(client_id, None)

    def command(
        self,
        *,
        timestamp: float,
        sequence_number: int,
        now: float | None = None,
    ) -> ControlCommand:
        current_time = self._now(now)
        with self._lock:
            self._expire_sources(current_time)
            if self._zero_barrier_source is not None:
                source = self._zero_barrier_source
                self._zero_barrier_source = None
                return ControlCommand.disconnected(
                    timestamp=timestamp,
                    sequence_number=sequence_number,
                    source=source,
                    input_client_sequence=self._last_client_sequence,
                )

            active = self._active_state(current_time)
            if active is None:
                candidates = [
                    (source, state)
                    for source, state in self._sources.items()
                    if self._is_eligible_nonzero(state, current_time)
                ]
                if candidates:
                    source, active = max(
                        candidates, key=lambda item: (item[1].received_at, item[0])
                    )
                    self._active_source = source
            if active is not None:
                return map_operator_command_to_joints(
                    normalize_axes(
                        active.snapshot.operator_axes,
                        timestamp=timestamp,
                        sequence_number=sequence_number,
                        source=active.snapshot.source,
                        input_client_sequence=active.last_sequence,
                        profiles=self._profiles,
                    ),
                    self._operator_to_joint_signs,
                )

            zero_candidates = [
                state
                for state in self._sources.values()
                if self._is_live(state, current_time)
                and state.armed
                and state.snapshot.connected
                and state.snapshot.is_zero
            ]
            if zero_candidates:
                zero = max(
                    zero_candidates, key=lambda state: (state.received_at, state.snapshot.source)
                )
                return map_operator_command_to_joints(
                    normalize_axes(
                        zero.snapshot.operator_axes,
                        timestamp=timestamp,
                        sequence_number=sequence_number,
                        source=zero.snapshot.source,
                        input_client_sequence=zero.last_sequence,
                        profiles=self._profiles,
                    ),
                    self._operator_to_joint_signs,
                )
            return ControlCommand.disconnected(
                timestamp=timestamp,
                sequence_number=sequence_number,
                source=self._last_source or "browser_input",
                input_client_sequence=self._last_client_sequence,
            )

    def _now(self, value: float | None) -> float:
        now = float(self._clock() if value is None else value)
        if not math.isfinite(now):
            raise ValueError("input monotonic time must be finite")
        return now

    def _expire_sources(self, now: float) -> None:
        expired_sources: list[str] = []
        for source, state in self._sources.items():
            if self._is_live(state, now):
                continue
            if self._active_source == source:
                self._active_source = None
                self._zero_barrier_source = source
                self._last_client_sequence = state.last_sequence
            expired_sources.append(source)
        for source in expired_sources:
            del self._sources[source]

    def _active_state(self, now: float) -> _SourceState | None:
        if self._active_source is None:
            return None
        state = self._sources.get(self._active_source)
        if state is None or not self._is_eligible_nonzero(state, now):
            self._active_source = None
            return None
        return state

    def _is_eligible_nonzero(self, state: _SourceState, now: float) -> bool:
        return (
            self._is_live(state, now)
            and state.armed
            and state.snapshot.connected
            and not state.snapshot.is_zero
        )

    def _is_live(self, state: _SourceState, now: float) -> bool:
        return now - state.received_at < self.lease_seconds
