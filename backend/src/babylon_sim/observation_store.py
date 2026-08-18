"""Isolated latest-value observations shared by simulation and gateway runtimes."""

from __future__ import annotations

import threading
import time
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass
from typing import Any, cast

from .protocol import BucketLoadFeedbackMessage, ProtocolError
from .sensor_gateway import (
    SENSOR_TELEMETRY_TIMEOUT_SECONDS,
    LatestSensorTelemetry,
    SensorTelemetryBatch,
    validate_sensor_order,
)
from .shadow_state import (
    SHADOW_TRUTH_TIMEOUT_SECONDS,
    LatestShadowTruth,
    ShadowTruthSample,
    validate_shadow_order,
)

SENSOR_HISTORY_CAPACITY = 256
BUCKET_FEEDBACK_TIMEOUT_SECONDS = 0.5


@dataclass(frozen=True)
class LatestBucketLoadFeedback:
    sample: BucketLoadFeedbackMessage
    received_monotonic_s: float

    def as_dict(self) -> dict[str, object]:
        return {
            "session_id": self.sample.session_id,
            "simulation_epoch": self.sample.simulation_epoch,
            "model_id": self.sample.model_id,
            "model_version": self.sample.model_version,
            "world_generation": self.sample.world_generation,
            "authority_generation": self.sample.authority_generation,
            "client_sequence": self.sample.client_sequence,
            "payload_mass_kg": self.sample.payload_mass_kg,
            "center_of_mass_local": list(self.sample.center_of_mass_local),
            "fill_ratio": self.sample.fill_ratio,
            "resistance": self.sample.resistance,
            "quality": self.sample.quality,
            "client_sent_ms": self.sample.client_sent_ms,
            "received_monotonic_ms": self.received_monotonic_s * 1000.0,
        }


class ObservationStore:
    """Own observational traffic without exposing any product-state mutation path."""

    def __init__(self, *, clock: Callable[[], float] = time.perf_counter) -> None:
        self._clock = clock
        self._bucket_feedback: dict[str, LatestBucketLoadFeedback] = {}
        self._bucket_feedback_lock = threading.Lock()
        self._shadow_truth: dict[str, LatestShadowTruth] = {}
        self._shadow_truth_lock = threading.Lock()
        self._sensor_telemetry: dict[str, LatestSensorTelemetry] = {}
        self._sensor_telemetry_lock = threading.Lock()
        self._sensor_history: dict[str, deque[SensorTelemetryBatch]] = {}

    def clear(self) -> None:
        with self._bucket_feedback_lock:
            self._bucket_feedback.clear()
        with self._shadow_truth_lock:
            self._shadow_truth.clear()
        with self._sensor_telemetry_lock:
            self._sensor_telemetry.clear()
            self._sensor_history.clear()

    def clear_session(self, session_id: str) -> None:
        with self._bucket_feedback_lock:
            self._bucket_feedback.pop(session_id, None)
        with self._shadow_truth_lock:
            self._shadow_truth.pop(session_id, None)
        with self._sensor_telemetry_lock:
            self._sensor_telemetry.pop(session_id, None)
            self._sensor_history.pop(session_id, None)

    def submit_bucket_load_feedback(
        self, session_id: str, sample: BucketLoadFeedbackMessage
    ) -> None:
        now = self._clock()
        with self._bucket_feedback_lock:
            previous = self._bucket_feedback.get(session_id)
            if previous is not None:
                if sample.client_sequence <= previous.sample.client_sequence:
                    raise ProtocolError(
                        "stale_feedback", "bucket feedback sequence must increase"
                    )
                if (
                    sample.authority_generation < previous.sample.authority_generation
                    or sample.world_generation < previous.sample.world_generation
                ):
                    raise ProtocolError(
                        "stale_feedback", "bucket feedback generation moved backwards"
                    )
            self._bucket_feedback[session_id] = LatestBucketLoadFeedback(sample, now)

    def latest_bucket_load_feedback(self) -> dict[str, object] | None:
        now = self._clock()
        with self._bucket_feedback_lock:
            current = max(
                self._bucket_feedback.values(),
                key=lambda value: value.received_monotonic_s,
                default=None,
            )
            if current is None:
                return None
            if now - current.received_monotonic_s > BUCKET_FEEDBACK_TIMEOUT_SECONDS:
                self._bucket_feedback.pop(current.sample.session_id, None)
                return None
            return current.as_dict()

    def submit_shadow_truth(self, session_id: str, sample: ShadowTruthSample) -> None:
        now = self._clock()
        with self._shadow_truth_lock:
            previous = self._shadow_truth.get(session_id)
            if previous is not None:
                validate_shadow_order(previous.sample, sample)
            self._shadow_truth[session_id] = LatestShadowTruth(sample, now)

    def latest_shadow_truth(self) -> dict[str, object] | None:
        now = self._clock()
        with self._shadow_truth_lock:
            current = max(
                self._shadow_truth.values(),
                key=lambda value: value.received_monotonic_s,
                default=None,
            )
            if current is None:
                return None
            if now - current.received_monotonic_s > SHADOW_TRUTH_TIMEOUT_SECONDS:
                self._shadow_truth.pop(current.sample.identity.session_id, None)
                return None
            return current.as_dict(now)

    def submit_sensor_telemetry(self, session_id: str, batch: SensorTelemetryBatch) -> None:
        now = self._clock()
        with self._sensor_telemetry_lock:
            previous = self._sensor_telemetry.get(session_id)
            if previous is not None:
                validate_sensor_order(previous.batch, batch)
                accepted = previous.accepted_batches + 1
                dropped = previous.dropped_batches
            else:
                accepted = 1
                dropped = 0
            self._sensor_telemetry[session_id] = LatestSensorTelemetry(
                batch=batch,
                received_monotonic_s=now,
                accepted_batches=accepted,
                dropped_batches=dropped,
            )
            history = self._sensor_history.setdefault(
                session_id, deque(maxlen=SENSOR_HISTORY_CAPACITY)
            )
            history.append(batch)

    def latest_sensor_telemetry(self) -> dict[str, object] | None:
        now = self._clock()
        with self._sensor_telemetry_lock:
            current = max(
                self._sensor_telemetry.values(),
                key=lambda value: value.received_monotonic_s,
                default=None,
            )
            if current is None:
                return None
            if now - current.received_monotonic_s > SENSOR_TELEMETRY_TIMEOUT_SECONDS:
                self._sensor_telemetry.pop(current.batch.identity.session_id, None)
                return None
            result = current.as_dict(now)
            result["history_count"] = len(
                self._sensor_history.get(current.batch.identity.session_id, ())
            )
            return result

    def sensor_telemetry_export(self, limit: int = 64) -> dict[str, object]:
        bounded_limit = max(1, min(int(limit), SENSOR_HISTORY_CAPACITY))
        with self._sensor_telemetry_lock:
            batches: list[dict[str, object]] = []
            for history in self._sensor_history.values():
                batches.extend(batch.as_dict() for batch in history)
        batches.sort(
            key=lambda batch: (
                int(cast(Any, batch["monotonic_time_ns"])),
                int(cast(Any, batch["batch_sequence"])),
            )
        )
        return {
            "batches": batches[-bounded_limit:],
            "count": min(len(batches), bounded_limit),
            "truncated": len(batches) > bounded_limit,
            "capacity": SENSOR_HISTORY_CAPACITY,
        }
