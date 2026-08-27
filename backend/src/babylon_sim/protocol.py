"""Versioned JSON boundary for browser and server messages."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass, replace
from functools import lru_cache
from itertools import pairwise
from typing import Any, Literal, TypeAlias, cast

from jsonschema import Draft202012Validator  # type: ignore[import-untyped]

from .input_router import MAX_CLIENT_SEQUENCE
from .paths import PROTOCOL_SCHEMA_PATH, VERSION_MANIFEST_PATH
from .terrain_excavation import MAX_PATCH_BYTES

MAX_MESSAGE_BYTES = 64 * 1024
CLIENT_MESSAGE_TYPES = frozenset(
    {
        "hello",
        "input_snapshot",
        "command",
        "playback_command",
        "terrain_command",
        "bucket_load_feedback",
        "simulation_truth_shadow",
        "sensor_telemetry_batch",
        "ping",
    }
)
SERVER_MESSAGE_TYPES = frozenset(
    {
        "hello_ack",
        "input_ack",
        "command_applied",
        "playback_applied",
        "terrain_applied",
        "terrain_view",
        "terrain_patch",
        "view_state",
        "status",
        "recording_status",
        "error",
        "pong",
    }
)


class ProtocolError(ValueError):
    def __init__(
        self,
        code: str,
        message: str,
        *,
        request_id: str | None = None,
        recoverable: bool = True,
    ) -> None:
        super().__init__(message)
        self.code = code
        self.request_id = request_id
        self.recoverable = recoverable


@dataclass(frozen=True)
class VersionManifest:
    protocol_version: str
    state_schema_version: str
    model_version: str
    calibration_version: str
    software_version: str
    terrain_spec_version: str
    terrain_algorithm_version: str
    visual_model_version: str

    def as_dict(self) -> dict[str, str]:
        return {
            "protocol_version": self.protocol_version,
            "state_schema_version": self.state_schema_version,
            "model_version": self.model_version,
            "calibration_version": self.calibration_version,
            "software_version": self.software_version,
            "terrain_spec_version": self.terrain_spec_version,
            "terrain_algorithm_version": self.terrain_algorithm_version,
            "visual_model_version": self.visual_model_version,
        }

    def for_model(
        self,
        *,
        model_version: str,
        visual_model_version: str,
        calibration_version: str | None = None,
    ) -> VersionManifest:
        return replace(
            self,
            model_version=model_version,
            visual_model_version=visual_model_version,
            calibration_version=calibration_version or self.calibration_version,
        )


@dataclass(frozen=True)
class HelloMessage:
    capabilities: tuple[str, ...]
    requested_model_id: str | None = None
    optional_capabilities: tuple[str, ...] | None = None


@dataclass(frozen=True)
class InputMessage:
    client_sequence: int
    connected: bool
    focused: bool
    operator_axes: tuple[float, float, float, float]
    client_sent_ms: float


@dataclass(frozen=True)
class CommandMessage:
    id: str
    command: Literal["start", "pause", "reset"]


@dataclass(frozen=True)
class PlaybackMessage:
    id: str
    expected_recording_epoch: str
    action: Literal["play", "pause", "seek", "go_live", "return_live"]
    recording_time_ns: int | None


@dataclass(frozen=True)
class TerrainMessage:
    id: str
    expected_recording_epoch: str
    expected_terrain_epoch: str
    action: Literal["apply_preview", "reset_terrain"]
    preview_token: str | None


@dataclass(frozen=True)
class PingMessage:
    id: str
    client_sent_ms: float


@dataclass(frozen=True)
class BucketLoadFeedbackMessage:
    session_id: str
    simulation_epoch: str
    model_id: str
    model_version: str
    world_generation: int
    authority_generation: int
    client_sequence: int
    payload_mass_kg: float
    center_of_mass_local: tuple[float, float, float]
    fill_ratio: float
    resistance: float
    quality: Literal["low", "balanced", "high"]
    client_sent_ms: float


@dataclass(frozen=True)
class SimulationTruthShadowMessage:
    snapshot: dict[str, Any]


@dataclass(frozen=True)
class SensorTelemetryBatchMessage:
    batch: dict[str, Any]


ClientMessage: TypeAlias = (
    HelloMessage
    | InputMessage
    | CommandMessage
    | PlaybackMessage
    | TerrainMessage
    | BucketLoadFeedbackMessage
    | SimulationTruthShadowMessage
    | SensorTelemetryBatchMessage
    | PingMessage
)


@lru_cache(maxsize=1)
def load_schema() -> dict[str, Any]:
    payload = json.loads(PROTOCOL_SCHEMA_PATH.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError("protocol schema root must be an object")
    Draft202012Validator.check_schema(payload)
    return cast(dict[str, Any], payload)


@lru_cache(maxsize=1)
def validator() -> Draft202012Validator:
    return Draft202012Validator(load_schema())


@lru_cache(maxsize=1)
def load_version_manifest() -> VersionManifest:
    payload = json.loads(VERSION_MANIFEST_PATH.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError("version manifest root must be an object")
    required = (
        "protocol_version",
        "state_schema_version",
        "model_version",
        "calibration_version",
        "software_version",
        "terrain_spec_version",
        "terrain_algorithm_version",
        "visual_model_version",
    )
    if set(payload) != set(required) or any(not isinstance(payload[key], str) for key in required):
        raise RuntimeError("version manifest fields do not match the protocol contract")
    manifest = VersionManifest(**{key: payload[key] for key in required})
    errors = sorted(
        validator().iter_errors(_hello_ack_probe(manifest)),
        key=lambda error: list(error.absolute_path),
    )
    if errors:
        raise RuntimeError(f"version manifest does not match schema: {errors[0].message}")
    return manifest


def _hello_ack_probe(manifest: VersionManifest) -> dict[str, object]:
    return {
        "type": "hello_ack",
        "session_id": "manifest-check",
        "simulation_epoch": "manifest-check",
        "recording_epoch": "manifest-check",
        "model_id": "sy205",
        "versions": manifest.as_dict(),
        "model_url": "/api/model",
        "lifecycle": "stopped",
        "capabilities": [],
    }


def _reject_nonfinite(value: object) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise ProtocolError("non_finite_number", "messages may not contain NaN or Infinity")
    if isinstance(value, list):
        for item in value:
            _reject_nonfinite(item)
    elif isinstance(value, dict):
        for item in value.values():
            _reject_nonfinite(item)


def _parse_json(raw: str | bytes, *, max_bytes: int) -> dict[str, Any]:
    encoded = raw.encode("utf-8") if isinstance(raw, str) else raw
    if len(encoded) > max_bytes:
        raise ProtocolError(
            "message_too_large", f"message exceeds {max_bytes} bytes", recoverable=False
        )
    try:
        text = encoded.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ProtocolError(
            "invalid_encoding", "messages must be UTF-8 text", recoverable=False
        ) from exc
    try:
        payload = json.loads(
            text,
            parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)),
        )
    except (json.JSONDecodeError, ValueError) as exc:
        raise ProtocolError("invalid_json", "message is not valid strict JSON") from exc
    if not isinstance(payload, dict):
        raise ProtocolError("invalid_message", "message root must be an object")
    _reject_nonfinite(payload)
    return cast(dict[str, Any], payload)


def decode_client_message(raw: str | bytes, *, max_bytes: int = MAX_MESSAGE_BYTES) -> ClientMessage:
    payload = _parse_json(raw, max_bytes=max_bytes)
    message_type = payload.get("type")
    if message_type not in CLIENT_MESSAGE_TYPES:
        code = "wrong_direction" if message_type in SERVER_MESSAGE_TYPES else "unknown_message_type"
        raise ProtocolError(code, "message type is not accepted from a client")
    errors = sorted(validator().iter_errors(payload), key=lambda error: list(error.absolute_path))
    if errors:
        raise ProtocolError("schema_validation_failed", errors[0].message)

    if message_type == "hello":
        manifest = load_version_manifest()
        if payload["protocol_version"] != manifest.protocol_version:
            raise ProtocolError(
                "incompatible_protocol",
                "client protocol version is incompatible",
                recoverable=False,
            )
        return HelloMessage(
            tuple(cast(list[str], payload["capabilities"])),
            str(payload["requested_model_id"])
            if payload.get("requested_model_id") is not None
            else None,
            tuple(cast(list[str], payload["optional_capabilities"]))
            if "optional_capabilities" in payload
            else None,
        )
    if message_type == "input_snapshot":
        sequence = payload["client_sequence"]
        if (
            isinstance(sequence, bool)
            or not isinstance(sequence, int)
            or sequence > MAX_CLIENT_SEQUENCE
        ):
            raise ProtocolError(
                "invalid_sequence", "client_sequence must be an unsigned 64-bit integer"
            )
        axes_list = cast(list[float], payload["axes"])
        operator_axes = cast(
            tuple[float, float, float, float], tuple(float(value) for value in axes_list)
        )
        return InputMessage(
            client_sequence=sequence,
            connected=payload["connected"],
            focused=payload["focused"],
            operator_axes=operator_axes,
            client_sent_ms=float(payload["client_sent_ms"]),
        )
    if message_type == "command":
        return CommandMessage(payload["id"], payload["command"])
    if message_type == "playback_command":
        return PlaybackMessage(
            payload["id"],
            payload["expected_recording_epoch"],
            payload["action"],
            payload.get("recording_time_ns"),
        )
    if message_type == "terrain_command":
        return TerrainMessage(
            payload["id"],
            payload["expected_recording_epoch"],
            payload["expected_terrain_epoch"],
            payload["action"],
            payload.get("preview_token"),
        )
    if message_type == "bucket_load_feedback":
        center = cast(list[float], payload["center_of_mass_local"])
        return BucketLoadFeedbackMessage(
            session_id=payload["session_id"],
            simulation_epoch=payload["simulation_epoch"],
            model_id=payload["model_id"],
            model_version=payload["model_version"],
            world_generation=payload["world_generation"],
            authority_generation=payload["authority_generation"],
            client_sequence=payload["client_sequence"],
            payload_mass_kg=float(payload["payload_mass_kg"]),
            center_of_mass_local=(float(center[0]), float(center[1]), float(center[2])),
            fill_ratio=float(payload["fill_ratio"]),
            resistance=float(payload["resistance"]),
            quality=payload["quality"],
            client_sent_ms=float(payload["client_sent_ms"]),
        )
    if message_type == "simulation_truth_shadow":
        return SimulationTruthShadowMessage(cast(dict[str, Any], payload["snapshot"]))
    if message_type == "sensor_telemetry_batch":
        return SensorTelemetryBatchMessage(payload)
    return PingMessage(payload["id"], float(payload["client_sent_ms"]))


def encode_server_message(message: dict[str, object]) -> str:
    if message.get("type") not in SERVER_MESSAGE_TYPES:
        raise ProtocolError("wrong_direction", "message type is not accepted from the server")
    _reject_nonfinite(message)
    errors = sorted(validator().iter_errors(message), key=lambda error: list(error.absolute_path))
    if errors:
        raise ProtocolError("server_schema_violation", errors[0].message, recoverable=False)
    if message.get("type") == "terrain_patch":
        base_revision = cast(int, message["base_revision"])
        new_revision = cast(int, message["new_revision"])
        indices = cast(list[int], message["indices"])
        heights = cast(list[float], message["heights_m"])
        if new_revision != base_revision + 1:
            raise ProtocolError(
                "server_schema_violation",
                "terrain patch revisions must be consecutive",
                recoverable=False,
            )
        if len(indices) != len(heights):
            raise ProtocolError(
                "server_schema_violation",
                "terrain patch index and height arrays must align",
                recoverable=False,
            )
        if any(left >= right for left, right in pairwise(indices)):
            raise ProtocolError(
                "server_schema_violation",
                "terrain patch indices must be strictly increasing",
                recoverable=False,
            )
    encoded = json.dumps(message, separators=(",", ":"), allow_nan=False)
    if message.get("type") == "terrain_patch" and len(encoded.encode("utf-8")) > MAX_PATCH_BYTES:
        raise ProtocolError(
            "server_schema_violation",
            "terrain patch exceeds the encoded byte limit",
            recoverable=False,
        )
    return encoded


def error_message(error: ProtocolError) -> dict[str, object]:
    payload: dict[str, object] = {
        "type": "error",
        "code": error.code,
        "message": str(error),
        "recoverable": error.recoverable,
    }
    if error.request_id is not None:
        payload["request_id"] = error.request_id
    return payload
