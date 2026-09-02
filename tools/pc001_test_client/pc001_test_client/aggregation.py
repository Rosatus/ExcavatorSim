"""Bounded latest-value aggregation for decoded PC001 frames."""

from __future__ import annotations

from collections import deque
from dataclasses import dataclass, field

from .protocol import Pc001Batch, Pc001Frame


@dataclass(frozen=True, order=True, slots=True)
class FrameKey:
    is_extended: bool
    can_id: int
    channel: int


@dataclass(frozen=True, slots=True)
class FrameSnapshot:
    key: FrameKey
    dlc: int
    payload: bytes
    count: int
    last_received_s: float
    actual_hz: float | None


@dataclass(slots=True)
class _MutableFrameStats:
    dlc: int
    payload: bytes
    count: int
    last_received_s: float
    timestamps: deque[float] = field(default_factory=lambda: deque(maxlen=10))


class FrameAccumulator:
    """Keep only the newest value and bounded timing history per identity."""

    def __init__(self, *, max_rows: int = 4096) -> None:
        if max_rows <= 0:
            raise ValueError("max_rows must be positive")
        self._max_rows = max_rows
        self._rows: dict[FrameKey, _MutableFrameStats] = {}
        self._dirty: set[FrameKey] = set()
        self.total_batches = 0
        self.total_frames = 0
        self.dropped_new_identities = 0

    def add_batch(self, batch: Pc001Batch, received_s: float) -> None:
        self.total_batches += 1
        for frame in batch.frames:
            self.add_frame(frame, received_s)

    def add_frame(self, frame: Pc001Frame, received_s: float) -> None:
        self.total_frames += 1
        key = FrameKey(frame.is_extended, frame.can_id, frame.channel)
        stats = self._rows.get(key)
        if stats is None:
            if len(self._rows) >= self._max_rows:
                self.dropped_new_identities += 1
                return
            stats = _MutableFrameStats(frame.dlc, frame.payload, 0, received_s)
            self._rows[key] = stats
        stats.dlc = frame.dlc
        stats.payload = frame.payload
        stats.count += 1
        stats.last_received_s = received_s
        stats.timestamps.append(received_s)
        self._dirty.add(key)

    def drain_dirty(self) -> tuple[FrameSnapshot, ...]:
        snapshots = tuple(self._snapshot(key, self._rows[key]) for key in sorted(self._dirty))
        self._dirty.clear()
        return snapshots

    def all_snapshots(self) -> tuple[FrameSnapshot, ...]:
        return tuple(self._snapshot(key, self._rows[key]) for key in sorted(self._rows))

    def clear(self) -> None:
        self._rows.clear()
        self._dirty.clear()
        self.total_batches = 0
        self.total_frames = 0
        self.dropped_new_identities = 0

    @staticmethod
    def _snapshot(key: FrameKey, stats: _MutableFrameStats) -> FrameSnapshot:
        actual_hz: float | None = None
        if len(stats.timestamps) >= 2:
            elapsed = stats.timestamps[-1] - stats.timestamps[0]
            if elapsed > 0.0:
                actual_hz = (len(stats.timestamps) - 1) / elapsed
        return FrameSnapshot(
            key=key,
            dlc=stats.dlc,
            payload=stats.payload,
            count=stats.count,
            last_received_s=stats.last_received_s,
            actual_hz=actual_hz,
        )
