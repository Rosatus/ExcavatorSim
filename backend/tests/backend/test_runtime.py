from __future__ import annotations

import queue
import threading
import time
from collections.abc import Callable

import numpy as np
import pytest

from babylon_sim.calibration import MachineCalibration
from babylon_sim.model import ExcavatorModel
from babylon_sim.replay_contract import SourceMode
from babylon_sim.runtime import (
    COMMAND_QUEUE_CAPACITY,
    RuntimeCommandError,
    RuntimeController,
)
from babylon_sim.terrain import TERRAIN_ALGORITHM_VERSION
from babylon_sim.terrain_controller import TerrainView


def _wait_for(predicate: object, timeout: float = 1.0) -> None:
    callback = predicate
    deadline = time.perf_counter() + timeout
    while time.perf_counter() < deadline:
        if callable(callback) and callback():
            return
        time.sleep(0.005)
    raise AssertionError("condition was not reached before timeout")


def _wait_for_stable_terrain(
    view: Callable[[], TerrainView], timeout: float = 2.0, quiet_seconds: float = 0.1
) -> TerrainView:
    current = view()
    fingerprint = (current.terrain_revision, current.snapshot_sha256, current.bucket_soil_volume_m3)
    stable_since = time.perf_counter()
    deadline = stable_since + timeout
    while time.perf_counter() < deadline:
        time.sleep(0.01)
        current = view()
        next_fingerprint = (
            current.terrain_revision,
            current.snapshot_sha256,
            current.bucket_soil_volume_m3,
        )
        if next_fingerprint != fingerprint:
            fingerprint = next_fingerprint
            stable_since = time.perf_counter()
        elif time.perf_counter() - stable_since >= quiet_seconds:
            return current
    raise AssertionError("terrain view did not settle before timeout")


