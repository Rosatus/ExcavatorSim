"""Single-writer replay state machine and historical kinematics worker."""

from __future__ import annotations

import queue
import threading
import time
from collections.abc import Callable, Mapping
from concurrent.futures import Future
from dataclasses import dataclass
from typing import TYPE_CHECKING, Literal

from .recording import (
    BufferSnapshot,
    ChunkedRecordingBuffer,
    MaterializedRecording,
    RecordedSample,
)
from .replay_contract import REPLAY_VIEW_HZ, PlaybackState, SourceMode
from .state import Matrix4

if TYPE_CHECKING:
    from .model import ExcavatorModel
    from .runtime import RuntimeSnapshot

ReplayAction = Literal["play", "pause", "seek", "go_live", "return_live"]
REPLAY_COMMAND_CAPACITY = 32


class ReplayCommandError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class AuthoritativeViewState:
    recording_epoch: str
    buffer_generation: int
    end_sample_sequence: int
    view_revision: int
    source_mode: SourceMode
    playback_state: PlaybackState
    cursor_recording_time_ns: int
    retained_start_ns: int
    retained_end_ns: int
    selected_sample_sequence: int
    simulation_epoch: str
    source_sequence: int
    simulation_time_s: float
    lifecycle: str
    joint_position: tuple[float, ...]
    joint_velocity: tuple[float, ...]
    joint_acceleration: tuple[float, ...]
    frame_transforms: Mapping[str, Matrix4]
    quality_flags: tuple[str, ...]
    last_input_sequence: int | None
    server_monotonic_ms: float


@dataclass(frozen=True)
class PlaybackApplied:
    id: str
    action: ReplayAction
    recording_epoch: str
    buffer_generation: int
    view_revision: int
    source_mode: SourceMode
    playback_state: PlaybackState
    cursor_recording_time_ns: int
    retained_start_ns: int
    retained_end_ns: int
    selected_sample_sequence: int


@dataclass(frozen=True)
class _ReplayCommand:
    id: str
    expected_recording_epoch: str
    action: ReplayAction
    recording_time_ns: int | None
    future: Future[PlaybackApplied]


@dataclass(frozen=True)
class _ImportCommand:
    id: str
    expected_recording_epoch: str
    data: MaterializedRecording
    future: Future[PlaybackApplied]


QueuedReplayCommand = _ReplayCommand | _ImportCommand


class LatestViewSlot:
    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._view: AuthoritativeViewState | None = None

    def publish(self, view: AuthoritativeViewState) -> None:
        with self._condition:
            self._view = view
            self._condition.notify_all()

    def read(self) -> AuthoritativeViewState:
        with self._condition:
            if self._view is None:
                raise RuntimeError("replay worker has not published a view")
            return self._view

    def wait_for_newer(self, revision: int, timeout: float | None = None) -> AuthoritativeViewState:
        with self._condition:
            self._condition.wait_for(
                lambda: self._view is not None and self._view.view_revision > revision,
                timeout=timeout,
            )
            if self._view is None:
                raise RuntimeError("replay worker has not published a view")
            return self._view


