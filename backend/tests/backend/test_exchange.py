from __future__ import annotations

import time
from pathlib import Path

import pytest

from babylon_sim.calibration import MachineCalibration
from babylon_sim.model import ExcavatorModel
from babylon_sim.replay_contract import PlaybackState, SourceMode
from babylon_sim.runtime import RuntimeController
from babylon_sim.terrain import TERRAIN_ALGORITHM_VERSION


def _wait_for(predicate: object, timeout: float = 1.0) -> None:
    callback = predicate
    deadline = time.perf_counter() + timeout
    while time.perf_counter() < deadline:
        if callable(callback) and callback():
            return
        time.sleep(0.005)
    raise AssertionError("condition was not reached before timeout")


def _export(runtime: RuntimeController) -> Path:
    return runtime.exchange.begin_export(source_mode=SourceMode.LIVE)


def test_cancelled_import_is_non_mutating(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    runtime.start()
    export_path: Path | None = None
    try:
        _wait_for(lambda: runtime.recording.snapshot().sample_count >= 5)
        before_epoch = runtime.recording.recording_epoch
        export_path = _export(runtime)
        staged_path = runtime.exchange.upload_path()
        staged_path.write_bytes(export_path.read_bytes())
        runtime.exchange.finish_export(export_path)
        export_path = None
        summary = runtime.exchange.stage_import(
            staged_path,
            expected_recording_epoch=before_epoch,
            session_id="session",
        )
        assert runtime.exchange.cancel(summary.token, session_id="session")
        assert runtime.recording.recording_epoch == before_epoch
        assert runtime.replay.latest.read().source_mode is SourceMode.LIVE
        assert not staged_path.exists()
    finally:
        if export_path is not None:
            runtime.exchange.finish_export(export_path)
        runtime.stop()


def test_confirmed_import_replaces_timeline_and_return_live_starts_clean_epoch(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    runtime.start()
    export_path: Path | None = None
    try:
        runtime.submit_input(
            "exchange",
            client_sequence=0,
            connected=True,
            focused=True,
            axes=(0.0, 0.0, 0.0, 0.0),
        )
        runtime.submit_command("exchange", "start-motion", "start").result(timeout=1.0)
        sequence = 1
        deadline = time.perf_counter() + 2.0
        while (
            runtime.latest.read().state.joint_position[0] >= -0.05
            and time.perf_counter() < deadline
        ):
            runtime.submit_input(
                "exchange",
                client_sequence=sequence,
                connected=True,
                focused=True,
                axes=(1.0, 0.0, 0.0, 0.0),
            )
            sequence += 1
            time.sleep(0.04)
        assert runtime.latest.read().state.joint_position[0] < -0.05
        runtime.submit_input(
            "exchange",
            client_sequence=sequence,
            connected=True,
            focused=True,
            axes=(0.0, 0.0, 0.0, 0.0),
        )
        runtime.submit_command("exchange", "pause-motion", "pause").result(timeout=1.0)
        _wait_for(lambda: runtime.recording.snapshot().sample_count >= 6)
        source_epoch = runtime.recording.recording_epoch
        export_path = _export(runtime)
        staged_path = runtime.exchange.upload_path()
        staged_path.write_bytes(export_path.read_bytes())
        runtime.exchange.finish_export(export_path)
        export_path = None
        summary = runtime.exchange.stage_import(
            staged_path,
            expected_recording_epoch=source_epoch,
            session_id="session",
        )
        result = runtime.exchange.commit_import(
            summary.token,
            expected_recording_epoch=source_epoch,
            session_id="session",
        ).result(timeout=1.0)

        assert result.recording_epoch != source_epoch
        assert result.source_mode is SourceMode.IMPORTED
        assert result.playback_state is PlaybackState.PAUSED
        assert result.cursor_recording_time_ns == summary.start_ns
        runtime.terrain.sync_source(result.recording_epoch, result.source_mode)
        imported_terrain = runtime.terrain.view_for(
            result.recording_epoch,
            result.selected_sample_sequence,
            result.source_mode,
        )
        assert imported_terrain.terrain_revision == 0
        assert imported_terrain.terrain_algorithm_version == TERRAIN_ALGORITHM_VERSION
        assert imported_terrain.bucket_soil_volume_m3 == 0.0
        assert imported_terrain.read_only
        imported_count = runtime.recording.snapshot().sample_count
        time.sleep(0.05)
        assert runtime.recording.snapshot().sample_count == imported_count

        runtime.submit_command("exchange", "start-authoritative-motion", "start").result(
            timeout=1.0
        )
        deadline = time.perf_counter() + 3.0
        while (
            runtime.latest.read().state.joint_position[0] <= 0.05
            and time.perf_counter() < deadline
        ):
            sequence += 1
            runtime.submit_input(
                "exchange",
                client_sequence=sequence,
                connected=True,
                focused=True,
                axes=(-1.0, 0.0, 0.0, 0.0),
            )
            time.sleep(0.04)
        sequence += 1
        runtime.submit_input(
            "exchange",
            client_sequence=sequence,
            connected=True,
            focused=True,
            axes=(0.0, 0.0, 0.0, 0.0),
        )
        runtime.submit_command("exchange", "pause-authoritative-motion", "pause").result(
            timeout=1.0
        )
        authoritative_pose = runtime.latest.read().state.joint_position
        assert authoritative_pose[0] > 0.05
        imported_recording = runtime.recording.snapshot().materialize()
        assert all(
            sample[0] < authoritative_pose[0] - 0.02 for sample in imported_recording.joint_position
        )
        assert runtime.recording.snapshot().sample_count == imported_count
        live = runtime.replay.submit("return", result.recording_epoch, "return_live").result(
            timeout=1.0
        )
        assert live.recording_epoch != result.recording_epoch
        assert live.source_mode is SourceMode.LIVE
        assert live.playback_state is PlaybackState.FOLLOWING
        runtime.terrain.sync_source(live.recording_epoch, live.source_mode)
        live_terrain = runtime.terrain.view_for(
            live.recording_epoch,
            live.selected_sample_sequence,
            live.source_mode,
        )
        assert live_terrain.terrain_epoch != imported_terrain.terrain_epoch
        assert live_terrain.terrain_algorithm_version == TERRAIN_ALGORITHM_VERSION
        assert live_terrain.terrain_revision == 0
        assert live_terrain.bucket_soil_volume_m3 == 0.0
        assert not live_terrain.read_only
        assert runtime.recording.snapshot().sample_count >= 1
        fresh_recording = runtime.recording.snapshot().materialize()
        assert tuple(fresh_recording.joint_position[0]) == pytest.approx(authoritative_pose)
    finally:
        if export_path is not None:
            runtime.exchange.finish_export(export_path)
        runtime.stop()


def test_commit_token_is_single_use(model: ExcavatorModel, calibration: MachineCalibration) -> None:
    runtime = RuntimeController(model, calibration)
    runtime.start()
    try:
        export_path = _export(runtime)
        staged_path = runtime.exchange.upload_path()
        staged_path.write_bytes(export_path.read_bytes())
        runtime.exchange.finish_export(export_path)
        epoch = runtime.recording.recording_epoch
        summary = runtime.exchange.stage_import(
            staged_path, expected_recording_epoch=epoch, session_id="session"
        )
        runtime.exchange.commit_import(
            summary.token, expected_recording_epoch=epoch, session_id="session"
        ).result(timeout=1.0)
        with pytest.raises(Exception, match="missing, used, or expired"):
            runtime.exchange.commit_import(
                summary.token, expected_recording_epoch=epoch, session_id="session"
            )
    finally:
        runtime.stop()
