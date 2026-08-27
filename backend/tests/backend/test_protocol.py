from __future__ import annotations

import json
from pathlib import Path

import pytest
from jsonschema import Draft202012Validator
from referencing import Registry, Resource

from babylon_sim.paths import PROTOCOL_SCHEMA_PATH
from babylon_sim.protocol import (
    BucketLoadFeedbackMessage,
    CommandMessage,
    HelloMessage,
    InputMessage,
    PlaybackMessage,
    ProtocolError,
    TerrainMessage,
    decode_client_message,
    encode_server_message,
    load_version_manifest,
)


def test_manifest_matches_schema_and_hello_decodes() -> None:
    manifest = load_version_manifest()
    message = decode_client_message(
        json.dumps(
            {
                "type": "hello",
                "protocol_version": manifest.protocol_version,
                "capabilities": ["input_snapshot", "commands", "latency"],
                "requested_model_id": "sy135",
            }
        )
    )
    assert isinstance(message, HelloMessage)
    assert message.capabilities == ("input_snapshot", "commands", "latency")
    assert message.requested_model_id == "sy135"
    assert message.optional_capabilities is None
    assert manifest.protocol_version == "godot-pinocchio-v4"
    schema = json.loads(PROTOCOL_SCHEMA_PATH.read_text(encoding="utf-8"))
    description = schema["$defs"]["AxisVector"]["description"]
    for semantic in ("right rotation", "boom raise", "arm extend", "bucket curl"):
        assert semantic in description


def test_v3_client_cannot_enter_the_v4_input_contract() -> None:
    with pytest.raises(ProtocolError) as rejected:
        decode_client_message(
            json.dumps(
                {
                    "type": "hello",
                    "protocol_version": "godot-pinocchio-v3",
                    "capabilities": ["input_snapshot", "commands"],
                }
            )
        )
    assert rejected.value.code == "schema_validation_failed"


def test_optional_feedback_offer_and_sample_decode_without_changing_required_capabilities() -> None:
    manifest = load_version_manifest()
    hello = decode_client_message(
        json.dumps(
            {
                "type": "hello",
                "protocol_version": manifest.protocol_version,
                "capabilities": ["input_snapshot", "commands"],
                "optional_capabilities": ["bucket_load_feedback_v1"],
            }
        )
    )
    assert isinstance(hello, HelloMessage)
    assert hello.capabilities == ("input_snapshot", "commands")
    assert hello.optional_capabilities == ("bucket_load_feedback_v1",)

    feedback = decode_client_message(
        json.dumps(
            {
                "type": "bucket_load_feedback",
                "protocol_version": manifest.protocol_version,
                "session_id": "session",
                "simulation_epoch": "epoch",
                "model_id": "sy205",
                "model_version": "sy205-glb-urdf-v4",
                "world_generation": 2,
                "authority_generation": 3,
                "client_sequence": 4,
                "payload_mass_kg": 125.0,
                "center_of_mass_local": [0.0, 0.1, -0.2],
                "fill_ratio": 0.5,
                "resistance": 0.25,
                "quality": "balanced",
                "client_sent_ms": 10.0,
            }
        )
    )
    assert isinstance(feedback, BucketLoadFeedbackMessage)
    assert feedback.center_of_mass_local == (0.0, 0.1, -0.2)


def test_legacy_babylon_protocol_identifier_is_rejected() -> None:
    with pytest.raises(ProtocolError) as rejected:
        decode_client_message(
            json.dumps(
                {
                    "type": "hello",
                    "protocol_version": "babylon-sim-v3",
                    "capabilities": ["input_snapshot", "commands"],
                }
            )
        )
    assert rejected.value.code == "schema_validation_failed"


def test_recording_http_schema_is_valid_draft_2020_12() -> None:
    root = Path(__file__).resolve().parents[3]
    schema = json.loads(
        (root / "protocol/recording-http-v1.schema.json").read_text(encoding="utf-8")
    )
    Draft202012Validator.check_schema(schema)
    Draft202012Validator(schema).validate(
        {
            "token": "staged-token",
            "expected_recording_epoch": "recording-epoch",
        }
    )


