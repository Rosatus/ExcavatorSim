from __future__ import annotations

import hashlib
import threading
import time

import pytest

from babylon_sim.constants import MODEL_VERSION
from babylon_sim.recording import ChunkedRecordingBuffer
from babylon_sim.replay_contract import SourceMode
from babylon_sim.state import SimulationState
from babylon_sim.terrain import (
    TERRAIN_ALGORITHM_VERSION,
    TerrainBaseline,
    default_terrain_spec,
)
from babylon_sim.terrain_controller import TerrainCommandError, TerrainController
from babylon_sim.terrain_excavation import (
    TerrainEditInput,
    TerrainHistoryError,
    TerrainTimeline,
)


def _state(sequence: int) -> SimulationState:
    zeros = (0.0, 0.0, 0.0, 0.0)
    return SimulationState(
        timestamp=sequence / 100.0,
        sequence_number=sequence,
        source="terrain-test",
        model_version=MODEL_VERSION,
        calibration_version="machine-calibration-v2",
        joint_position=zeros,
        joint_velocity=zeros,
        joint_acceleration=zeros,
    )


def _recording() -> ChunkedRecordingBuffer:
    recording = ChunkedRecordingBuffer(chunk_samples=2, max_samples=8)
    for sequence in range(3):
        recording.append(
            _state(sequence),
            simulation_epoch="simulation",
            lifecycle="stopped",
            last_input_sequence=None,
            monotonic_ns=100 + sequence,
        )
    return recording


def test_preview_apply_reset_and_static_history_are_identity_safe() -> None:
    recording = _recording()
    controller = TerrainController(recording)
    try:
        epoch = recording.recording_epoch
        initial = controller.view_for(epoch, 0, SourceMode.LIVE)
        slope = {
            **default_terrain_spec(),
            "kind": "slope",
            "angle_deg": 10.0,
            "direction": "north",
        }
        preview = controller.stage_preview(
            "session",
            slope,
            expected_recording_epoch=epoch,
            expected_terrain_epoch=initial.terrain_epoch,
        ).result(timeout=2.0)

        with pytest.raises(TerrainCommandError, match="unavailable"):
            controller.preview("other-session", preview.token)
        with pytest.raises(TerrainCommandError) as stale:
            controller.apply_preview(
                "session",
                "stale",
                preview.token,
                expected_recording_epoch=epoch,
                expected_terrain_epoch="old-terrain",
                selected_sample_sequence=2,
            )
        assert stale.value.code == "stale_terrain_epoch"
        assert controller.view_for(epoch, 2, SourceMode.LIVE).terrain_epoch == initial.terrain_epoch

        applied = controller.apply_preview(
            "session",
            "apply",
            preview.token,
            expected_recording_epoch=epoch,
            expected_terrain_epoch=initial.terrain_epoch,
            selected_sample_sequence=2,
        )
        assert applied.recording_epoch == epoch
        assert recording.recording_epoch == epoch
        assert controller.view_for(epoch, 1, SourceMode.LIVE).terrain_epoch == initial.terrain_epoch
        active = controller.view_for(epoch, 2, SourceMode.LIVE)
        assert active.terrain_epoch == applied.terrain_epoch
        assert active.terrain_algorithm_version == TERRAIN_ALGORITHM_VERSION
        assert active.terrain_revision == 0
        with pytest.raises(TerrainCommandError) as consumed:
            controller.preview("session", preview.token)
        assert consumed.value.code == "invalid_terrain_preview"

        reset = controller.reset(
            "reset",
            expected_recording_epoch=epoch,
            expected_terrain_epoch=active.terrain_epoch,
            selected_sample_sequence=2,
        )
        assert reset.terrain_epoch == active.terrain_epoch
        assert reset.terrain_revision == 1
        reset_view, snapshot = controller.snapshot_for(epoch, reset.terrain_epoch, 1)
        assert reset_view.snapshot_sha256 == active.snapshot_sha256
        assert len(snapshot) == reset_view.rows * reset_view.columns * 4
        assert hashlib.sha256(snapshot).hexdigest() == reset_view.snapshot_sha256
    finally:
        controller.close()


