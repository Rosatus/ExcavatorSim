"""Bounded process-local recording with immutable reader snapshots."""

from __future__ import annotations

import json
import threading
import uuid
from collections import deque
from collections.abc import Iterable
from dataclasses import dataclass

import numpy as np
import numpy.typing as npt

from .constants import ACTIVE_JOINT_NAMES
from .replay_contract import RECORDING_CHUNK_SAMPLES, RECORDING_MAX_SAMPLES
from .state import SimulationState

UInt64Array = npt.NDArray[np.uint64]
Int64Array = npt.NDArray[np.int64]
UInt32Array = npt.NDArray[np.uint32]
UInt8Array = npt.NDArray[np.uint8]
BoolArray = npt.NDArray[np.bool_]
Float64Array = npt.NDArray[np.float64]

_LIFECYCLE_TO_CODE = {"stopped": 0, "running": 1, "paused": 2, "fault": 3}
_CODE_TO_LIFECYCLE = tuple(_LIFECYCLE_TO_CODE)


@dataclass(frozen=True)
class RecordingEvent:
    sample_sequence: int
    recording_time_ns: int
    kind: str
    value: str


@dataclass(frozen=True)
class RecordingChunk:
    recording_time_ns: Int64Array
    simulation_time_s: Float64Array
    source_sequence: UInt64Array
    simulation_epoch_id: UInt32Array
    lifecycle_code: UInt8Array
    joint_position: Float64Array
    joint_velocity: Float64Array
    joint_acceleration: Float64Array
    last_input_sequence: UInt64Array
    last_input_valid: BoolArray
    sample_sequence: UInt64Array

    def __len__(self) -> int:
        return int(self.recording_time_ns.shape[0])


@dataclass(frozen=True)
class RecordedSample:
    recording_time_ns: int
    simulation_time_s: float
    source_sequence: int
    simulation_epoch: str
    lifecycle: str
    joint_position: tuple[float, ...]
    joint_velocity: tuple[float, ...]
    joint_acceleration: tuple[float, ...]
    last_input_sequence: int | None
    sample_sequence: int


@dataclass(frozen=True)
class MaterializedRecording:
    recording_time_ns: Int64Array
    simulation_time_s: Float64Array
    source_sequence: UInt64Array
    simulation_epoch_id: UInt32Array
    lifecycle_code: UInt8Array
    joint_position: Float64Array
    joint_velocity: Float64Array
    joint_acceleration: Float64Array
    last_input_sequence: UInt64Array
    last_input_valid: BoolArray
    sample_sequence: UInt64Array
    simulation_epochs: tuple[str, ...]
    events: tuple[RecordingEvent, ...]

    def __len__(self) -> int:
        return int(self.recording_time_ns.shape[0])