class ReplayWorker:
    def __init__(
        self,
        recording: ChunkedRecordingBuffer,
        replay_model: ExcavatorModel,
        live_snapshot: Callable[[], RuntimeSnapshot],
        *,
        clock: Callable[[], float] = time.perf_counter,
    ) -> None:
        self.recording = recording
        self.replay_model = replay_model
        self.latest = LatestViewSlot()
        self._live_snapshot = live_snapshot
        self._clock = clock
        self._commands: queue.Queue[QueuedReplayCommand] = queue.Queue(REPLAY_COMMAND_CAPACITY)
        self._seek_lock = threading.Lock()
        self._pending_seek: _ReplayCommand | None = None
        self._stop_event = threading.Event()
        self._wake_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._source_mode = SourceMode.LIVE
        self._playback_state = PlaybackState.FOLLOWING
        self._cursor_ns = 0
        self._view_revision = 0
        self._last_runtime_generation = 0
        self._last_play_clock = self._clock()
        self._publish_live()

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._last_play_clock = self._clock()
        self._thread = threading.Thread(
            target=self._run,
            name="babylon-sim-replay",
            daemon=False,
        )
        self._thread.start()

    def stop(self) -> None:
        self._stop_event.set()
        self._wake_event.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=3.0)
        error = ReplayCommandError("server_shutting_down", "server is shutting down")
        self._fail_pending(error)

    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def submit(
        self,
        request_id: str,
        expected_recording_epoch: str,
        action: ReplayAction,
        *,
        recording_time_ns: int | None = None,
    ) -> Future[PlaybackApplied]:
        if action == "seek" and recording_time_ns is None:
            raise ReplayCommandError("invalid_playback_command", "seek requires recording_time_ns")
        if action != "seek" and recording_time_ns is not None:
            raise ReplayCommandError(
                "invalid_playback_command", "recording_time_ns is only valid for seek"
            )
        if recording_time_ns is not None and recording_time_ns < 0:
            raise ReplayCommandError(
                "invalid_playback_command", "recording_time_ns must be non-negative"
            )
        if self._stop_event.is_set():
            raise ReplayCommandError("server_shutting_down", "server is shutting down")
        future: Future[PlaybackApplied] = Future()
        command = _ReplayCommand(
            request_id,
            expected_recording_epoch,
            action,
            recording_time_ns,
            future,
        )
        if action == "seek":
            with self._seek_lock:
                superseded = self._pending_seek
                self._pending_seek = command
            if superseded is not None and not superseded.future.done():
                superseded.future.set_exception(
                    ReplayCommandError("seek_superseded", "a newer seek replaced this request")
                )
        else:
            try:
                self._commands.put_nowait(command)
            except queue.Full as exc:
                raise ReplayCommandError(
                    "playback_queue_full", "playback command queue is full"
                ) from exc
        self._wake_event.set()
        return future

    def install_imported(
        self, request_id: str, expected_recording_epoch: str, data: MaterializedRecording
    ) -> Future[PlaybackApplied]:
        future: Future[PlaybackApplied] = Future()
        command = _ImportCommand(request_id, expected_recording_epoch, data, future)
        try:
            self._commands.put_nowait(command)
        except queue.Full as exc:
            raise ReplayCommandError(
                "playback_queue_full", "playback command queue is full"
            ) from exc
        self._wake_event.set()
        return future

    def _run(self) -> None:
        interval = 1.0 / REPLAY_VIEW_HZ
        next_view_at = self._clock()
        while not self._stop_event.is_set():
            self._drain_commands()
            now = self._clock()
            if now >= next_view_at:
                self._advance(now)
                next_view_at += interval
                if next_view_at <= now - interval:
                    next_view_at = now + interval
            timeout = max(0.0, min(interval, next_view_at - self._clock()))
            self._wake_event.wait(timeout)
            self._wake_event.clear()

    def _drain_commands(self) -> None:
        while True:
            try:
                command = self._commands.get_nowait()
            except queue.Empty:
                break
            if isinstance(command, _ImportCommand):
                self._apply_import(command)
            else:
                self._apply(command)
        with self._seek_lock:
            seek = self._pending_seek
            self._pending_seek = None
        if seek is not None:
            self._apply(seek)

    def _apply(self, command: _ReplayCommand) -> None:
        try:
            snapshot = self.recording.snapshot()
            if command.expected_recording_epoch != snapshot.recording_epoch:
                raise ReplayCommandError(
                    "stale_recording_epoch", "recording was replaced before command application"
                )
            if not snapshot.chunks:
                raise ReplayCommandError("recording_empty", "recording has no samples")
            if command.action == "pause":
                self._playback_state = PlaybackState.PAUSED
            elif command.action == "play":
                if self._playback_state is PlaybackState.COMPLETE:
                    raise ReplayCommandError(
                        "playback_complete", "seek before replaying a completed recording"
                    )
                self._playback_state = PlaybackState.PLAYING
                self._last_play_clock = self._clock()
            elif command.action == "seek":
                assert command.recording_time_ns is not None
                self._cursor_ns = self._clip_cursor(snapshot, command.recording_time_ns)
                self._playback_state = PlaybackState.PAUSED
            elif command.action == "go_live":
                if self._source_mode is not SourceMode.LIVE:
                    raise ReplayCommandError(
                        "invalid_source_mode", "go_live is only valid for a Live recording"
                    )
                self._playback_state = PlaybackState.FOLLOWING
            else:
                if self._source_mode is not SourceMode.IMPORTED:
                    raise ReplayCommandError(
                        "invalid_source_mode", "return_live requires an Imported recording"
                    )
                live = self._live_snapshot()
                self.recording.return_to_live(
                    live.state,
                    simulation_epoch=live.stream_epoch,
                    lifecycle=live.lifecycle,
                    last_input_sequence=live.last_input_client_sequence,
                    monotonic_ns=int(live.server_monotonic_ms * 1_000_000.0),
                )
                self._source_mode = SourceMode.LIVE
                self._playback_state = PlaybackState.FOLLOWING

            view = (
                self._publish_live()
                if self._playback_state is PlaybackState.FOLLOWING
                else self._publish_historical(snapshot, self._cursor_ns)
            )
            command.future.set_result(self._applied(command, view))
        except ReplayCommandError as exc:
            command.future.set_exception(exc)
        except Exception as exc:
            command.future.set_exception(
                ReplayCommandError("replay_failed", f"replay command failed: {exc}")
            )

    def _apply_import(self, command: _ImportCommand) -> None:
        try:
            if command.expected_recording_epoch != self.recording.recording_epoch:
                raise ReplayCommandError(
                    "stale_recording_epoch", "recording was replaced before import commit"
                )
            self.recording.install_imported(command.data)
            snapshot = self.recording.snapshot()
            start_ns = snapshot.retained_start_ns
            assert start_ns is not None
            self._source_mode = SourceMode.IMPORTED
            self._playback_state = PlaybackState.PAUSED
            self._cursor_ns = start_ns
            view = self._publish_historical(snapshot, start_ns)
            applied = PlaybackApplied(
                id=command.id,
                action="seek",
                recording_epoch=view.recording_epoch,
                buffer_generation=view.buffer_generation,
                view_revision=view.view_revision,
                source_mode=view.source_mode,
                playback_state=view.playback_state,
                cursor_recording_time_ns=view.cursor_recording_time_ns,
                retained_start_ns=view.retained_start_ns,
                retained_end_ns=view.retained_end_ns,
                selected_sample_sequence=view.selected_sample_sequence,
            )
            command.future.set_result(applied)
        except ReplayCommandError as exc:
            command.future.set_exception(exc)
        except Exception as exc:
            command.future.set_exception(
                ReplayCommandError("import_commit_failed", f"import commit failed: {exc}")
            )

    def _advance(self, now: float) -> None:
        snapshot = self.recording.snapshot()
        if not snapshot.chunks:
            return
        start_ns = snapshot.retained_start_ns
        end_ns = snapshot.retained_end_ns
        assert start_ns is not None and end_ns is not None
        if self._playback_state is PlaybackState.FOLLOWING:
            live = self._live_snapshot()
            if live.generation != self._last_runtime_generation:
                self._publish_live(snapshot, live)
            return
        if self._cursor_ns < start_ns:
            self._cursor_ns = start_ns
            self._publish_historical(snapshot, self._cursor_ns)
        if self._playback_state is not PlaybackState.PLAYING:
            return
        elapsed_ns = max(0, int((now - self._last_play_clock) * 1_000_000_000.0))
        self._last_play_clock = now
        self._cursor_ns = min(end_ns, self._cursor_ns + elapsed_ns)
        if self._cursor_ns >= end_ns:
            if self._source_mode is SourceMode.LIVE:
                self._playback_state = PlaybackState.FOLLOWING
                self._publish_live(snapshot)
            else:
                self._playback_state = PlaybackState.COMPLETE
                self._publish_historical(snapshot, end_ns)
        else:
            self._publish_historical(snapshot, self._cursor_ns)

    def _publish_live(
        self,
        recording_snapshot: BufferSnapshot | None = None,
        live: RuntimeSnapshot | None = None,
    ) -> AuthoritativeViewState:
        recording_snapshot = recording_snapshot or self.recording.snapshot()
        live = live or self._live_snapshot()
        if not recording_snapshot.chunks:
            raise RuntimeError("live recording has no samples")
        sample = recording_snapshot.sample_at_or_before(recording_snapshot.retained_end_ns or 0)
        self._cursor_ns = sample.recording_time_ns
        self._last_runtime_generation = live.generation
        return self._publish(
            recording_snapshot,
            sample,
            live.state.frame_transforms,
            live.state.quality_flags,
            live.server_monotonic_ms,
        )

    def _publish_historical(
        self, snapshot: BufferSnapshot, cursor_ns: int
    ) -> AuthoritativeViewState:
        self._cursor_ns = self._clip_cursor(snapshot, cursor_ns)
        sample = snapshot.sample_at_or_before(self._cursor_ns)
        transforms = self.replay_model.frame_transforms(sample.joint_position)
        return self._publish(
            snapshot,
            sample,
            transforms,
            snapshot.quality_at(sample.sample_sequence),
            self._clock() * 1000.0,
        )

    def _publish(
        self,
        snapshot: BufferSnapshot,
        sample: RecordedSample,
        transforms: Mapping[str, Matrix4],
        quality_flags: tuple[str, ...],
        server_monotonic_ms: float,
    ) -> AuthoritativeViewState:
        start_ns = snapshot.retained_start_ns
        end_ns = snapshot.retained_end_ns
        assert start_ns is not None and end_ns is not None
        self._view_revision += 1
        view = AuthoritativeViewState(
            recording_epoch=snapshot.recording_epoch,
            buffer_generation=snapshot.buffer_generation,
            end_sample_sequence=snapshot.end_sample_sequence,
            view_revision=self._view_revision,
            source_mode=self._source_mode,
            playback_state=self._playback_state,
            cursor_recording_time_ns=sample.recording_time_ns,
            retained_start_ns=start_ns,
            retained_end_ns=end_ns,
            selected_sample_sequence=sample.sample_sequence,
            simulation_epoch=sample.simulation_epoch,
            source_sequence=sample.source_sequence,
            simulation_time_s=sample.simulation_time_s,
            lifecycle=sample.lifecycle,
            joint_position=sample.joint_position,
            joint_velocity=sample.joint_velocity,
            joint_acceleration=sample.joint_acceleration,
            frame_transforms=transforms,
            quality_flags=quality_flags,
            last_input_sequence=sample.last_input_sequence,
            server_monotonic_ms=server_monotonic_ms,
        )
        self.latest.publish(view)
        return view

    @staticmethod
    def _clip_cursor(snapshot: BufferSnapshot, cursor_ns: int) -> int:
        start_ns = snapshot.retained_start_ns
        end_ns = snapshot.retained_end_ns
        assert start_ns is not None and end_ns is not None
        return min(max(cursor_ns, start_ns), end_ns)

    @staticmethod
    def _applied(command: _ReplayCommand, view: AuthoritativeViewState) -> PlaybackApplied:
        return PlaybackApplied(
            id=command.id,
            action=command.action,
            recording_epoch=view.recording_epoch,
            buffer_generation=view.buffer_generation,
            view_revision=view.view_revision,
            source_mode=view.source_mode,
            playback_state=view.playback_state,
            cursor_recording_time_ns=view.cursor_recording_time_ns,
            retained_start_ns=view.retained_start_ns,
            retained_end_ns=view.retained_end_ns,
            selected_sample_sequence=view.selected_sample_sequence,
        )

    def _fail_pending(self, error: ReplayCommandError) -> None:
        while True:
            try:
                command = self._commands.get_nowait()
            except queue.Empty:
                break
            if not command.future.done():
                command.future.set_exception(error)
        with self._seek_lock:
            seek = self._pending_seek
            self._pending_seek = None
        if seek is not None and not seek.future.done():
            seek.future.set_exception(error)
