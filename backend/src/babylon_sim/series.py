"""Bounded numeric range projection for timeline and chart clients."""

from __future__ import annotations

from dataclasses import dataclass

import numpy as np
import numpy.typing as npt

from .constants import ACTIVE_JOINT_NAMES
from .recording import BufferSnapshot, RecordingChunk, RecordingEvent
from .replay_contract import RECORDING_RANGE_MAX_BUCKETS, SERIES_FIELDS


class SeriesQueryError(ValueError):
    pass


@dataclass(frozen=True)
class SeriesEnvelope:
    minimum: tuple[float, ...]
    maximum: tuple[float, ...]


@dataclass(frozen=True)
class SeriesRange:
    recording_epoch: str
    buffer_generation: int
    end_sample_sequence: int
    requested_start_ns: int
    requested_end_ns: int
    actual_start_ns: int | None
    actual_end_ns: int | None
    retained_start_ns: int | None
    retained_end_ns: int | None
    bucket_start_ns: tuple[int, ...]
    bucket_end_ns: tuple[int, ...]
    series: dict[str, SeriesEnvelope]
    events: tuple[RecordingEvent, ...]

    def as_dict(self) -> dict[str, object]:
        return {
            "recording_epoch": self.recording_epoch,
            "buffer_generation": self.buffer_generation,
            "end_sample_sequence": self.end_sample_sequence,
            "requested_start_ns": self.requested_start_ns,
            "requested_end_ns": self.requested_end_ns,
            "actual_start_ns": self.actual_start_ns,
            "actual_end_ns": self.actual_end_ns,
            "retained_start_ns": self.retained_start_ns,
            "retained_end_ns": self.retained_end_ns,
            "bucket_start_ns": list(self.bucket_start_ns),
            "bucket_end_ns": list(self.bucket_end_ns),
            "series": {
                field: {"minimum": list(envelope.minimum), "maximum": list(envelope.maximum)}
                for field, envelope in self.series.items()
            },
            "events": [
                {
                    "sample_sequence": event.sample_sequence,
                    "recording_time_ns": event.recording_time_ns,
                    "kind": event.kind,
                    "value": event.value,
                }
                for event in self.events
            ],
        }


def project_series(
    snapshot: BufferSnapshot,
    fields: tuple[str, ...],
    requested_start_ns: int,
    requested_end_ns: int,
    *,
    max_buckets: int,
) -> SeriesRange:
    if not fields:
        raise SeriesQueryError("at least one field is required")
    if len(fields) != len(set(fields)):
        raise SeriesQueryError("series fields must be unique")
    unsupported = sorted(set(fields) - set(SERIES_FIELDS))
    if unsupported:
        raise SeriesQueryError(f"unsupported series field: {unsupported[0]}")
    if requested_start_ns < 0 or requested_end_ns < requested_start_ns:
        raise SeriesQueryError("range bounds must be ordered non-negative nanoseconds")
    if not 1 <= max_buckets <= RECORDING_RANGE_MAX_BUCKETS:
        raise SeriesQueryError(f"max_points must be between 1 and {RECORDING_RANGE_MAX_BUCKETS}")
    retained_start = snapshot.retained_start_ns
    retained_end = snapshot.retained_end_ns
    if retained_start is None or retained_end is None:
        return _empty(snapshot, fields, requested_start_ns, requested_end_ns)

    actual_start = max(requested_start_ns, retained_start)
    actual_end = min(requested_end_ns, retained_end)
    if actual_start > actual_end:
        return _empty(snapshot, fields, requested_start_ns, requested_end_ns)

    windows: list[tuple[RecordingChunk, int, int]] = []
    for chunk in snapshot.chunks:
        if int(chunk.recording_time_ns[-1]) < actual_start:
            continue
        if int(chunk.recording_time_ns[0]) > actual_end:
            break
        left = int(np.searchsorted(chunk.recording_time_ns, actual_start, side="left"))
        right = int(np.searchsorted(chunk.recording_time_ns, actual_end, side="right"))
        if left >= right:
            continue
        windows.append((chunk, left, right))
    if not windows:
        return _empty(snapshot, fields, requested_start_ns, requested_end_ns)
    time_parts = [chunk.recording_time_ns[left:right] for chunk, left, right in windows]
    times = time_parts[0] if len(time_parts) == 1 else np.concatenate(time_parts)
    columns: dict[str, npt.NDArray[np.float64]] = {}
    if "simulation_time_s" in fields:
        parts = [chunk.simulation_time_s[left:right] for chunk, left, right in windows]
        columns["simulation_time_s"] = (
            parts[0] if len(parts) == 1 else np.concatenate(parts)
        )
    for prefix, attribute in (
        ("joint_position", "joint_position"),
        ("joint_velocity", "joint_velocity"),
        ("joint_acceleration", "joint_acceleration"),
    ):
        selected = tuple(field for field in fields if field.startswith(f"{prefix}."))
        if not selected:
            continue
        parts = [getattr(chunk, attribute)[left:right] for chunk, left, right in windows]
        matrix = parts[0] if len(parts) == 1 else np.concatenate(parts, axis=0)
        for field in selected:
            joint = field.split(".", 1)[1]
            columns[field] = matrix[:, ACTIVE_JOINT_NAMES.index(joint)]
    sample_count = len(times)
    bucket_count = min(sample_count, max_buckets)
    edges = np.linspace(0, sample_count, bucket_count + 1, dtype=np.int64)
    starts = times[edges[:-1]]
    ends = times[edges[1:] - 1]
    minima = {field: np.minimum.reduceat(values, edges[:-1]) for field, values in columns.items()}
    maxima = {field: np.maximum.reduceat(values, edges[:-1]) for field, values in columns.items()}

    events = tuple(
        event for event in snapshot.events if actual_start <= event.recording_time_ns <= actual_end
    )
    return SeriesRange(
        recording_epoch=snapshot.recording_epoch,
        buffer_generation=snapshot.buffer_generation,
        end_sample_sequence=snapshot.end_sample_sequence,
        requested_start_ns=requested_start_ns,
        requested_end_ns=requested_end_ns,
        actual_start_ns=int(times[0]),
        actual_end_ns=int(times[-1]),
        retained_start_ns=retained_start,
        retained_end_ns=retained_end,
        bucket_start_ns=tuple(starts.tolist()),
        bucket_end_ns=tuple(ends.tolist()),
        series={
            field: SeriesEnvelope(
                tuple(minima[field].tolist()),
                tuple(maxima[field].tolist()),
            )
            for field in fields
        },
        events=events,
    )


def _empty(
    snapshot: BufferSnapshot,
    fields: tuple[str, ...],
    requested_start_ns: int,
    requested_end_ns: int,
) -> SeriesRange:
    return SeriesRange(
        recording_epoch=snapshot.recording_epoch,
        buffer_generation=snapshot.buffer_generation,
        end_sample_sequence=snapshot.end_sample_sequence,
        requested_start_ns=requested_start_ns,
        requested_end_ns=requested_end_ns,
        actual_start_ns=None,
        actual_end_ns=None,
        retained_start_ns=snapshot.retained_start_ns,
        retained_end_ns=snapshot.retained_end_ns,
        bucket_start_ns=(),
        bucket_end_ns=(),
        series={field: SeriesEnvelope((), ()) for field in fields},
        events=(),
    )
