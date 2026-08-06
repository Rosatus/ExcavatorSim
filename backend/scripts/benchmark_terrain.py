"""Measure terrain editing, reconstruction, snapshots, and runtime isolation."""

from __future__ import annotations

import argparse
import json
import platform
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

import numpy as np

from babylon_sim.calibration import MachineCalibration
from babylon_sim.model import ExcavatorModel
from babylon_sim.paths import CALIBRATION_PATH, URDF_PATH
from babylon_sim.protocol import encode_server_message
from babylon_sim.recording import ChunkedRecordingBuffer
from babylon_sim.replay_contract import SourceMode
from babylon_sim.runtime import RuntimeController
from babylon_sim.terrain import generate_terrain
from babylon_sim.terrain_controller import TerrainController
from babylon_sim.terrain_excavation import (
    BUCKET_CAPACITY_M3,
    MAX_DIRTY_CELLS,
    MAX_PATCH_BYTES,
    MAX_RELAXATION_CELL_VISITS,
    MAX_RELAXATION_PASSES,
    TERRAIN_EDIT_HZ,
    TERRAIN_HISTORY_BYTES,
    TerrainEditInput,
    TerrainTimeline,
)

ROOT = Path(__file__).resolve().parents[2]
FRONTEND_CACHE_BYTES = 32 * 1024 * 1024
MAXIMUM_GRID_SPEC: dict[str, object] = {
    "terrain_spec_version": "terrain-spec-v1",
    "kind": "flat",
    "width_m": 50.0,
    "depth_m": 50.0,
    "spacing_m": 0.25,
    "elevation_m": 0.0,
    "seed": 0,
    "noise_amplitude_m": 0.0,
    "noise_scale_m": 4.0,
}


def _percentile(values: list[float], percentile: float) -> float:
    return float(np.percentile(values, percentile))


