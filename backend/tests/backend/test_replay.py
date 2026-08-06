from __future__ import annotations

import time

import numpy as np
import pytest

from babylon_sim.calibration import MachineCalibration
from babylon_sim.model import ExcavatorModel
from babylon_sim.replay import ReplayCommandError
from babylon_sim.replay_contract import PlaybackState, SourceMode
from babylon_sim.runtime import RuntimeController


def _wait_for(predicate: object, timeout: float = 1.0) -> None:
    callback = predicate
    deadline = time.perf_counter() + timeout
    while time.perf_counter() < deadline:
        if callable(callback) and callback():
            return
        time.sleep(0.005)
    raise AssertionError("condition was not reached before timeout")


def test_playback_pause_freezes_view_while_live_recording_continues(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    runtime.start()
    try:
        _wait_for(lambda: runtime.recording.snapshot().sample_count >= 8)
        before = runtime.recording.snapshot()
        paused = runtime.replay.submit("pause", before.recording_epoch, "pause").result(timeout=1.0)
        paused_view = runtime.replay.latest.read()
        assert paused.playback_state is PlaybackState.PAUSED

        time.sleep(0.08)
        after = runtime.recording.snapshot()
        current_view = runtime.replay.latest.read()
        assert after.sample_count > before.sample_count
        assert current_view.cursor_recording_time_ns == paused_view.cursor_recording_time_ns
        assert current_view.view_revision == paused_view.view_revision
    finally:
        runtime.stop()


def test_seek_uses_independent_fk_and_go_live_restores_following(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    runtime.start()
    try:
        _wait_for(lambda: runtime.recording.snapshot().sample_count >= 8)
        snapshot = runtime.recording.snapshot()
        target = snapshot.chunks[0].recording_time_ns[2]
        applied = runtime.replay.submit(
            "seek",
            snapshot.recording_epoch,
            "seek",
            recording_time_ns=int(target),
        ).result(timeout=1.0)
        view = runtime.replay.latest.read()

        assert applied.source_mode is SourceMode.LIVE
        assert applied.playback_state is PlaybackState.PAUSED
        assert view.selected_sample_sequence == 2
        expected = model.frame_transforms(view.joint_position)
        for frame_name, matrix in expected.items():
            np.testing.assert_allclose(
                view.frame_transforms[frame_name], matrix, atol=1e-9, rtol=0.0
            )

        following = runtime.replay.submit("live", snapshot.recording_epoch, "go_live").result(
            timeout=1.0
        )
        assert following.playback_state is PlaybackState.FOLLOWING
        assert (
            runtime.replay.latest.read().selected_sample_sequence >= view.selected_sample_sequence
        )
    finally:
        runtime.stop()


def test_stale_recording_epoch_is_rejected(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    runtime.start()
    try:
        future = runtime.replay.submit("pause", "obsolete", "pause")
        with pytest.raises(ReplayCommandError) as error:
            future.result(timeout=1.0)
        assert error.value.code == "stale_recording_epoch"
    finally:
        runtime.stop()


def test_latest_seek_slot_supersedes_pending_request(
    model: ExcavatorModel, calibration: MachineCalibration
) -> None:
    runtime = RuntimeController(model, calibration)
    epoch = runtime.recording.recording_epoch
    first = runtime.replay.submit("seek-a", epoch, "seek", recording_time_ns=0)
    second = runtime.replay.submit("seek-b", epoch, "seek", recording_time_ns=0)

    with pytest.raises(ReplayCommandError) as error:
        first.result(timeout=1.0)
    assert error.value.code == "seek_superseded"
    runtime.replay.start()
    try:
        assert second.result(timeout=1.0).id == "seek-b"
    finally:
        runtime.stop()
