"""Fixed-rate simulation runtime isolated from network and render cadence."""

from __future__ import annotations

import math
import queue
import threading
import time
import uuid
from collections import OrderedDict
from collections.abc import Callable
from concurrent.futures import Future
from dataclasses import dataclass
from typing import Literal

from .calibration import MachineCalibration
from .constants import DISPLAY_HZ, SIMULATION_DT_SECONDS
from .exchange import RecordingExchange
from .input_router import InputRouter, InputSnapshot
from .model import ExcavatorModel
from .observation_store import ObservationStore
from .protocol import BucketLoadFeedbackMessage, ProtocolError
from .recording import ChunkedRecordingBuffer
from .replay import AuthoritativeViewState, LatestViewSlot, ReplayWorker
from .replay_contract import PlaybackState, SourceMode
from .runtime_types import (
    BUCKET_FEEDBACK_CAPABILITY,
    COMMAND_CACHE_CAPACITY,
    CommandResult,
    LifecycleCommand,
    RuntimeCommandError,
    RuntimeStatus,
)
from .sensor_gateway import SENSOR_TELEMETRY_CAPABILITY, SensorTelemetryBatch
from .shadow_state import SHADOW_TRUTH_CAPABILITY, ShadowTruthSample
from .simulation import SimulationStatus, Simulator
from .state import SimulationState
from .terrain_controller import TerrainController
from .terrain_excavation import (
    TERRAIN_EDIT_STRIDE,
    TerrainEditInput,
    normalized_joint,
    point_from_matrix,
)

SimulationRuntimeProfile = Literal["legacy", "motion-only"]
COMMAND_QUEUE_CAPACITY = 32
COMMANDS_PER_TICK = 8


@dataclass(frozen=True)
class RuntimeSnapshot:
    generation: int
    stream_epoch: str
    lifecycle: str
    state: SimulationState
    last_input_client_sequence: int | None
    server_monotonic_ms: float


@dataclass(frozen=True)
class _QueuedCommand:
    session_id: str
    id: str
    command: LifecycleCommand
    future: Future[CommandResult]


@dataclass
class _CachedCommand:
    command: LifecycleCommand
    future: Future[CommandResult]


class LatestStateSlot:
    def __init__(self) -> None:
        self._condition = threading.Condition()
        self._snapshot: RuntimeSnapshot | None = None

    def publish(self, snapshot: RuntimeSnapshot) -> None:
        with self._condition:
            self._snapshot = snapshot
            self._condition.notify_all()

    def read(self) -> RuntimeSnapshot:
        with self._condition:
            if self._snapshot is None:
                raise RuntimeError("runtime has not published an initial state")
            return self._snapshot

    def wait_for_newer(self, generation: int, timeout: float | None = None) -> RuntimeSnapshot:
        with self._condition:
            self._condition.wait_for(
                lambda: self._snapshot is not None and self._snapshot.generation > generation,
                timeout=timeout,
            )
            if self._snapshot is None:
                raise RuntimeError("runtime has not published an initial state")
            return self._snapshot


