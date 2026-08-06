"""Measure full-capacity time-series projection against the recording contract."""

from __future__ import annotations

import argparse
import json
import platform
import time
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

from babylon_sim.calibration import MachineCalibration
from babylon_sim.constants import SIMULATION_HZ
from babylon_sim.model import ExcavatorModel
from babylon_sim.paths import CALIBRATION_PATH, URDF_PATH
from babylon_sim.recording import ChunkedRecordingBuffer, MaterializedRecording
from babylon_sim.replay_contract import (
    JOINT_SIGNAL_FIELDS,
    RECORDING_MAX_SAMPLES,
    RECORDING_RANGE_MAX_BUCKETS,
)
from babylon_sim.runtime import RuntimeController
from babylon_sim.series import project_series

ROOT = Path(__file__).resolve().parents[2]


def _full_recording() -> MaterializedRecording:
    count = RECORDING_MAX_SAMPLES
    recording_time_ns = np.arange(count, dtype=np.int64) * 10_000_000
    sequence = np.arange(count, dtype=np.uint64)
    base = np.linspace(-1.0, 1.0, count, dtype=np.float64)
    joints = np.column_stack((base, base * 2.0, base * 3.0, base * 4.0))
    return MaterializedRecording(
        recording_time_ns=recording_time_ns,
        simulation_time_s=recording_time_ns.astype(np.float64) / 1_000_000_000,
        source_sequence=sequence,
        simulation_epoch_id=np.zeros(count, dtype=np.uint32),
        lifecycle_code=np.ones(count, dtype=np.uint8),
        joint_position=joints,
        joint_velocity=joints * 0.1,
        joint_acceleration=joints * 0.01,
        last_input_sequence=sequence,
        last_input_valid=np.ones(count, dtype=np.bool_),
        sample_sequence=sequence,
        simulation_epochs=("benchmark",),
        events=(),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--warmup-seconds", type=float, default=2.0)
    parser.add_argument("--measure-seconds", type=float, default=10.0)
    parser.add_argument("--queries-per-second", type=float, default=5.0)
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "artifacts/benchmark/series.json",
    )
    args = parser.parse_args()
    if args.warmup_seconds < 0 or args.measure_seconds <= 0 or args.queries_per_second <= 0:
        parser.error("warmup must be non-negative and measurement/rate must be positive")

    buffer = ChunkedRecordingBuffer()
    buffer.install_imported(_full_recording())
    snapshot = buffer.snapshot()
    fields = tuple(JOINT_SIGNAL_FIELDS)
    end_ns = snapshot.retained_end_ns
    assert end_ns is not None

    runtime = RuntimeController(
        ExcavatorModel.from_urdf(URDF_PATH),
        MachineCalibration.from_json(CALIBRATION_PATH),
    )
    runtime.start()
    durations_ms: list[float] = []
    try:
        time.sleep(args.warmup_seconds)
        initial = runtime.latest.read()
        started_measurement = time.perf_counter()
        next_query = started_measurement
        query_interval = 1.0 / args.queries_per_second
        result = None
        while time.perf_counter() - started_measurement < args.measure_seconds:
            started_query = time.perf_counter()
            result = project_series(
                snapshot,
                fields,
                0,
                end_ns,
                max_buckets=RECORDING_RANGE_MAX_BUCKETS,
            )
            durations_ms.append((time.perf_counter() - started_query) * 1_000)
            next_query += query_interval
            time.sleep(max(0.0, next_query - time.perf_counter()))
        elapsed = time.perf_counter() - started_measurement
        final = runtime.latest.read()
    finally:
        runtime.stop()
    assert result is not None
    measured_hz = (final.generation - initial.generation) / elapsed
    p95_ms = float(np.percentile(durations_ms, 95))
    passed = (
        snapshot.sample_count == RECORDING_MAX_SAMPLES
        and len(snapshot.chunks) == RECORDING_MAX_SAMPLES // 100
        and len(result.bucket_start_ns) == RECORDING_RANGE_MAX_BUCKETS
        and p95_ms < 100.0
        and SIMULATION_HZ * 0.95 <= measured_hz <= SIMULATION_HZ * 1.05
    )
    report = {
        "schema_version": "babylon-sim-series-benchmark-v1",
        "captured_at_utc": datetime.now(UTC).isoformat(),
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "numpy": np.__version__,
        },
        "conditions": {
            "samples": snapshot.sample_count,
            "chunks": len(snapshot.chunks),
            "fields": len(fields),
            "max_buckets": RECORDING_RANGE_MAX_BUCKETS,
            "warmup_seconds": args.warmup_seconds,
            "measurement_seconds": elapsed,
            "queries_per_second": args.queries_per_second,
        },
        "metrics": {
            "query_ms": durations_ms,
            "p50_ms": float(np.percentile(durations_ms, 50)),
            "p95_ms": p95_ms,
            "simulation_hz": measured_hz,
        },
        "gates": {
            "full_buffer_query_p95_below_100_ms": p95_ms < 100.0,
            "simulation_hz_at_least_95_percent": measured_hz >= SIMULATION_HZ * 0.95,
            "simulation_hz_at_most_105_percent": measured_hz <= SIMULATION_HZ * 1.05,
        },
        "pass": passed,
    }
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"Series benchmark: {p95_ms:.2f} ms P95 for "
        f"{len(fields)} fields / {snapshot.sample_count} samples; runtime {measured_hz:.2f} Hz."
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