def test_preview_limits_expiry_cleanup_and_imported_read_only() -> None:
    now = [10.0]
    recording = _recording()
    controller = TerrainController(recording, clock=lambda: now[0])
    try:
        epoch = recording.recording_epoch
        terrain_epoch = controller.view_for(epoch, 0, SourceMode.LIVE).terrain_epoch
        previews = [
            controller.stage_preview(
                "session",
                default_terrain_spec(),
                expected_recording_epoch=epoch,
                expected_terrain_epoch=terrain_epoch,
            ).result(timeout=2.0)
            for _ in range(4)
        ]
        with pytest.raises(TerrainCommandError) as limited:
            controller.stage_preview(
                "session",
                default_terrain_spec(),
                expected_recording_epoch=epoch,
                expected_terrain_epoch=terrain_epoch,
            )
        assert limited.value.code == "too_many_terrain_previews"

        assert controller.cancel_preview("session", previews[0].token)
        replacement = controller.stage_preview(
            "session",
            default_terrain_spec(),
            expected_recording_epoch=epoch,
            expected_terrain_epoch=terrain_epoch,
        ).result(timeout=2.0)
        now[0] += 301.0
        with pytest.raises(TerrainCommandError):
            controller.preview("session", replacement.token)

        controller.sync_source(epoch, SourceMode.IMPORTED)
        view = controller.view_for(epoch, 0, SourceMode.IMPORTED)
        assert view.read_only
        with pytest.raises(TerrainCommandError) as read_only:
            controller.stage_preview(
                "session",
                default_terrain_spec(),
                expected_recording_epoch=epoch,
                expected_terrain_epoch=view.terrain_epoch,
            )
        assert read_only.value.code == "terrain_read_only"
    finally:
        controller.close()