@dataclass(frozen=True)
class BufferSnapshot:
    recording_epoch: str
    chunks: tuple[RecordingChunk, ...]
    simulation_epochs: tuple[str, ...]
    events: tuple[RecordingEvent, ...]
    buffer_generation: int
    end_sample_sequence: int
    evicted_samples: int

    @property
    def sample_count(self) -> int:
        return sum(len(chunk) for chunk in self.chunks)

    @property
    def retained_start_ns(self) -> int | None:
        return None if not self.chunks else int(self.chunks[0].recording_time_ns[0])

    @property
    def retained_end_ns(self) -> int | None:
        return None if not self.chunks else int(self.chunks[-1].recording_time_ns[-1])

    def materialize(self) -> MaterializedRecording:
        def join(name: str) -> npt.NDArray[np.generic]:
            arrays = [getattr(chunk, name) for chunk in self.chunks]
            if not arrays:
                raise RuntimeError("cannot materialize an empty recording")
            return np.concatenate(arrays, axis=0)

        return MaterializedRecording(
            recording_time_ns=join("recording_time_ns"),  # type: ignore[arg-type]
            simulation_time_s=join("simulation_time_s"),  # type: ignore[arg-type]
            source_sequence=join("source_sequence"),  # type: ignore[arg-type]
            simulation_epoch_id=join("simulation_epoch_id"),  # type: ignore[arg-type]
            lifecycle_code=join("lifecycle_code"),  # type: ignore[arg-type]
            joint_position=join("joint_position"),  # type: ignore[arg-type]
            joint_velocity=join("joint_velocity"),  # type: ignore[arg-type]
            joint_acceleration=join("joint_acceleration"),  # type: ignore[arg-type]
            last_input_sequence=join("last_input_sequence"),  # type: ignore[arg-type]
            last_input_valid=join("last_input_valid"),  # type: ignore[arg-type]
            sample_sequence=join("sample_sequence"),  # type: ignore[arg-type]
            simulation_epochs=self.simulation_epochs,
            events=self.events,
        )

    def sample_at_or_before(self, recording_time_ns: int) -> RecordedSample:
        if not self.chunks:
            raise RuntimeError("cannot select from an empty recording")
        chunk = self.chunks[0]
        for candidate in reversed(self.chunks):
            if recording_time_ns >= int(candidate.recording_time_ns[0]):
                chunk = candidate
                break
        index = int(np.searchsorted(chunk.recording_time_ns, recording_time_ns, side="right") - 1)
        index = min(max(index, 0), len(chunk) - 1)
        epoch_id = int(chunk.simulation_epoch_id[index])
        return RecordedSample(
            recording_time_ns=int(chunk.recording_time_ns[index]),
            simulation_time_s=float(chunk.simulation_time_s[index]),
            source_sequence=int(chunk.source_sequence[index]),
            simulation_epoch=self.simulation_epochs[epoch_id],
            lifecycle=_CODE_TO_LIFECYCLE[int(chunk.lifecycle_code[index])],
            joint_position=tuple(float(value) for value in chunk.joint_position[index]),
            joint_velocity=tuple(float(value) for value in chunk.joint_velocity[index]),
            joint_acceleration=tuple(float(value) for value in chunk.joint_acceleration[index]),
            last_input_sequence=(
                int(chunk.last_input_sequence[index]) if chunk.last_input_valid[index] else None
            ),
            sample_sequence=int(chunk.sample_sequence[index]),
        )

    def quality_at(self, sample_sequence: int) -> tuple[str, ...]:
        value = "[]"
        for event in self.events:
            if event.sample_sequence > sample_sequence:
                break
            if event.kind == "quality":
                value = event.value
        decoded = json.loads(value)
        if not isinstance(decoded, list) or any(not isinstance(item, str) for item in decoded):
            raise RuntimeError("recording quality event is invalid")
        return tuple(decoded)


class _MutableChunk:
    def __init__(self, capacity: int) -> None:
        joints = len(ACTIVE_JOINT_NAMES)
        self.recording_time_ns = np.empty(capacity, dtype=np.int64)
        self.simulation_time_s = np.empty(capacity, dtype=np.float64)
        self.source_sequence = np.empty(capacity, dtype=np.uint64)
        self.simulation_epoch_id = np.empty(capacity, dtype=np.uint32)
        self.lifecycle_code = np.empty(capacity, dtype=np.uint8)
        self.joint_position = np.empty((capacity, joints), dtype=np.float64)
        self.joint_velocity = np.empty((capacity, joints), dtype=np.float64)
        self.joint_acceleration = np.empty((capacity, joints), dtype=np.float64)
        self.last_input_sequence = np.empty(capacity, dtype=np.uint64)
        self.last_input_valid = np.empty(capacity, dtype=np.bool_)
        self.sample_sequence = np.empty(capacity, dtype=np.uint64)
        self.size = 0

    def immutable_copy(self) -> RecordingChunk | None:
        if self.size == 0:
            return None

        def copied(name: str) -> npt.NDArray[np.generic]:
            result = np.array(getattr(self, name)[: self.size], copy=True)
            result.setflags(write=False)
            return result

        return RecordingChunk(
            recording_time_ns=copied("recording_time_ns"),  # type: ignore[arg-type]
            simulation_time_s=copied("simulation_time_s"),  # type: ignore[arg-type]
            source_sequence=copied("source_sequence"),  # type: ignore[arg-type]
            simulation_epoch_id=copied("simulation_epoch_id"),  # type: ignore[arg-type]
            lifecycle_code=copied("lifecycle_code"),  # type: ignore[arg-type]
            joint_position=copied("joint_position"),  # type: ignore[arg-type]
            joint_velocity=copied("joint_velocity"),  # type: ignore[arg-type]
            joint_acceleration=copied("joint_acceleration"),  # type: ignore[arg-type]
            last_input_sequence=copied("last_input_sequence"),  # type: ignore[arg-type]
            last_input_valid=copied("last_input_valid"),  # type: ignore[arg-type]
            sample_sequence=copied("sample_sequence"),  # type: ignore[arg-type]
        )


