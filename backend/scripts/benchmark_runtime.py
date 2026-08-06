"""Measure the fixed-rate producer while its latest-state slot is not consumed."""

from __future__ import annotations

import argparse
import json
import platform
import time
from datetime import UTC, datetime
from pathlib import Path

from babylon_sim.calibration import MachineCalibration
from babylon_sim.constants import SIMULATION_HZ
from babylon_sim.model import ExcavatorModel
from babylon_sim.paths import CALIBRATION_PATH, URDF_PATH
from babylon_sim.runtime import RuntimeController

ROOT = Path(__file__).resolve().parents[2]


def main() -> int:
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--warmup-seconds", type=float, default=2.0)
    parser.add_argument("--measure-seconds", type=float, default=10.0)
    parser.add_argument(
        "--output",
        type=Path,
        default=ROOT / "artifacts/benchmark/runtime.json",
    )
    args = parser.parse_args()
    if args.warmup_seconds < 0 or args.measure_seconds <= 0:
        parser.error("warmup must be non-negative and measurement must be positive")

    model = ExcavatorModel.from_urdf(URDF_PATH)
    calibration = MachineCalibration.from_json(CALIBRATION_PATH)
    runtime = RuntimeController(model, calibration)
    runtime.start()
    try:
        time.sleep(args.warmup_seconds)
        initial = runtime.latest.read()
        initial_status = runtime.status_snapshot()
        started = time.perf_counter()
        # Intentionally do not read the slot during measurement. This emulates a stalled consumer.
        time.sleep(args.measure_seconds)
        elapsed = time.perf_counter() - started
        final = runtime.latest.read()
        final_status = runtime.status_snapshot()
    finally:
        runtime.stop()

    ticks = final.generation - initial.generation
    measured_hz = ticks / elapsed
    lower_bound = SIMULATION_HZ * 0.95
    upper_bound = SIMULATION_HZ * 1.05
    latest_generation = runtime.latest.read().generation
    passed = lower_bound <= measured_hz <= upper_bound and latest_generation >= final.generation
    measurement_overruns = final_status.overruns - initial_status.overruns
    report = {
        "schema_version": "babylon-sim-runtime-benchmark-v1",
        "captured_at_utc": datetime.now(UTC).isoformat(),
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "processor": platform.processor(),
        },
        "conditions": {
            "warmup_seconds": args.warmup_seconds,
            "measurement_seconds": elapsed,
            "target_simulation_hz": SIMULATION_HZ,
            "consumer": "stalled-latest-state-reader",
        },
        "metrics": {
            "published_generations": ticks,
            "simulation_hz": measured_hz,
            "overruns_during_measurement": measurement_overruns,
            "latest_slot_generation": final.generation,
        },
        "gates": {
            "simulation_hz_at_least_95_percent": measured_hz >= lower_bound,
            "simulation_hz_at_most_105_percent": measured_hz <= upper_bound,
            "producer_continued_while_consumer_stalled": ticks > 0,
        },
        "pass": passed,
    }
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        f"Runtime benchmark: {measured_hz:.2f} Hz, {ticks} publications, "
        f"{measurement_overruns} overruns."
    )
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