def test_pending_preview_work_is_bounded_and_disconnect_cannot_publish(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    recording = _recording()
    controller = TerrainController(recording)
    started = threading.Event()
    release = threading.Event()
    from babylon_sim import terrain_controller as terrain_controller_module

    real_generate = terrain_controller_module.generate_terrain

    def slow_generate(spec: object) -> TerrainBaseline:
        started.set()
        if not release.wait(timeout=2.0):
            raise TimeoutError("test terrain worker was not released")
        return real_generate(spec)

    monkeypatch.setattr(terrain_controller_module, "generate_terrain", slow_generate)
    epoch = recording.recording_epoch
    terrain_epoch = controller.view_for(epoch, 0, SourceMode.LIVE).terrain_epoch
    try:
        first = controller.stage_preview(
            "disconnecting-session",
            default_terrain_spec(),
            expected_recording_epoch=epoch,
            expected_terrain_epoch=terrain_epoch,
        )
        assert started.wait(timeout=1.0)
        controller.cancel_session("disconnecting-session")
        release.set()
        with pytest.raises(TerrainCommandError) as cancelled:
            first.result(timeout=2.0)
        assert cancelled.value.code == "invalid_terrain_preview"

        release.clear()
        futures = [
            controller.stage_preview(
                "bounded-session",
                default_terrain_spec(),
                expected_recording_epoch=epoch,
                expected_terrain_epoch=terrain_epoch,
            )
            for _ in range(4)
        ]
        with pytest.raises(TerrainCommandError) as per_session:
            controller.stage_preview(
                "bounded-session",
                default_terrain_spec(),
                expected_recording_epoch=epoch,
                expected_terrain_epoch=terrain_epoch,
            )
        assert per_session.value.code == "too_many_terrain_previews"
        for index in range(4):
            controller.stage_preview(
                f"other-{index}",
                default_terrain_spec(),
                expected_recording_epoch=epoch,
                expected_terrain_epoch=terrain_epoch,
            )
        with pytest.raises(TerrainCommandError) as global_limit:
            controller.stage_preview(
                "overflow",
                default_terrain_spec(),
                expected_recording_epoch=epoch,
                expected_terrain_epoch=terrain_epoch,
            )
        assert global_limit.value.code == "terrain_worker_busy"
        release.set()
        for future in futures:
            future.result(timeout=2.0)
    finally:
        release.set()
        controller.close()


def test_live_edit_worker_publishes_revision_patch_and_reset_clears_bucket() -> None:
    recording = _recording()
    controller = TerrainController(recording)
    epoch = recording.recording_epoch
    terrain_epoch = controller.view_for(epoch, 0, SourceMode.LIVE).terrain_epoch

    def edit(sample: int, x: float, *, reset_bucket: bool = False) -> TerrainEditInput:
        teeth = ((x, -0.25, -0.1), (x, 0.0, -0.1), (x, 0.25, -0.1))
        return TerrainEditInput(
            recording_epoch=epoch,
            sample_sequence=sample,
            recording_time_ns=sample * 40_000_000,
            stream_epoch="stream",
            previous_teeth=teeth,
            current_teeth=teeth,
            bucket_joint_normalized=0.2,
            reset_bucket=reset_bucket,
        )

    try:
        controller.submit_live_edit(edit(0, -0.5))
        time.sleep(0.05)
        controller.submit_live_edit(edit(4, 0.5))
        deadline = time.monotonic() + 2.0
        view = controller.view_for(epoch, 4, SourceMode.LIVE)
        while view.terrain_revision == 0 and time.monotonic() < deadline:
            time.sleep(0.01)
            view = controller.view_for(epoch, 4, SourceMode.LIVE)
        assert view.terrain_epoch == terrain_epoch
        assert view.terrain_revision == 1
        assert view.bucket_soil_volume_m3 > 0.0
        assert not view.snapshot_required
        patch = controller.patch_for(terrain_epoch, 1)
        assert patch is not None
        assert patch.base_revision == 0
        assert patch.new_revision == 1
        assert tuple(sorted(patch.indices)) == patch.indices
        latest_event = controller.latest_edit_event
        assert latest_event is not None
        assert latest_event.revision == 1
        assert latest_event.relaxation_converged
        assert latest_event.bucket_residual_m3 == view.bucket_soil_volume_m3

        controller.submit_live_edit(edit(8, 0.5, reset_bucket=True))
        controller.submit_live_edit(edit(12, 0.75))
        deadline = time.monotonic() + 2.0
        reset_view = controller.view_for(epoch, 8, SourceMode.LIVE)
        while reset_view.terrain_revision == 1 and time.monotonic() < deadline:
            time.sleep(0.01)
            reset_view = controller.view_for(epoch, 8, SourceMode.LIVE)
        assert reset_view.terrain_revision == 2
        assert reset_view.bucket_soil_volume_m3 == 0.0
        assert reset_view.snapshot_sha256 == view.snapshot_sha256
        assert controller.view_for(epoch, 4, SourceMode.LIVE).bucket_soil_volume_m3 > 0.0
        assert controller.processed_edit_inputs >= 4
        assert controller.edit_fault is None
    finally:
        controller.close()


def test_live_edit_worker_survives_a_typed_history_fault(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    recording = _recording()
    controller = TerrainController(recording)
    epoch = recording.recording_epoch
    real_apply = TerrainTimeline.apply

    def edit(sample: int, x: float) -> TerrainEditInput:
        teeth = ((x, -0.25, -0.1), (x, 0.0, -0.1), (x, 0.25, -0.1))
        return TerrainEditInput(
            recording_epoch=epoch,
            sample_sequence=sample,
            recording_time_ns=sample * 40_000_000,
            stream_epoch="stream",
            previous_teeth=teeth,
            current_teeth=teeth,
            bucket_joint_normalized=0.2,
        )

    def fail_history(self: TerrainTimeline, value: TerrainEditInput) -> None:
        raise TerrainHistoryError("forced test fault")

    try:
        controller.submit_live_edit(edit(0, -0.5))
        deadline = time.monotonic() + 1.0
        while controller.processed_edit_inputs < 1 and time.monotonic() < deadline:
            time.sleep(0.005)
        monkeypatch.setattr(TerrainTimeline, "apply", fail_history)
        controller.submit_live_edit(edit(4, 0.5))
        deadline = time.monotonic() + 1.0
        while controller.edit_fault is None and time.monotonic() < deadline:
            time.sleep(0.005)
        assert controller.edit_fault == "terrain_history_unavailable: forced test fault"

        monkeypatch.setattr(TerrainTimeline, "apply", real_apply)
        controller.submit_live_edit(edit(8, -0.5))
        deadline = time.monotonic() + 1.0
        while controller.processed_edit_inputs < 3 and time.monotonic() < deadline:
            time.sleep(0.005)
        controller.submit_live_edit(edit(12, 0.5))
        deadline = time.monotonic() + 1.0
        view = controller.view_for(epoch, 12, SourceMode.LIVE)
        while view.terrain_revision == 0 and time.monotonic() < deadline:
            time.sleep(0.005)
            view = controller.view_for(epoch, 12, SourceMode.LIVE)
        assert view.terrain_revision == 1
        assert controller.processed_edit_inputs >= 4
    finally:
        controller.close()
