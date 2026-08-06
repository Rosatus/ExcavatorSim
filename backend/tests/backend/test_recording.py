from __future__ import annotations

import threading

import numpy as np
import pytest

from babylon_sim.recording import ChunkedRecordingBuffer
from babylon_sim.series import SeriesQueryError, project_series
from babylon_sim.state import SimulationState


def _state(sequence: int, *, quality_flags: tuple[str, ...] = ()) -> SimulationState:
    value = float(sequence)
    return SimulationState(
        timestamp=value / 100.0,
        sequence_number=sequence,
        source="test",
        model_version="model",
        calibration_version="calibration",
        joint_position=(value, value + 1.0, value + 2.0, value + 3.0),
        joint_velocity=(0.1, 0.2, 0.3, 0.4),
        joint_acceleration=(1.0, 2.0, 3.0, 4.0),
        quality_flags=quality_flags,
    )


def _append(
    buffer: ChunkedRecordingBuffer,
    sequence: int,
    *,
    monotonic_ns: int | None = None,
) -> None:
    buffer.append(
        _state(sequence),
        simulation_epoch="simulation-a",
        lifecycle="running",
        last_input_sequence=sequence,
        monotonic_ns=sequence * 10 if monotonic_ns is None else monotonic_ns,
    )


def test_sealed_and_active_snapshot_arrays_are_immutable() -> None:
    buffer = ChunkedRecordingBuffer(chunk_samples=3, max_samples=6, recording_epoch="recording-a")
    for sequence in range(4):
        _append(buffer, sequence)

    first = buffer.snapshot()
    assert first.recording_epoch == "recording-a"
    assert first.sample_count == 4
    assert len(first.chunks) == 2
    assert all(not chunk.recording_time_ns.flags.writeable for chunk in first.chunks)
    assert all(not chunk.joint_position.flags.writeable for chunk in first.chunks)

    _append(buffer, 4)
    assert first.sample_count == 4
    np.testing.assert_array_equal(first.materialize().sample_sequence, [0, 1, 2, 3])


def test_rollover_evicts_whole_chunks_without_exceeding_capacity() -> None:
    buffer = ChunkedRecordingBuffer(chunk_samples=3, max_samples=6)
    for sequence in range(9):
        _append(buffer, sequence)
        assert buffer.snapshot().sample_count <= 6

    snapshot = buffer.snapshot()
    assert snapshot.evicted_samples == 3
    assert snapshot.sample_count == 6
    np.testing.assert_array_equal(snapshot.materialize().sample_sequence, [3, 4, 5, 6, 7, 8])
    assert snapshot.retained_start_ns == 30
    assert snapshot.retained_end_ns == 80


def test_recording_time_is_strictly_increasing_when_clock_stalls_or_moves_backward() -> None:
    buffer = ChunkedRecordingBuffer(chunk_samples=4, max_samples=8)
    for sequence, monotonic_ns in enumerate((100, 100, 50, 101)):
        _append(buffer, sequence, monotonic_ns=monotonic_ns)

    data = buffer.snapshot().materialize()
    np.testing.assert_array_equal(data.recording_time_ns, [0, 1, 2, 3])


def test_concurrent_reader_snapshots_remain_consistent() -> None:
    buffer = ChunkedRecordingBuffer(chunk_samples=10, max_samples=100)
    snapshots = []

    def write() -> None:
        for sequence in range(100):
            _append(buffer, sequence)

    writer = threading.Thread(target=write)
    writer.start()
    while writer.is_alive():
        snapshots.append(buffer.snapshot())
    writer.join(timeout=1.0)
    snapshots.append(buffer.snapshot())

    for snapshot in snapshots:
        if snapshot.sample_count == 0:
            continue
        data = snapshot.materialize()
        assert len(data) == snapshot.sample_count
        assert np.all(np.diff(data.sample_sequence) == 1)
        assert np.all(np.diff(data.recording_time_ns) > 0)
    assert snapshots[-1].sample_count == 100


def test_sample_lookup_clamps_to_retained_bounds() -> None:
    buffer = ChunkedRecordingBuffer(chunk_samples=3, max_samples=6)
    for sequence in range(6):
        _append(buffer, sequence)
    snapshot = buffer.snapshot()

    assert snapshot.sample_at_or_before(-1).sample_sequence == 0
    assert snapshot.sample_at_or_before(25).sample_sequence == 2
    assert snapshot.sample_at_or_before(999).sample_sequence == 5


def test_series_projection_clips_and_preserves_bucket_extrema() -> None:
    buffer = ChunkedRecordingBuffer(chunk_samples=10, max_samples=20)
    for sequence in range(10):
        _append(buffer, sequence)
    result = project_series(
        buffer.snapshot(),
        ("joint_position.swing_joint", "simulation_time_s"),
        0,
        999,
        max_buckets=2,
    )

    assert result.actual_start_ns == 0
    assert result.actual_end_ns == 90
    assert result.bucket_start_ns == (0, 50)
    assert result.bucket_end_ns == (40, 90)
    assert result.series["joint_position.swing_joint"].minimum == (0.0, 5.0)
    assert result.series["joint_position.swing_joint"].maximum == (4.0, 9.0)


def test_series_projection_reads_only_the_window_across_multiple_chunks() -> None:
    buffer = ChunkedRecordingBuffer(chunk_samples=4, max_samples=16)
    for sequence in range(12):
        _append(buffer, sequence)

    result = project_series(
        buffer.snapshot(),
        ("joint_position.swing_joint", "joint_position.bucket_joint"),
        25,
        85,
        max_buckets=3,
    )

    assert result.actual_start_ns == 30
    assert result.actual_end_ns == 80
    assert result.bucket_start_ns == (30, 50, 70)
    assert result.bucket_end_ns == (40, 60, 80)
    assert result.series["joint_position.swing_joint"].minimum == (3.0, 5.0, 7.0)
    assert result.series["joint_position.swing_joint"].maximum == (4.0, 6.0, 8.0)
    assert result.series["joint_position.bucket_joint"].minimum == (6.0, 8.0, 10.0)
    assert result.series["joint_position.bucket_joint"].maximum == (7.0, 9.0, 11.0)


def test_series_projection_rejects_unknown_or_unbounded_requests() -> None:
    buffer = ChunkedRecordingBuffer(chunk_samples=3, max_samples=6)
    _append(buffer, 0)
    snapshot = buffer.snapshot()

    with pytest.raises(SeriesQueryError, match="unsupported"):
        project_series(snapshot, ("joint_position.unknown",), 0, 1, max_buckets=1)
    with pytest.raises(SeriesQueryError, match="between 1"):
        project_series(snapshot, ("simulation_time_s",), 0, 1, max_buckets=4_097)
