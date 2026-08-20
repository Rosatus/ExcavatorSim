"""Lifecycle and telemetry gateway for the Godot/Jolt authoritative product."""

from __future__ import annotations

import threading
import time
import uuid
from collections import OrderedDict
from collections.abc import Callable
from concurrent.futures import Future
from typing import Literal

from .constants import DISPLAY_HZ
from .input_router import InputRouter, InputSnapshot
from .model_registry import ModelDescriptor
from .observation_store import ObservationStore
from .protocol import BucketLoadFeedbackMessage, ProtocolError
from .runtime_types import (
    BUCKET_FEEDBACK_CAPABILITY,
    COMMAND_CACHE_CAPACITY,
    CommandResult,
    LifecycleCommand,
    RuntimeCommandError,
    RuntimeStatus,
)
from .sensor_gateway import SENSOR_TELEMETRY_CAPABILITY, SensorTelemetryBatch
from .shadow_state import ShadowTruthSample


class GatewayRuntimeController:
    """No-pose runtime used when Godot/Jolt is the sole simulation writer."""

    profile: Literal["gateway-only"] = "gateway-only"
    publishes_view_state = False
    recording = None
    replay = None
    terrain = None
    exchange = None

    def __init__(
        self,
        descriptor: ModelDescriptor,
        *,
        clock: Callable[[], float] = time.perf_counter,
    ) -> None:
        self.descriptor = descriptor
        self._clock = clock
        self.input_router = InputRouter(clock=clock)
        self._observations = ObservationStore(clock=clock)
        self._stream_epoch = uuid.uuid4().hex
        self._recording_epoch = uuid.uuid4().hex
        self._lifecycle = "stopped"
        self._state_sequence = 0
        self._running = False
        self._started_at = clock()
        self._dropped_snapshots = 0
        self._input_clients: set[str] = set()
        self._command_cache: dict[
            str, OrderedDict[str, tuple[LifecycleCommand, Future[CommandResult]]]
        ] = {}
        self._lock = threading.RLock()

    @property
    def model_id(self) -> str:
        return self.descriptor.model_id

    @property
    def model_version(self) -> str:
        return self.descriptor.model_version

    @property
    def visual_model_version(self) -> str:
        return self.descriptor.visual_model_version

    @property
    def stream_epoch(self) -> str:
        with self._lock:
            return self._stream_epoch

    @property
    def recording_epoch(self) -> str:
        return self._recording_epoch

    @property
    def lifecycle(self) -> str:
        with self._lock:
            return self._lifecycle

    @property
    def capabilities(self) -> frozenset[str]:
        return frozenset(
            {
                "input_snapshot",
                "commands",
                BUCKET_FEEDBACK_CAPABILITY,
                SENSOR_TELEMETRY_CAPABILITY,
            }
        )

    def start(self) -> None:
        with self._lock:
            self._running = True
            self._started_at = self._clock()

    def stop(self) -> None:
        with self._lock:
            self._running = False
            clients = tuple(self._input_clients)
            self._input_clients.clear()
            self._command_cache.clear()
        for client_id in clients:
            self.input_router.disconnect_client(client_id)
        self._observations.clear()

    def is_running(self) -> bool:
        with self._lock:
            return self._running

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
                source=f"godot:{client_id}",
                client_sequence=client_sequence,
                connected=effective_connected,
                axes=effective_axes,
            ),
            client_id=client_id,
        )
        with self._lock:
            self._input_clients.add(client_id)

    def disconnect_client(self, client_id: str) -> None:
        self.input_router.disconnect_client(client_id)
        with self._lock:
            self._input_clients.discard(client_id)
            self._command_cache.pop(client_id, None)
        self._observations.clear_session(client_id)

    def submit_command(
        self, session_id: str, command_id: str, command: LifecycleCommand
    ) -> Future[CommandResult]:
        with self._lock:
            if not self._running:
                raise RuntimeCommandError("server_shutting_down", "server is shutting down")
            cache = self._command_cache.setdefault(session_id, OrderedDict())
            cached = cache.get(command_id)
            if cached is not None:
                cached_command, cached_future = cached
                if cached_command != command:
                    raise RuntimeCommandError(
                        "command_id_conflict",
                        "command id was already used with another payload",
                    )
                cache.move_to_end(command_id)
                return cached_future

            if command == "start":
                self._lifecycle = "running"
            elif command == "pause":
                self._lifecycle = "paused"
            else:
                self._lifecycle = "stopped"
                self._stream_epoch = uuid.uuid4().hex
                self._observations.clear()
            self._state_sequence += 1
            future: Future[CommandResult] = Future()
            future.set_result(
                CommandResult(
                    id=command_id,
                    command=command,
                    lifecycle=self._lifecycle,
                    state_sequence=self._state_sequence,
                )
            )
            cache[command_id] = (command, future)
            while len(cache) > COMMAND_CACHE_CAPACITY:
                cache.popitem(last=False)
            return future

    def submit_bucket_load_feedback(
        self, session_id: str, sample: BucketLoadFeedbackMessage
    ) -> None:
        self._translate_observation_error(
            self._observations.submit_bucket_load_feedback, session_id, sample
        )

    def latest_bucket_load_feedback(self) -> dict[str, object] | None:
        return self._observations.latest_bucket_load_feedback()

    def submit_shadow_truth(self, session_id: str, sample: ShadowTruthSample) -> None:
        self._translate_observation_error(
            self._observations.submit_shadow_truth, session_id, sample
        )

    def latest_shadow_truth(self) -> dict[str, object] | None:
        return self._observations.latest_shadow_truth()

    def submit_sensor_telemetry(self, session_id: str, batch: SensorTelemetryBatch) -> None:
        self._translate_observation_error(
            self._observations.submit_sensor_telemetry, session_id, batch
        )

    def latest_sensor_telemetry(self) -> dict[str, object] | None:
        return self._observations.latest_sensor_telemetry()

    def sensor_telemetry_export(self, limit: int = 64) -> dict[str, object]:
        return self._observations.sensor_telemetry_export(limit)

    def status_snapshot(self) -> RuntimeStatus:
        return RuntimeStatus(
            simulation_hz=0.0,
            state_hz=0.0,
            render_target_hz=float(DISPLAY_HZ),
            overruns=0,
            dropped_snapshots=self._dropped_snapshots,
            controller_source=self.input_router.active_source,
            stale=not self.is_running(),
        )

    def record_dropped_snapshots(self, count: int) -> None:
        if count > 0:
            with self._lock:
                self._dropped_snapshots += count

    @staticmethod
    def _translate_observation_error(callback: Callable[..., None], *args: object) -> None:
        try:
            callback(*args)
        except ProtocolError as exc:
            raise RuntimeCommandError(exc.code, str(exc)) from exc