def test_runtime_applies_commands_and_keeps_ticking_while_paused(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    runtime.start()
    try:
        runtime.submit_input(
            "client",
            client_sequence=0,
            connected=True,
            focused=True,
            axes=(0.0, 0.0, 0.0, 0.0),
        )
        runtime.submit_input(
            "client",
            client_sequence=1,
            connected=True,
            focused=True,
            axes=(1.0, 0.0, 0.0, 0.0),
        )
        started = runtime.submit_command("client", "start", "start").result(timeout=1.0)
        assert started.lifecycle == "running"
        _wait_for(lambda: runtime.latest.read().state.joint_position[0] > 0.0)

        paused = runtime.submit_command("client", "pause", "pause").result(timeout=1.0)
        assert paused.lifecycle == "paused"
        paused_position = runtime.latest.read().state.joint_position
        paused_generation = runtime.latest.read().generation
        time.sleep(0.23)
        snapshot = runtime.latest.read()
        assert snapshot.generation > paused_generation
        assert snapshot.lifecycle == "paused"
        assert snapshot.state.joint_position == paused_position
        assert "input_disconnected" in snapshot.state.quality_flags

        epoch = snapshot.stream_epoch
        reset = runtime.submit_command("client", "reset", "reset").result(timeout=1.0)
        assert reset.lifecycle == "stopped"
        assert runtime.latest.read().stream_epoch != epoch
        assert runtime.latest.read().state.sequence_number == 0
        assert "state_reset" in runtime.latest.read().state.quality_flags
    finally:
        runtime.stop()


def test_command_idempotency_conflict_and_queue_bound(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    first = runtime.submit_command("client", "same", "start")
    assert runtime.submit_command("client", "same", "start") is first
    with pytest.raises(RuntimeCommandError) as conflict:
        runtime.submit_command("client", "same", "reset")
    assert conflict.value.code == "command_id_conflict"

    for index in range(COMMAND_QUEUE_CAPACITY - 1):
        runtime.submit_command("client", f"queued-{index}", "reset")
    with pytest.raises(RuntimeCommandError) as full:
        runtime.submit_command("client", "overflow", "reset")
    assert full.value.code == "command_queue_full"
    runtime.stop()


def test_latest_state_slot_is_single_value_and_disconnect_is_safe(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    initial = runtime.latest.read()
    runtime.start()
    try:
        newer = runtime.latest.wait_for_newer(initial.generation, timeout=1.0)
        assert newer.generation > initial.generation
        runtime.disconnect_client("missing")
        runtime.disconnect_client("missing")
    finally:
        runtime.stop()


def test_recording_continues_monotonically_across_simulation_reset(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    runtime.start()
    try:
        _wait_for(lambda: runtime.recording.snapshot().sample_count >= 3)
        before = runtime.recording.snapshot()
        simulation_epoch = runtime.stream_epoch
        runtime.submit_command("client", "reset-recording", "reset").result(timeout=1.0)
        _wait_for(lambda: runtime.recording.snapshot().sample_count > before.sample_count)
        after = runtime.recording.snapshot().materialize()
    finally:
        runtime.stop()

    assert len(after) > before.sample_count
    assert np.all(np.diff(after.recording_time_ns) > 0)
    assert len(after.simulation_epochs) == 2
    assert after.simulation_epochs[0] == simulation_epoch
    assert after.source_sequence[-1] >= 0


def test_simulation_reset_preserves_deformed_terrain_and_clears_bucket(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    runtime.start()
    recording_epoch = runtime.recording.recording_epoch

    def terrain_view() -> TerrainView:
        recording = runtime.recording.snapshot()
        return runtime.terrain.view_for(
            recording_epoch,
            recording.end_sample_sequence,
            SourceMode.LIVE,
        )

    try:
        undeformed = terrain_view()
        runtime.submit_input(
            "terrain-reset",
            client_sequence=0,
            connected=True,
            focused=True,
            axes=(0.0, 0.0, 0.0, 0.0),
        )
        runtime.submit_command("terrain-reset", "start-dig", "start").result(timeout=1.0)
        sequence = 1
        deadline = time.perf_counter() + 5.0
        while terrain_view().bucket_soil_volume_m3 == 0.0 and time.perf_counter() < deadline:
            runtime.submit_input(
                "terrain-reset",
                client_sequence=sequence,
                connected=True,
                focused=True,
                axes=(0.0, 1.0, -1.0, -1.0),
            )
            sequence += 1
            time.sleep(0.04)
        assert terrain_view().bucket_soil_volume_m3 > 0.0
        runtime.submit_input(
            "terrain-reset",
            client_sequence=sequence,
            connected=True,
            focused=True,
            axes=(0.0, 0.0, 0.0, 0.0),
        )
        runtime.submit_command("terrain-reset", "pause-dig", "pause").result(timeout=1.0)
        before = _wait_for_stable_terrain(terrain_view)
        assert before.bucket_soil_volume_m3 > 0.0
        assert before.terrain_revision > undeformed.terrain_revision
        assert before.snapshot_sha256 != undeformed.snapshot_sha256

        runtime.submit_command("terrain-reset", "reset-terrain-bucket", "reset").result(timeout=1.0)
        _wait_for(lambda: terrain_view().bucket_soil_volume_m3 == 0.0)
        after = terrain_view()

        assert after.terrain_epoch == before.terrain_epoch
        assert after.terrain_algorithm_version == TERRAIN_ALGORITHM_VERSION
        assert after.snapshot_sha256 == before.snapshot_sha256
        assert after.terrain_revision == before.terrain_revision + 1
        assert after.bucket_soil_volume_m3 == 0.0
    finally:
        runtime.stop()


def test_batch_command_results_reference_the_published_lifecycle(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    reset = runtime.submit_command("first", "reset", "reset")
    start = runtime.submit_command("second", "start", "start")
    runtime.start()
    try:
        reset_result = reset.result(timeout=1.0)
        start_result = start.result(timeout=1.0)
        snapshot = runtime.latest.read()
        assert reset_result.lifecycle == snapshot.lifecycle == "running"
        assert start_result.lifecycle == snapshot.lifecycle
        assert reset_result.state_sequence == snapshot.state.sequence_number
        assert start_result.state_sequence == snapshot.state.sequence_number
    finally:
        runtime.stop()


def test_shutdown_cannot_leave_a_concurrent_submission_pending(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    entered_put = threading.Event()
    release_put = threading.Event()

    class BlockingQueue(queue.Queue[object]):
        def put_nowait(self, item: object) -> None:
            entered_put.set()
            assert release_put.wait(timeout=1.0)
            super().put_nowait(item)

    runtime._commands = BlockingQueue(COMMAND_QUEUE_CAPACITY)  # type: ignore[assignment]
    submitted: list[object] = []

    def submit() -> None:
        submitted.append(runtime.submit_command("client", "race", "reset"))

    submit_thread = threading.Thread(target=submit)
    stop_thread = threading.Thread(target=runtime.stop)
    submit_thread.start()
    assert entered_put.wait(timeout=1.0)
    stop_thread.start()
    release_put.set()
    submit_thread.join(timeout=1.0)
    stop_thread.join(timeout=1.0)
    assert not submit_thread.is_alive()
    assert not stop_thread.is_alive()
    future = submitted[0]
    with pytest.raises(RuntimeCommandError, match="server is shutting down"):
        future.result(timeout=1.0)  # type: ignore[union-attr]


def test_motion_only_profile_has_no_optional_workers(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration, profile="motion-only")
    assert runtime.recording is None
    assert runtime.terrain is None
    assert runtime.replay is None
    assert runtime.exchange is None
    assert runtime.capabilities == frozenset(
        {
            "input_snapshot",
            "commands",
            "bucket_load_feedback_v1",
            "simulation_truth_shadow_v1",
        }
    )
    runtime.start()
    try:
        first = runtime.latest_view.read()
        assert first.source_mode is SourceMode.LIVE
        assert first.playback_state.value == "following"
        runtime.submit_command("motion", "reset", "reset").result(timeout=1.0)
        second = runtime.latest_view.read()
        assert second.simulation_epoch != first.simulation_epoch
        assert second.view_revision > first.view_revision
        assert len(second.frame_transforms) >= 5
    finally:
        runtime.stop()


def test_motion_only_stop_clears_input_lease_and_command_cache(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration, profile="motion-only")
    runtime.start()
    try:
        runtime.submit_input(
            "client",
            client_sequence=0,
            connected=True,
            focused=True,
            axes=(0.0, 0.0, 0.0, 0.0),
        )
        runtime.submit_input(
            "client",
            client_sequence=1,
            connected=True,
            focused=True,
            axes=(1.0, 0.0, 0.0, 0.0),
        )
        _wait_for(lambda: runtime.input_router.active_source == "browser:client")
        applied = runtime.submit_command("client", "start", "start")
        assert applied.result(timeout=1.0).lifecycle == "running"
        assert "client" in runtime._command_cache
    finally:
        runtime.stop()

    assert runtime.input_router.active_source is None
    assert runtime._command_cache == {}