class ChunkedRecordingBuffer:
    """Single-writer recording with immutable chunk references for readers."""

    def __init__(
        self,
        *,
        chunk_samples: int = RECORDING_CHUNK_SAMPLES,
        max_samples: int = RECORDING_MAX_SAMPLES,
        recording_epoch: str | None = None,
    ) -> None:
        if chunk_samples <= 0 or max_samples < chunk_samples or max_samples % chunk_samples:
            raise ValueError("max_samples must be a positive multiple of chunk_samples")
        self._chunk_samples = chunk_samples
        self._max_samples = max_samples
        self._lock = threading.Lock()
        self._sealed: deque[RecordingChunk] = deque()
        self._active = _MutableChunk(chunk_samples)
        self._recording_epoch = recording_epoch or uuid.uuid4().hex
        self._epoch_origin_ns: int | None = None
        self._last_recording_time_ns = -1
        self._next_sample_sequence = 0
        self._buffer_generation = 0
        self._evicted_samples = 0
        self._events: list[RecordingEvent] = []
        self._simulation_epochs: list[str] = []
        self._simulation_epoch_ids: dict[str, int] = {}
        self._previous_lifecycle: str | None = None
        self._previous_quality: tuple[str, ...] | None = None
        self._accept_live_appends = True

    @property
    def recording_epoch(self) -> str:
        with self._lock:
            return self._recording_epoch

    def append(
        self,
        state: SimulationState,
        *,
        simulation_epoch: str,
        lifecycle: str,
        last_input_sequence: int | None,
        monotonic_ns: int,
    ) -> int | None:
        if lifecycle not in _LIFECYCLE_TO_CODE:
            raise ValueError(f"unsupported lifecycle {lifecycle!r}")
        if monotonic_ns < 0:
            raise ValueError("monotonic_ns must be non-negative")
        with self._lock:
            if not self._accept_live_appends:
                return None
            if self._active.size == 0 and self._sealed_count_locked() >= self._max_samples:
                evicted = self._sealed.popleft()
                self._evicted_samples += len(evicted)
                self._buffer_generation += 1
                retained_sequence = (
                    int(self._sealed[0].sample_sequence[0])
                    if self._sealed
                    else self._next_sample_sequence
                )
                retained_time_ns = (
                    int(self._sealed[0].recording_time_ns[0])
                    if self._sealed
                    else self._last_recording_time_ns + 1
                )
                carried: list[RecordingEvent] = []
                for kind in ("lifecycle", "quality"):
                    previous = next(
                        (
                            event
                            for event in reversed(self._events)
                            if event.kind == kind and event.sample_sequence < retained_sequence
                        ),
                        None,
                    )
                    if previous is not None:
                        carried.append(
                            RecordingEvent(
                                retained_sequence,
                                retained_time_ns,
                                previous.kind,
                                previous.value,
                            )
                        )
                self._events = carried + [
                    event for event in self._events if event.sample_sequence >= retained_sequence
                ]

            if self._epoch_origin_ns is None:
                self._epoch_origin_ns = monotonic_ns
            elapsed = max(monotonic_ns - self._epoch_origin_ns, self._last_recording_time_ns + 1)
            row = self._active.size
            sample_sequence = self._next_sample_sequence
            epoch_id = self._simulation_epoch_ids.get(simulation_epoch)
            if epoch_id is None:
                epoch_id = len(self._simulation_epochs)
                self._simulation_epochs.append(simulation_epoch)
                self._simulation_epoch_ids[simulation_epoch] = epoch_id

            active = self._active
            active.recording_time_ns[row] = elapsed
            active.simulation_time_s[row] = state.timestamp
            active.source_sequence[row] = state.sequence_number
            active.simulation_epoch_id[row] = epoch_id
            active.lifecycle_code[row] = _LIFECYCLE_TO_CODE[lifecycle]
            active.joint_position[row] = state.joint_position
            active.joint_velocity[row] = state.joint_velocity
            active.joint_acceleration[row] = state.joint_acceleration
            active.last_input_sequence[row] = (
                0 if last_input_sequence is None else last_input_sequence
            )
            active.last_input_valid[row] = last_input_sequence is not None
            active.sample_sequence[row] = sample_sequence
            active.size += 1

            quality = tuple(sorted(state.quality_flags))
            if lifecycle != self._previous_lifecycle:
                self._append_event_locked(sample_sequence, elapsed, "lifecycle", lifecycle)
                self._previous_lifecycle = lifecycle
            if quality != self._previous_quality:
                self._append_event_locked(
                    sample_sequence,
                    elapsed,
                    "quality",
                    json.dumps(quality, separators=(",", ":")),
                )
                self._previous_quality = quality

            self._last_recording_time_ns = elapsed
            self._next_sample_sequence += 1
            if active.size == self._chunk_samples:
                sealed = active.immutable_copy()
                assert sealed is not None
                self._sealed.append(sealed)
                self._active = _MutableChunk(self._chunk_samples)
                self._buffer_generation += 1
            return sample_sequence

    def install_imported(self, data: MaterializedRecording) -> str:
        self._validate_materialized(data)
        chunks = tuple(
            _chunk_from_materialized(data, start, min(start + self._chunk_samples, len(data)))
            for start in range(0, len(data), self._chunk_samples)
        )
        epoch = uuid.uuid4().hex
        with self._lock:
            self._sealed = deque(chunks)
            self._active = _MutableChunk(self._chunk_samples)
            self._recording_epoch = epoch
            self._epoch_origin_ns = None
            self._last_recording_time_ns = int(data.recording_time_ns[-1])
            self._next_sample_sequence = int(data.sample_sequence[-1]) + 1
            self._buffer_generation += 1
            self._evicted_samples = 0
            self._events = list(data.events)
            self._simulation_epochs = list(data.simulation_epochs)
            self._simulation_epoch_ids = {
                value: index for index, value in enumerate(self._simulation_epochs)
            }
            self._previous_lifecycle = None
            self._previous_quality = None
            self._accept_live_appends = False
        return epoch

    def return_to_live(
        self,
        state: SimulationState,
        *,
        simulation_epoch: str,
        lifecycle: str,
        last_input_sequence: int | None,
        monotonic_ns: int,
    ) -> str:
        epoch = uuid.uuid4().hex
        with self._lock:
            self._sealed.clear()
            self._active = _MutableChunk(self._chunk_samples)
            self._recording_epoch = epoch
            self._epoch_origin_ns = None
            self._last_recording_time_ns = -1
            self._next_sample_sequence = 0
            self._buffer_generation += 1
            self._evicted_samples = 0
            self._events.clear()
            self._simulation_epochs.clear()
            self._simulation_epoch_ids.clear()
            self._previous_lifecycle = None
            self._previous_quality = None
            self._accept_live_appends = True
        self.append(
            state,
            simulation_epoch=simulation_epoch,
            lifecycle=lifecycle,
            last_input_sequence=last_input_sequence,
            monotonic_ns=monotonic_ns,
        )
        return epoch

    def snapshot(self) -> BufferSnapshot:
        with self._lock:
            active = self._active.immutable_copy()
            chunks = tuple(self._sealed) + (() if active is None else (active,))
            events = tuple(self._events)
            return BufferSnapshot(
                recording_epoch=self._recording_epoch,
                chunks=chunks,
                simulation_epochs=tuple(self._simulation_epochs),
                events=events,
                buffer_generation=self._buffer_generation,
                end_sample_sequence=self._next_sample_sequence - 1,
                evicted_samples=self._evicted_samples,
            )

    def _sealed_count_locked(self) -> int:
        return sum(len(chunk) for chunk in self._sealed)

    def _append_event_locked(
        self, sample_sequence: int, recording_time_ns: int, kind: str, value: str
    ) -> None:
        self._events.append(RecordingEvent(sample_sequence, recording_time_ns, kind, value))
        self._buffer_generation += 1

    def _validate_materialized(self, data: MaterializedRecording) -> None:
        if not 1 <= len(data) <= self._max_samples:
            raise ValueError(f"imported recording must contain 1..{self._max_samples} samples")
        sample_count = len(data)
        vectors = (data.joint_position, data.joint_velocity, data.joint_acceleration)
        arrays = (
            data.recording_time_ns,
            data.simulation_time_s,
            data.source_sequence,
            data.simulation_epoch_id,
            data.lifecycle_code,
            data.last_input_sequence,
            data.last_input_valid,
            data.sample_sequence,
        )
        if any(array.shape[0] != sample_count for array in arrays):
            raise ValueError("imported recording columns must have identical row counts")
        if any(vector.shape != (sample_count, len(ACTIVE_JOINT_NAMES)) for vector in vectors):
            raise ValueError("imported joint columns have an invalid shape")
        if np.any(np.diff(data.recording_time_ns) <= 0):
            raise ValueError("imported recording time must be strictly increasing")
        if np.any(np.diff(data.sample_sequence) != 1):
            raise ValueError("imported sample sequence must be contiguous")
        if any(not np.all(np.isfinite(vector)) for vector in (*vectors, data.simulation_time_s)):
            raise ValueError("imported telemetry must be finite")
        if not data.simulation_epochs or np.any(
            data.simulation_epoch_id >= len(data.simulation_epochs)
        ):
            raise ValueError("imported simulation epoch references are invalid")
        if np.any(data.lifecycle_code >= len(_CODE_TO_LIFECYCLE)):
            raise ValueError("imported lifecycle values are invalid")