class RuntimeController:
    def __init__(
        self,
        model: ExcavatorModel,
        calibration: MachineCalibration,
        *,
        profile: SimulationRuntimeProfile = "legacy",
        clock: Callable[[], float] = time.perf_counter,
    ) -> None:
        if profile not in ("legacy", "motion-only"):
            raise ValueError(f"unknown runtime profile: {profile}")
        self.profile = profile
        self.model = model
        self.calibration = calibration
        self.simulator = Simulator(model, calibration)
        self.input_router = InputRouter(clock=clock)
        self.latest = LatestStateSlot()
        self.recording = ChunkedRecordingBuffer() if profile == "legacy" else None
        self.terrain = TerrainController(self.recording) if self.recording is not None else None
        self._motion_recording_epoch = uuid.uuid4().hex
        self._motion_view = LatestViewSlot()
        self._clock = clock
        self._commands: queue.Queue[_QueuedCommand] = queue.Queue(COMMAND_QUEUE_CAPACITY)
        self._command_cache: dict[str, OrderedDict[str, _CachedCommand]] = {}
        self._cache_lock = threading.Lock()
        self._input_clients: set[str] = set()
        self._input_clients_lock = threading.Lock()
        self._observations = ObservationStore(clock=clock)
        self._submit_lock = threading.Lock()
        self._metrics_lock = threading.Lock()
        self._stop_event = threading.Event()
        self._thread: threading.Thread | None = None
        self._generation = 0
        self._stream_epoch = uuid.uuid4().hex
        self._overruns = 0
        self._dropped_snapshots = 0
        self._ticks = 0
        self._started_at = self._clock()
        self._publish(self.simulator.snapshot())
        self.replay = None
        self.exchange = None
        if self.recording is not None and self.terrain is not None:
            self.replay = ReplayWorker(
                self.recording,
                # Preserve the selected descriptor identity for replay.  Loading
                # the same URDF without its explicit version silently applies
                # the SY205 compatibility default to SY135 recordings.
                ExcavatorModel.from_urdf(
                    model.urdf_path,
                    model_version=model.model_version,
                ),
                self.latest.read,
                clock=clock,
            )
            self.exchange = RecordingExchange(
                self.recording,
                self.replay,
                calibration_version=calibration.calibration_version,
                model_version=model.model_version,
            )

    @property
    def model_id(self) -> str:
        """Compatibility identity; session manager provides the reviewed stable ID."""
        return self.model.model_version

    @property
    def model_version(self) -> str:
        return self.model.model_version

    @property
    def visual_model_version(self) -> str:
        return (
            "original-skin-v1"
            if self.model.model_version == "sy205-glb-urdf-v4"
            else "sy135-combined-glb-v1"
        )

    @property
    def stream_epoch(self) -> str:
        return self._stream_epoch

    @property
    def lifecycle(self) -> str:
        return self.simulator.status.value

    @property
    def publishes_view_state(self) -> bool:
        return True

    @property
    def capabilities(self) -> frozenset[str]:
        if self.profile == "motion-only":
            return frozenset(
                {
                    "input_snapshot",
                    "commands",
                    BUCKET_FEEDBACK_CAPABILITY,
                    SHADOW_TRUTH_CAPABILITY,
                    SENSOR_TELEMETRY_CAPABILITY,
                }
            )
        return frozenset(
            {
                "input_snapshot",
                "commands",
                "latency",
                "playback",
                "recording",
                "terrain",
                BUCKET_FEEDBACK_CAPABILITY,
                SHADOW_TRUTH_CAPABILITY,
                SENSOR_TELEMETRY_CAPABILITY,
            }
        )

    @property
    def latest_view(self) -> LatestViewSlot:
        if self.profile == "motion-only":
            return self._motion_view
        if self.replay is None:
            raise RuntimeError("legacy runtime replay service is unavailable")
        return self.replay.latest

    @property
    def recording_epoch(self) -> str:
        return (
            self._motion_recording_epoch
            if self.recording is None
            else self.recording.recording_epoch
        )

    def start(self) -> None:
        if self._thread is not None and self._thread.is_alive():
            return
        self._stop_event.clear()
        self._started_at = self._clock()
        self._thread = threading.Thread(target=self._run, name="babylon-sim-runtime", daemon=False)
        self._thread.start()
        if self.replay is not None:
            self.replay.start()

    def stop(self) -> None:
        with self._submit_lock:
            self._stop_event.set()
        thread = self._thread
        if thread is not None and thread is not threading.current_thread():
            thread.join(timeout=3.0)
        if self.replay is not None:
            self.replay.stop()
        if self.exchange is not None:
            self.exchange.close()
        if self.terrain is not None:
            self.terrain.close()
        self._fail_pending(RuntimeCommandError("server_shutting_down", "server is shutting down"))
        self._observations.clear()
        if self.profile == "motion-only":
            with self._input_clients_lock:
                input_clients = tuple(self._input_clients)
                self._input_clients.clear()
            for client_id in input_clients:
                self.input_router.disconnect_client(client_id)
            with self._cache_lock:
                self._command_cache.clear()

    def is_running(self) -> bool:
        return self._thread is not None and self._thread.is_alive()

    def submit_input(
        self,
        client_id: str,
        *,
        client_sequence: int,
        connected: bool,
        focused: bool,
        axes: tuple[float, float, float, float],
    ) -> None:
        effective_connected = connected and focused
        effective_axes = axes if effective_connected else (0.0, 0.0, 0.0, 0.0)
        self.input_router.submit(
            InputSnapshot(
                source=f"browser:{client_id}",
                client_sequence=client_sequence,
                connected=effective_connected,
                axes=effective_axes,
            ),
            client_id=client_id,
        )
        with self._input_clients_lock:
            self._input_clients.add(client_id)

    def disconnect_client(self, client_id: str) -> None:
        self.input_router.disconnect_client(client_id)
        with self._input_clients_lock:
            self._input_clients.discard(client_id)
        if self.terrain is not None:
            self.terrain.cancel_session(client_id)
        with self._cache_lock:
            self._command_cache.pop(client_id, None)
        self._observations.clear_session(client_id)

    def submit_bucket_load_feedback(
        self, session_id: str, sample: BucketLoadFeedbackMessage
    ) -> None:
        try:
            self._observations.submit_bucket_load_feedback(session_id, sample)
        except ProtocolError as exc:
            raise RuntimeCommandError(exc.code, str(exc)) from exc

    def latest_bucket_load_feedback(self) -> dict[str, object] | None:
        return self._observations.latest_bucket_load_feedback()

    def submit_shadow_truth(self, session_id: str, sample: ShadowTruthSample) -> None:
        try:
            self._observations.submit_shadow_truth(session_id, sample)
        except ProtocolError as exc:
            raise RuntimeCommandError(exc.code, str(exc)) from exc

    def latest_shadow_truth(self) -> dict[str, object] | None:
        return self._observations.latest_shadow_truth()

    def submit_sensor_telemetry(self, session_id: str, batch: SensorTelemetryBatch) -> None:
        try:
            self._observations.submit_sensor_telemetry(session_id, batch)
        except ProtocolError as exc:
            raise RuntimeCommandError(exc.code, str(exc)) from exc

    def latest_sensor_telemetry(self) -> dict[str, object] | None:
        return self._observations.latest_sensor_telemetry()

    def sensor_telemetry_export(self, limit: int = 64) -> dict[str, object]:
        return self._observations.sensor_telemetry_export(limit)

    def submit_command(
        self, session_id: str, command_id: str, command: LifecycleCommand
    ) -> Future[CommandResult]:
        with self._submit_lock:
            if self._stop_event.is_set():
                raise RuntimeCommandError("server_shutting_down", "server is shutting down")
            with self._cache_lock:
                cache = self._command_cache.setdefault(session_id, OrderedDict())
                cached = cache.get(command_id)
                if cached is not None:
                    if cached.command != command:
                        raise RuntimeCommandError(
                            "command_id_conflict",
                            "command id was already used with another payload",
                        )
                    cache.move_to_end(command_id)
                    return cached.future
                future: Future[CommandResult] = Future()
                cache[command_id] = _CachedCommand(command, future)
                while len(cache) > COMMAND_CACHE_CAPACITY:
                    oldest_id, oldest = next(iter(cache.items()))
                    if not oldest.future.done():
                        break
                    cache.pop(oldest_id)
            queued = _QueuedCommand(session_id, command_id, command, future)
            try:
                self._commands.put_nowait(queued)
            except queue.Full as exc:
                with self._cache_lock:
                    session_cache = self._command_cache.get(session_id)
                    if session_cache is not None:
                        session_cache.pop(command_id, None)
                raise RuntimeCommandError(
                    "command_queue_full", "lifecycle command queue is full"
                ) from exc
            return future

    def status_snapshot(self) -> RuntimeStatus:
        elapsed = max(self._clock() - self._started_at, SIMULATION_DT_SECONDS)
        with self._metrics_lock:
            ticks = self._ticks
            overruns = self._overruns
            dropped = self._dropped_snapshots
        actual_hz = ticks / elapsed
        return RuntimeStatus(
            simulation_hz=actual_hz,
            state_hz=actual_hz,
            render_target_hz=float(DISPLAY_HZ),
            overruns=overruns,
            dropped_snapshots=dropped,
            controller_source=self.input_router.active_source,
            stale=not self.is_running(),
        )

    def record_dropped_snapshots(self, count: int) -> None:
        if count <= 0:
            return
        with self._metrics_lock:
            self._dropped_snapshots += count

    def _run(self) -> None:
        next_deadline = self._clock()
        while not self._stop_event.is_set():
            now = self._clock()
            wait_seconds = next_deadline - now
            if wait_seconds > 0.0:
                time.sleep(wait_seconds)
                if self._stop_event.is_set():
                    break
            tick_started = self._clock()
            self._tick(tick_started)
            with self._metrics_lock:
                self._ticks += 1
            next_deadline += SIMULATION_DT_SECONDS
            finished = self._clock()
            if finished > next_deadline:
                missed = max(1, math.floor((finished - next_deadline) / SIMULATION_DT_SECONDS) + 1)
                with self._metrics_lock:
                    self._overruns += missed
                next_deadline = finished + SIMULATION_DT_SECONDS

    def _tick(self, now: float) -> None:
        command = self.input_router.command(
            timestamp=self.simulator.timestamp,
            sequence_number=self.simulator.sequence_number,
            now=now,
        )
        applied: list[_QueuedCommand] = []
        reset_applied = False
        for _ in range(COMMANDS_PER_TICK):
            try:
                queued = self._commands.get_nowait()
            except queue.Empty:
                break
            try:
                reset_applied = self._apply_command(queued.command) or reset_applied
            except RuntimeError as exc:
                queued.future.set_exception(RuntimeCommandError("invalid_lifecycle", str(exc)))
            else:
                applied.append(queued)

        if self.simulator.status is SimulationStatus.RUNNING:
            state = self.simulator.step(command, dt=SIMULATION_DT_SECONDS)
        elif reset_applied:
            reset_flags = ["state_reset"]
            if not command.connected:
                reset_flags.extend(("input_disconnected", "emergency_stop"))
            state = self.simulator.snapshot(
                source=command.source,
                quality_flags=reset_flags,
            )
        else:
            state = self.simulator.hold(command)
        snapshot = self._publish(state, last_input_client_sequence=command.input_client_sequence)
        for queued in applied:
            queued.future.set_result(
                CommandResult(
                    queued.id,
                    queued.command,
                    snapshot.lifecycle,
                    snapshot.state.sequence_number,
                )
            )

    def _apply_command(self, command: LifecycleCommand) -> bool:
        if command == "start":
            self.simulator.start()
        elif command == "pause":
            self.simulator.pause()
        else:
            self.simulator.reset()
            self._stream_epoch = uuid.uuid4().hex
            # Sensor batches belong to the old authority epoch.  Clear both
            # latest-value and bounded history before publishing the reset
            # snapshot so diagnostics cannot expose cross-epoch samples.
            self._observations.clear()
            return True
        return False

    def _publish(
        self,
        state: SimulationState,
        *,
        last_input_client_sequence: int | None = None,
    ) -> RuntimeSnapshot:
        self._generation += 1
        server_monotonic_ms = self._clock() * 1000.0
        snapshot = RuntimeSnapshot(
            generation=self._generation,
            stream_epoch=self._stream_epoch,
            lifecycle=self.simulator.status.value,
            state=state,
            last_input_client_sequence=last_input_client_sequence,
            server_monotonic_ms=server_monotonic_ms,
        )
        if self.recording is not None and self.terrain is not None:
            sample_sequence = self.recording.append(
                state,
                simulation_epoch=self._stream_epoch,
                lifecycle=self.simulator.status.value,
                last_input_sequence=last_input_client_sequence,
                monotonic_ns=int(server_monotonic_ms * 1_000_000.0),
            )
            reset_bucket = "state_reset" in state.quality_flags
        else:
            sample_sequence = None
            reset_bucket = False
        if (
            self.recording is not None
            and self.terrain is not None
            and sample_sequence is not None
            and (reset_bucket or sample_sequence % TERRAIN_EDIT_STRIDE == 0)
        ):
            teeth = tuple(
                point_from_matrix(state.frame_transforms[name])
                for name in ("tooth_left", "tooth_center", "tooth_right")
            )
            bucket_limit = self.calibration.joint_limits[-1]
            self.terrain.submit_live_edit(
                TerrainEditInput(
                    recording_epoch=self.recording.recording_epoch,
                    sample_sequence=sample_sequence,
                    recording_time_ns=int(server_monotonic_ms * 1_000_000.0),
                    stream_epoch=self._stream_epoch,
                    previous_teeth=teeth,  # type: ignore[arg-type]
                    current_teeth=teeth,  # type: ignore[arg-type]
                    bucket_joint_normalized=normalized_joint(
                        state.joint_position[-1],
                        bucket_limit.min_position,
                        bucket_limit.max_position,
                    ),
                    reset_bucket=reset_bucket,
                )
            )
        self.latest.publish(snapshot)
        if self.profile == "motion-only":
            timestamp_ns = int(server_monotonic_ms * 1_000_000.0)
            self._motion_view.publish(
                AuthoritativeViewState(
                    recording_epoch=self._motion_recording_epoch,
                    buffer_generation=self._generation,
                    end_sample_sequence=self._generation - 1,
                    view_revision=self._generation,
                    source_mode=SourceMode.LIVE,
                    playback_state=PlaybackState.FOLLOWING,
                    cursor_recording_time_ns=timestamp_ns,
                    retained_start_ns=0,
                    retained_end_ns=timestamp_ns,
                    selected_sample_sequence=self._generation - 1,
                    simulation_epoch=snapshot.stream_epoch,
                    source_sequence=state.sequence_number,
                    simulation_time_s=state.timestamp,
                    lifecycle=snapshot.lifecycle,
                    joint_position=state.joint_position,
                    joint_velocity=state.joint_velocity,
                    joint_acceleration=state.joint_acceleration,
                    frame_transforms=state.frame_transforms,
                    quality_flags=state.quality_flags,
                    last_input_sequence=last_input_client_sequence,
                    server_monotonic_ms=server_monotonic_ms,
                )
            )
        return snapshot

    def _fail_pending(self, error: RuntimeCommandError) -> None:
        while True:
            try:
                queued = self._commands.get_nowait()
            except queue.Empty:
                break
            if not queued.future.done():
                queued.future.set_exception(error)


def create_runtime(
    model: ExcavatorModel,
    calibration: MachineCalibration,
    *,
    profile: SimulationRuntimeProfile = "legacy",
) -> RuntimeController:
    return RuntimeController(model, calibration, profile=profile)
