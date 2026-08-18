"""Strict, observational storage for Godot fixed-tick sensor batches."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from typing import Any, cast

from .protocol import ProtocolError, validator

SENSOR_TELEMETRY_CAPABILITY = "sensor_telemetry_v1"
SENSOR_TELEMETRY_TIMEOUT_SECONDS = 1.0
MAX_SENSOR_BATCHES = 256
_SENSOR_LAYOUTS: dict[str, tuple[int, str]] = {
    "encoder": (3, "rad,rad_s,N"),
    "imu": (15, "rotation_matrix_3x3,rad_s,m_s2"),
    "gnss": (6, "position_m,velocity_m_s"),
    "track_contact": (6, "m_s,m_s,ratio,ratio,count,count"),
    "payload": (4, "kg,m3,ratio,ratio"),
}


@dataclass(frozen=True)
class SensorTelemetryIdentity:
    session_id: str
    simulation_epoch: str
    model_id: str
    model_version: str
    rig_id: str
    rig_version: str
    calibration_version: str


@dataclass(frozen=True)
class SensorTelemetryBatch:
    canonical_json: str
    identity: SensorTelemetryIdentity
    authority_profile: str
    authority_epoch: str
    physics_tick: int
    monotonic_time_ns: int
    batch_sequence: int
    samples: tuple[dict[str, Any], ...]
    gaps: tuple[dict[str, Any], ...]

    def as_dict(self) -> dict[str, Any]:
        return cast(dict[str, Any], json.loads(self.canonical_json))


@dataclass(frozen=True)
class LatestSensorTelemetry:
    batch: SensorTelemetryBatch
    received_monotonic_s: float
    accepted_batches: int
    dropped_batches: int

    def as_dict(self, now: float) -> dict[str, object]:
        return {
            "batch": self.batch.as_dict(),
            "received_monotonic_ms": self.received_monotonic_s * 1000.0,
            "age_ms": max(0.0, now - self.received_monotonic_s) * 1000.0,
            "accepted_batches": self.accepted_batches,
            "dropped_batches": self.dropped_batches,
        }


def decode_sensor_batch(
    batch: dict[str, Any], expected: SensorTelemetryIdentity
) -> SensorTelemetryBatch:
    if batch.get("type") != "sensor_telemetry_batch":
        raise ProtocolError("sensor_schema_validation_failed", "invalid sensor batch type")
    errors = sorted(validator().iter_errors(batch), key=lambda error: list(error.absolute_path))
    if errors:
        raise ProtocolError("sensor_schema_validation_failed", errors[0].message)
    if batch["authority_profile"] != "jolt_authoritative":
        raise ProtocolError(
            "sensor_identity_mismatch", "sensor batches require jolt_authoritative profile"
        )
    actual = SensorTelemetryIdentity(
        session_id=batch["session_id"],
        simulation_epoch=batch["simulation_epoch"],
        model_id=batch["model_id"],
        model_version=batch["model_version"],
        rig_id=batch["rig_id"],
        rig_version=batch["rig_version"],
        calibration_version=batch["calibration_version"],
    )
    if actual != expected:
        raise ProtocolError("sensor_identity_mismatch", "sensor batch identity is not current")
    for sample in cast(list[dict[str, Any]], batch["samples"]):
        expected_layout = _SENSOR_LAYOUTS.get(str(sample["kind"]))
        if expected_layout is None or len(sample["value"]) != expected_layout[0]:
            raise ProtocolError(
                "sensor_layout_invalid", "sensor value length does not match its kind"
            )
        if sample["units"] != expected_layout[1]:
            raise ProtocolError(
                "sensor_units_invalid", "sensor units do not match its kind"
            )
        values = cast(list[float], sample["value"])
        if any(not math.isfinite(float(value)) for value in values):
            raise ProtocolError("sensor_non_finite", "sensor values must be finite")
        if sample["sample_time_ns"] > batch["monotonic_time_ns"]:
            raise ProtocolError("sensor_clock_invalid", "sample time cannot exceed batch time")
    samples = tuple(cast(dict[str, Any], value) for value in batch["samples"])
    stream_sequences: dict[str, int] = {}
    for sample in samples:
        stream = sample["sensor_id"]
        if stream in stream_sequences and sample["sample_sequence"] <= stream_sequences[stream]:
            raise ProtocolError(
                "sensor_duplicate_sequence", "sample sequence must increase within a batch"
            )
        stream_sequences[stream] = sample["sample_sequence"]
    canonical = json.dumps(batch, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return SensorTelemetryBatch(
        canonical_json=canonical,
        identity=actual,
        authority_profile=batch["authority_profile"],
        authority_epoch=batch["authority_epoch"],
        physics_tick=batch["physics_tick"],
        monotonic_time_ns=batch["monotonic_time_ns"],
        batch_sequence=batch["batch_sequence"],
        samples=samples,
        gaps=tuple(cast(dict[str, Any], value) for value in batch["gaps"]),
    )


def validate_sensor_order(
    previous: SensorTelemetryBatch, current: SensorTelemetryBatch
) -> None:
    if previous.identity.simulation_epoch != current.identity.simulation_epoch:
        return
    if previous.authority_epoch != current.authority_epoch:
        raise ProtocolError("stale_sensor_epoch", "sensor authority epoch changed")
    if current.batch_sequence <= previous.batch_sequence:
        raise ProtocolError("stale_sensor_batch", "sensor batch sequence must increase")
    if current.physics_tick <= previous.physics_tick:
        raise ProtocolError("stale_sensor_tick", "sensor physics tick must increase")
    if current.monotonic_time_ns < previous.monotonic_time_ns:
        raise ProtocolError("stale_sensor_clock", "sensor monotonic clock moved backwards")
    previous_streams = {
        sample["sensor_id"]: sample["sample_sequence"] for sample in previous.samples
    }
    for sample in current.samples:
        prior = previous_streams.get(sample["sensor_id"])
        if prior is not None and sample["sample_sequence"] <= prior:
            raise ProtocolError(
                "stale_sensor_sample", "sensor sample sequence must increase per stream"
            )