def materialized_chunks(
    chunks: Iterable[RecordingChunk],
) -> tuple[RecordingChunk, ...]:
    return tuple(chunks)


def _chunk_from_materialized(data: MaterializedRecording, start: int, stop: int) -> RecordingChunk:
    def copied(name: str) -> npt.NDArray[np.generic]:
        result = np.array(getattr(data, name)[start:stop], copy=True)
        result.setflags(write=False)
        return result

    return RecordingChunk(
        recording_time_ns=copied("recording_time_ns"),  # type: ignore[arg-type]
        simulation_time_s=copied("simulation_time_s"),  # type: ignore[arg-type]
        source_sequence=copied("source_sequence"),  # type: ignore[arg-type]
        simulation_epoch_id=copied("simulation_epoch_id"),  # type: ignore[arg-type]
        lifecycle_code=copied("lifecycle_code"),  # type: ignore[arg-type]
        joint_position=copied("joint_position"),  # type: ignore[arg-type]
        joint_velocity=copied("joint_velocity"),  # type: ignore[arg-type]
        joint_acceleration=copied("joint_acceleration"),  # type: ignore[arg-type]
        last_input_sequence=copied("last_input_sequence"),  # type: ignore[arg-type]
        last_input_valid=copied("last_input_valid"),  # type: ignore[arg-type]
        sample_sequence=copied("sample_sequence"),  # type: ignore[arg-type]
    )