def test_terrain_http_and_spec_schemas_are_valid_and_linked() -> None:
    root = Path(__file__).resolve().parents[3]
    spec = json.loads((root / "protocol/terrain-spec-v1.schema.json").read_text(encoding="utf-8"))
    http = json.loads((root / "protocol/terrain-http-v1.schema.json").read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(spec)
    Draft202012Validator.check_schema(http)
    registry = Registry().with_resource(spec["$id"], Resource.from_contents(spec))
    Draft202012Validator(http, registry=registry).validate(
        {
            "expected_recording_epoch": "recording",
            "expected_terrain_epoch": "terrain",
            "spec": {
                "terrain_spec_version": "terrain-spec-v1",
                "kind": "flat",
                "width_m": 20,
                "depth_m": 20,
                "spacing_m": 0.25,
                "elevation_m": 0,
                "seed": 0,
                "noise_amplitude_m": 0,
                "noise_scale_m": 4,
            },
        }
    )


def test_input_and_command_decode_to_typed_messages() -> None:
    input_message = decode_client_message(
        json.dumps(
            {
                "type": "input_snapshot",
                "client_sequence": 7,
                "connected": True,
                "focused": True,
                "axes": [1.0, -1.0, 0.0, 0.5],
                "client_sent_ms": 12.5,
            }
        )
    )
    assert isinstance(input_message, InputMessage)
    assert input_message.operator_axes == (1.0, -1.0, 0.0, 0.5)
    command = decode_client_message('{"type":"command","id":"start-1","command":"start"}')
    assert command == CommandMessage("start-1", "start")
    playback = decode_client_message(
        '{"type":"playback_command","id":"seek-1",'
        '"expected_recording_epoch":"epoch","action":"seek","recording_time_ns":42}'
    )
    assert playback == PlaybackMessage("seek-1", "epoch", "seek", 42)
    terrain = decode_client_message(
        '{"type":"terrain_command","id":"terrain-1",'
        '"expected_recording_epoch":"recording","expected_terrain_epoch":"terrain",'
        '"action":"apply_preview","preview_token":"preview"}'
    )
    assert terrain == TerrainMessage(
        "terrain-1", "recording", "terrain", "apply_preview", "preview"
    )


@pytest.mark.parametrize(
    ("raw", "code"),
    [
        ('{"type":"view_state"}', "wrong_direction"),
        ('{"type":"unknown"}', "unknown_message_type"),
        ('{"type":"ping","id":"p","client_sent_ms":NaN}', "invalid_json"),
        ('{"type":"command","id":"","command":"start"}', "schema_validation_failed"),
    ],
)
def test_invalid_client_messages_fail_closed(raw: str, code: str) -> None:
    with pytest.raises(ProtocolError) as rejected:
        decode_client_message(raw)
    assert rejected.value.code == code


def test_message_size_and_unsigned_64_bit_sequence_are_enforced() -> None:
    with pytest.raises(ProtocolError, match="exceeds") as oversized:
        decode_client_message("{}" * 100, max_bytes=16)
    assert oversized.value.code == "message_too_large"

    payload = {
        "type": "input_snapshot",
        "client_sequence": 1 << 64,
        "connected": True,
        "focused": True,
        "axes": [0, 0, 0, 0],
        "client_sent_ms": 0,
    }
    with pytest.raises(ProtocolError) as invalid_sequence:
        decode_client_message(json.dumps(payload))
    assert invalid_sequence.value.code == "invalid_sequence"


def test_server_encoder_validates_direction_and_shape() -> None:
    encoded = encode_server_message(
        {
            "type": "pong",
            "id": "p1",
            "client_sent_ms": 1.0,
            "server_monotonic_ms": 2.0,
        }
    )
    assert json.loads(encoded)["type"] == "pong"
    with pytest.raises(ProtocolError) as rejected:
        encode_server_message({"type": "ping", "id": "p", "client_sent_ms": 1.0})
    assert rejected.value.code == "wrong_direction"


def test_terrain_patch_server_message_is_strict_and_bounded() -> None:
    patch = {
        "type": "terrain_patch",
        "recording_epoch": "recording",
        "selected_sample_sequence": 4,
        "terrain_epoch": "terrain",
        "base_revision": 0,
        "new_revision": 1,
        "indices": [4, 5],
        "heights_m": [-0.1, -0.2],
        "dirty_bounds": [1, 1, 1, 2],
        "snapshot_sha256": "a" * 64,
    }
    assert json.loads(encode_server_message(patch)) == patch
    with pytest.raises(ProtocolError) as extra:
        encode_server_message({**patch, "extra": True})
    assert extra.value.code == "server_schema_violation"
    invalid_patches = (
        {**patch, "new_revision": 2},
        {**patch, "indices": [5, 4]},
        {**patch, "heights_m": [-0.1]},
    )
    for invalid in invalid_patches:
        with pytest.raises(ProtocolError) as semantic:
            encode_server_message(invalid)
        assert semantic.value.code == "server_schema_violation"
