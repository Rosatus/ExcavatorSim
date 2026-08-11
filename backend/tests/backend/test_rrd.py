from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from babylon_sim.constants import MODEL_VERSION
from babylon_sim.recording import ChunkedRecordingBuffer
from babylon_sim.replay_contract import RRD_PROFILE, SourceMode
from babylon_sim.rrd import RrdProfileError, export_rrd, import_rrd
from babylon_sim.state import SimulationState


def _state(sequence: int) -> SimulationState:
    position = tuple(sequence * 0.125 + index for index in range(4))
    return SimulationState(
        timestamp=sequence / 100.0,
        sequence_number=sequence,
        source="rrd-test",
        model_version=MODEL_VERSION,
        calibration_version="calibration-test",
        joint_position=position,
        joint_velocity=tuple(value * -0.25 for value in position),
        joint_acceleration=tuple(value * 0.0625 for value in position),
        quality_flags=("good",) if sequence < 3 else ("joint_limit",),
    )


def _recording() -> ChunkedRecordingBuffer:
    buffer = ChunkedRecordingBuffer(chunk_samples=3, max_samples=12, recording_epoch="rrd-test")
    for sequence in range(7):
        buffer.append(
            _state(sequence),
            simulation_epoch="simulation-a" if sequence < 4 else "simulation-b",
            lifecycle="running" if sequence < 5 else "paused",
            last_input_sequence=None if sequence in {0, 6} else sequence + 100,
            monotonic_ns=10_000 + sequence * 10_000_001,
        )
    return buffer


def test_real_rrd_round_trip_is_exact(tmp_path: Path) -> None:
    source = _recording().snapshot()
    output = tmp_path / "recording.rrd"
    export_rrd(
        source,
        output,
        calibration_version="m1-provisional-2",
        source_mode=SourceMode.LIVE,
    )

    assert output.is_file()
    assert output.stat().st_size > 0
    imported = import_rrd(output)
    expected = source.materialize()
    actual = imported.data

    assert imported.profile == RRD_PROFILE
    assert imported.source_mode is SourceMode.LIVE
    assert imported.calibration_version == "m1-provisional-2"
    assert actual.simulation_epochs == expected.simulation_epochs
    assert actual.events == expected.events
    for name in (
        "recording_time_ns",
        "simulation_time_s",
        "source_sequence",
        "simulation_epoch_id",
        "lifecycle_code",
        "joint_position",
        "joint_velocity",
        "joint_acceleration",
        "last_input_sequence",
        "last_input_valid",
        "sample_sequence",
    ):
        np.testing.assert_array_equal(getattr(actual, name), getattr(expected, name))


def test_corrupt_rrd_is_rejected(tmp_path: Path) -> None:
    path = tmp_path / "corrupt.rrd"
    path.write_bytes(b"not an rrd")
    with pytest.raises(RrdProfileError, match="could not be read"):
        import_rrd(path)


def test_motion_only_protocol_v2_rrd_remains_importable() -> None:
    fixture = (
        Path(__file__).resolve().parents[1]
        / "fixtures"
        / "rrd"
        / "motion-only-protocol-v2.rrd"
    )
    imported = import_rrd(fixture)

    assert imported.profile == RRD_PROFILE
    assert imported.sample_count == 4
    assert imported.calibration_version == "m1-provisional-2"
    assert imported.data.events
