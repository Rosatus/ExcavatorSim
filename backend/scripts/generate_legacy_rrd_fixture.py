"""Regenerate the committed motion-only RRD v1 fixture from a protocol-v2 producer."""

from __future__ import annotations

from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

from babylon_sim.constants import MODEL_VERSION
from babylon_sim.protocol import load_version_manifest
from babylon_sim.recording import ChunkedRecordingBuffer
from babylon_sim.replay_contract import SourceMode
from babylon_sim.rrd import export_rrd
from babylon_sim.state import SimulationState

PROJECT_ROOT = Path(__file__).resolve().parents[2]
OUTPUT = PROJECT_ROOT / "backend" / "tests" / "fixtures" / "rrd" / "motion-only-protocol-v2.rrd"


def _state(sequence: int) -> SimulationState:
    position = tuple(sequence * 0.125 + index for index in range(4))
    return SimulationState(
        timestamp=sequence / 100.0,
        sequence_number=sequence,
        source="legacy-v2-fixture",
        model_version=MODEL_VERSION,
        calibration_version="m1-provisional-2",
        joint_position=position,
        joint_velocity=tuple(value * -0.25 for value in position),
        joint_acceleration=tuple(value * 0.0625 for value in position),
        quality_flags=("good",),
    )


def main() -> None:
    recording = ChunkedRecordingBuffer(
        chunk_samples=3, max_samples=12, recording_epoch="legacy-protocol-v2"
    )
    for sequence in range(4):
        recording.append(
            _state(sequence),
            simulation_epoch="legacy-simulation",
            lifecycle="running",
            last_input_sequence=None,
            monotonic_ns=10_000 + sequence * 10_000_001,
        )
    producer_manifest = replace(load_version_manifest(), protocol_version="babylon-sim-v2")
    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    with patch("babylon_sim.rrd.load_version_manifest", return_value=producer_manifest):
        export_rrd(
            recording.snapshot(),
            OUTPUT,
            calibration_version="m1-provisional-2",
            source_mode=SourceMode.LIVE,
        )
    print(f"Generated {OUTPUT} ({OUTPUT.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