def _edit(recording_epoch: str, index: int) -> TerrainEditInput:
    cycle = index % 20
    lane = (index // 20) % 10
    y = -1.35 + lane * 0.3
    if cycle < 14:
        start_x = -1.4 + cycle * 0.2
        end_x = start_x + 0.35
        z = -0.1
        posture = 0.2
    else:
        start_x = end_x = 1.5
        z = 1.0
        posture = 0.9
    previous = (
        (start_x, y - 0.25, z),
        (start_x, y, z),
        (start_x, y + 0.25, z),
    )
    current = (
        (end_x, y - 0.25, z),
        (end_x, y, z),
        (end_x, y + 0.25, z),
    )
    sample_sequence = (index + 1) * 4
    return TerrainEditInput(
        recording_epoch=recording_epoch,
        sample_sequence=sample_sequence,
        recording_time_ns=(index + 1) * 40_000_000,
        stream_epoch="terrain-benchmark-stream",
        previous_teeth=previous,
        current_teeth=current,
        bucket_joint_normalized=posture,
    )


def _prepared_timeline() -> tuple[TerrainTimeline, int]:
    baseline = generate_terrain(MAXIMUM_GRID_SPEC)
    timeline = TerrainTimeline(baseline, start_sample_sequence=0)
    attempts = 0
    while timeline.current_revision < 40 and attempts < 240:
        timeline.apply(_edit("maximum-grid-benchmark", attempts))
        attempts += 1
    if timeline.current_revision < 2:
        raise RuntimeError("terrain benchmark could not create historical revisions")
    return timeline, max(1, timeline.current_revision // 2)


def _runtime_rate(runtime: RuntimeController, started: float, generation: int) -> float:
    elapsed = time.perf_counter() - started
    return (runtime.latest.read().generation - generation) / elapsed


def _browser_evidence() -> dict[str, Any] | None:
    path = ROOT / "artifacts/benchmark/browser.json"
    if not path.exists():
        return None
    raw = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(raw, dict) or not isinstance(raw.get("metrics"), dict):
        raise RuntimeError("browser benchmark evidence is malformed")
    return raw


def main() -> int:
    parser = argparse.ArgumentParser(formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--warmup-seconds", type=float, default=2.0)
    parser.add_argument("--edit-seconds", type=float, default=10.0)
    parser.add_argument("--snapshot-seconds", type=float, default=2.0)
    parser.add_argument("--seek-seconds", type=float, default=2.0)
    parser.add_argument("--output", type=Path, default=ROOT / "artifacts/benchmark/terrain.json")
    args = parser.parse_args()
    if min(args.warmup_seconds, args.edit_seconds, args.snapshot_seconds, args.seek_seconds) <= 0:
        parser.error("all benchmark durations must be positive")

    timeline, historical_revision = _prepared_timeline()
    maximum_grid = timeline.baseline
    recording = ChunkedRecordingBuffer()
    terrain = TerrainController(recording)
    recording_epoch = recording.recording_epoch
    runtime = RuntimeController(
        ExcavatorModel.from_urdf(URDF_PATH),
        MachineCalibration.from_json(CALIBRATION_PATH),
    )
    generation_ms: list[float] = []
    materialization_ms: list[float] = []
    serialization_ms: list[float] = []
    client_copy_ms: list[float] = []
    snapshot_pipeline_ms: list[float] = []
    seek_ms: list[float] = []
    dirty_cells: list[float] = []
    patch_bytes: list[float] = []
    relaxation_passes: list[float] = []
    relaxation_touched_cells: list[float] = []
    relaxation_cell_visits: list[float] = []
    relaxation_bucket_residual_m3: list[float] = []
    relaxation_converged: list[bool] = []
    runtime.start()
    try:
        time.sleep(args.warmup_seconds)

        snapshot_generation = runtime.latest.read().generation
        snapshot_started = time.perf_counter()
        while time.perf_counter() - snapshot_started < args.snapshot_seconds:
            pipeline_started = time.perf_counter()
            started = time.perf_counter()
            generated = generate_terrain(MAXIMUM_GRID_SPEC)
            generation_ms.append((time.perf_counter() - started) * 1_000)
            if generated.snapshot_sha256 != maximum_grid.snapshot_sha256:
                raise RuntimeError("maximum-grid generation is not deterministic")
            started = time.perf_counter()
            materialized = timeline.materialize_revision(historical_revision)
            materialization_ms.append((time.perf_counter() - started) * 1_000)
            started = time.perf_counter()
            payload = materialized.heights.astype("<f4", copy=False).tobytes(order="C")
            serialization_ms.append((time.perf_counter() - started) * 1_000)
            started = time.perf_counter()
            client_heights = np.frombuffer(payload, dtype="<f4").copy()
            client_copy_ms.append((time.perf_counter() - started) * 1_000)
            if client_heights.size != maximum_grid.domain.point_count:
                raise RuntimeError("maximum-grid snapshot shape changed")
            snapshot_pipeline_ms.append((time.perf_counter() - pipeline_started) * 1_000)
        snapshot_runtime_hz = _runtime_rate(runtime, snapshot_started, snapshot_generation)

        seek_generation = runtime.latest.read().generation
        seek_started = time.perf_counter()
        while time.perf_counter() - seek_started < args.seek_seconds:
            started = time.perf_counter()
            timeline.materialize_revision(historical_revision)
            seek_ms.append((time.perf_counter() - started) * 1_000)
        seek_runtime_hz = _runtime_rate(runtime, seek_started, seek_generation)

        submitted = max(2, round(args.edit_seconds * TERRAIN_EDIT_HZ))
        initial_processed = terrain.processed_edit_inputs
        edit_generation = runtime.latest.read().generation
        edit_started = time.perf_counter()
        deadline = edit_started
        last_revision = 0
        last_diagnostic_revision = 0
        terrain_epoch: str | None = None
        for index in range(submitted):
            terrain.submit_live_edit(_edit(recording_epoch, index))
            deadline += 1.0 / TERRAIN_EDIT_HZ
            time.sleep(max(0.0, deadline - time.perf_counter()))
            view = terrain.view_for(recording_epoch, (index + 1) * 4, SourceMode.LIVE)
            terrain_epoch = view.terrain_epoch
            latest_event = terrain.latest_edit_event
            if latest_event is not None and latest_event.revision > last_diagnostic_revision:
                last_diagnostic_revision = latest_event.revision
                if latest_event.operation == "deposit":
                    relaxation_passes.append(float(latest_event.relaxation_passes))
                    relaxation_touched_cells.append(float(latest_event.relaxation_touched_cells))
                    relaxation_cell_visits.append(float(latest_event.relaxation_cell_visits))
                    relaxation_bucket_residual_m3.append(latest_event.bucket_residual_m3)
                    relaxation_converged.append(latest_event.relaxation_converged)
            for revision in range(last_revision + 1, view.terrain_revision + 1):
                patch = terrain.patch_for(view.terrain_epoch, revision)
                if patch is None:
                    continue
                dirty_cells.append(float(len(patch.indices)))
                wire = encode_server_message(
                    patch.as_message(recording_epoch, view.terrain_epoch)
                ).encode("utf-8")
                patch_bytes.append(float(len(wire)))
            last_revision = view.terrain_revision
        edit_elapsed = time.perf_counter() - edit_started
        processing_deadline = time.perf_counter() + 2.0
        while (
            terrain.processed_edit_inputs - initial_processed < submitted
            and time.perf_counter() < processing_deadline
        ):
            time.sleep(0.005)
        processed = terrain.processed_edit_inputs - initial_processed
        final_view = terrain.view_for(recording_epoch, submitted * 4, SourceMode.LIVE)
        edit_runtime_hz = (runtime.latest.read().generation - edit_generation) / (
            time.perf_counter() - edit_started
        )
    finally:
        terrain.close()
        runtime.stop()

    if not dirty_cells or not patch_bytes or terrain_epoch is None:
        raise RuntimeError("sustained terrain benchmark produced no visible patches")
    if not relaxation_passes:
        raise RuntimeError("sustained terrain benchmark produced no relaxation evidence")

    browser = _browser_evidence()
    browser_metrics = {} if browser is None else dict(browser["metrics"])
    browser_gates = {} if browser is None else dict(browser.get("gates", {}))
    browser_captured_at = None if browser is None else browser.get("capturedAtUtc")
    browser_fresh = False
    if isinstance(browser_captured_at, str):
        try:
            captured = datetime.fromisoformat(browser_captured_at.replace("Z", "+00:00"))
            browser_age_seconds = (datetime.now(UTC) - captured).total_seconds()
            browser_fresh = 0.0 <= browser_age_seconds <= 30 * 60
        except ValueError:
            browser_fresh = False
    p95_snapshot_ms = _percentile(snapshot_pipeline_ms, 95)
    p95_patch_bytes = _percentile(patch_bytes, 95)
    edit_input_hz = submitted / edit_elapsed
    processed_edit_hz = processed / edit_elapsed
    dropped_ratio = terrain.dropped_edit_inputs / submitted
    runtime_rates = {
        "sustained_dig": edit_runtime_hz,
        "maximum_grid_snapshot": snapshot_runtime_hz,
        "historical_seek": seek_runtime_hz,
    }
    backend_gates = {
        "edit_input_hz_between_24_and_26": 24.0 <= edit_input_hz <= 26.0,
        "worker_processed_hz_between_24_and_26": 24.0 <= processed_edit_hz <= 26.0,
        "worker_processed_every_submitted_input": processed == submitted,
        "dropped_edit_ratio_at_most_1_percent": dropped_ratio <= 0.01,
        "edit_worker_has_no_fault": terrain.edit_fault is None,
        "dirty_cells_at_most_4096": max(dirty_cells) <= MAX_DIRTY_CELLS,
        "wire_patch_at_most_256_kib": max(patch_bytes) <= MAX_PATCH_BYTES,
        "maximum_grid_snapshot_pipeline_p95_below_250_ms": p95_snapshot_ms < 250.0,
        "history_within_128_mib": timeline.history_bytes <= TERRAIN_HISTORY_BYTES,
        "relaxation_all_accepted_deposits_converged": all(relaxation_converged),
        "relaxation_passes_within_budget": max(relaxation_passes) <= MAX_RELAXATION_PASSES,
        "relaxation_touched_cells_at_most_4096": max(relaxation_touched_cells) <= MAX_DIRTY_CELLS,
        "relaxation_cell_visits_within_budget": max(relaxation_cell_visits)
        <= MAX_RELAXATION_CELL_VISITS,
        "relaxation_bucket_residual_within_capacity": max(relaxation_bucket_residual_m3)
        <= BUCKET_CAPACITY_M3,
        "frontend_cache_policy_at_most_32_mib": FRONTEND_CACHE_BYTES <= 32 * 1024 * 1024,
        "runtime_sustained_dig_between_95_and_105_hz": 95.0 <= edit_runtime_hz <= 105.0,
        "runtime_snapshot_between_95_and_105_hz": 95.0 <= snapshot_runtime_hz <= 105.0,
        "runtime_seek_between_95_and_105_hz": 95.0 <= seek_runtime_hz <= 105.0,
    }
    client_gates = (
        {}
        if browser is None
        else {
            "browser_reference_passed": bool(browser.get("pass")),
            "browser_evidence_captured_within_30_minutes": browser_fresh,
            "browser_terrain_patch_to_visible_p95_below_100_ms": bool(
                browser_gates.get("terrainPatchToVisibleP95Below100Ms")
            ),
            "browser_every_applicable_patch_became_visible": bool(
                browser_gates.get("terrainEveryApplicablePatchVisible")
            ),
            "browser_maximum_grid_apply_below_250_ms": bool(
                browser_gates.get("maximumGridSnapshotApplyBelow250Ms")
            ),
        }
    )
    gates = {**backend_gates, **client_gates}
    report = {
        "schema_version": "babylon-sim-terrain-benchmark-v1",
        "captured_at_utc": datetime.now(UTC).isoformat(),
        "environment": {
            "platform": platform.platform(),
            "python": platform.python_version(),
            "numpy": np.__version__,
        },
        "identities": {
            "terrain_spec_version": "terrain-spec-v1",
            "terrain_algorithm_version": maximum_grid.algorithm_version,
            "terrain_config_id": maximum_grid.config_id,
            "recording_epoch": recording_epoch,
            "terrain_epoch": terrain_epoch,
        },
        "conditions": {
            "grid": {
                "rows": maximum_grid.domain.rows,
                "columns": maximum_grid.domain.columns,
                "cells": maximum_grid.domain.point_count,
                "snapshot_bytes": maximum_grid.domain.point_count * 4,
            },
            "target_edit_hz": TERRAIN_EDIT_HZ,
            "edit_seconds": edit_elapsed,
            "snapshot_seconds": args.snapshot_seconds,
            "seek_seconds": args.seek_seconds,
            "historical_revision": historical_revision,
        },
        "metrics": {
            "submitted_edit_inputs": submitted,
            "processed_edit_inputs": processed,
            "visible_edit_revisions": final_view.terrain_revision,
            "dropped_edit_inputs": terrain.dropped_edit_inputs,
            "edit_input_hz": edit_input_hz,
            "processed_edit_hz": processed_edit_hz,
            "dirty_cells": {
                "p50": _percentile(dirty_cells, 50),
                "p95": _percentile(dirty_cells, 95),
                "max": max(dirty_cells),
            },
            "wire_patch_bytes": {
                "p50": _percentile(patch_bytes, 50),
                "p95": p95_patch_bytes,
                "max": max(patch_bytes),
            },
            "snapshot_ms": {
                "generation_p95": _percentile(generation_ms, 95),
                "materialization_p95": _percentile(materialization_ms, 95),
                "serialization_p95": _percentile(serialization_ms, 95),
                "client_copy_p95": _percentile(client_copy_ms, 95),
                "pipeline_p95": p95_snapshot_ms,
                "browser_apply": browser_metrics.get("maximumGridSnapshotApplyMs"),
            },
            "historical_seek_p95_ms": _percentile(seek_ms, 95),
            "history_bytes_peak": timeline.history_bytes,
            "checkpoint_bytes": timeline.checkpoint_bytes,
            "checkpoint_count": timeline.checkpoint_count,
            "canonical_layer_bytes": timeline.canonical_state_bytes,
            "backend_history_limit_bytes": TERRAIN_HISTORY_BYTES,
            "frontend_cache_limit_bytes": FRONTEND_CACHE_BYTES,
            "runtime_hz": runtime_rates,
            "relaxation": {
                "accepted_deposit_events": len(relaxation_passes),
                "passes_p95": _percentile(relaxation_passes, 95),
                "passes_max": max(relaxation_passes),
                "touched_cells_p95": _percentile(relaxation_touched_cells, 95),
                "touched_cells_max": max(relaxation_touched_cells),
                "cell_visits_p95": _percentile(relaxation_cell_visits, 95),
                "cell_visits_max": max(relaxation_cell_visits),
                "bucket_residual_m3_max": max(relaxation_bucket_residual_m3),
            },
            "browser": {
                "visible_state_hz": browser_metrics.get("websocketStateHz"),
                "render_fps_p05": browser_metrics.get("renderFpsP05"),
                "input_latency_ms_p95": browser_metrics.get("latencyMsP95"),
                "terrain_visible_edit_hz": browser_metrics.get("terrainVisibleEditHz"),
                "terrain_patch_to_visible_ms_p95": browser_metrics.get(
                    "terrainPatchToVisibleMsP95"
                ),
            },
        },
        "gates": gates,
        "pass": all(gates.values()),
    }
    output = args.output if args.output.is_absolute() else ROOT / args.output
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(
        "Terrain benchmark: "
        f"{edit_input_hz:.2f} edit inputs/s, {p95_snapshot_ms:.2f} ms snapshot P95, "
        f"runtime {edit_runtime_hz:.2f}/{snapshot_runtime_hz:.2f}/{seek_runtime_hz:.2f} Hz."
    )
    return 0 if report["pass"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
