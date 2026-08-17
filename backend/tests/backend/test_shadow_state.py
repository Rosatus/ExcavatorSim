from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import pytest
from aiohttp import ClientWebSocketResponse
from aiohttp.test_utils import TestClient, TestServer
from jsonschema import Draft202012Validator

from babylon_sim.calibration import MachineCalibration
from babylon_sim.model import ExcavatorModel
from babylon_sim.paths import PHYSICS_RIG_SCHEMA_PATH, PROJECT_ROOT
from babylon_sim.protocol import ProtocolError, SimulationTruthShadowMessage, decode_client_message
from babylon_sim.runtime import RuntimeController
from babylon_sim.shadow_state import (
    ShadowTruthIdentity,
    decode_shadow_truth,
    validate_shadow_order,
)
from babylon_sim.web import create_app


def _snapshot(
    identity: ShadowTruthIdentity,
    *,
    sequence: int = 1,
    physics_tick: int = 10,
    authority_epoch: str = "authority-a",
) -> dict[str, Any]:
    return {
        "schema_version": "simulation-truth-v1",
        "authority_profile": "jolt_shadow",
        "authority_epoch": authority_epoch,
        "sequence": sequence,
        "physics_tick": physics_tick,
        "monotonic_time_ns": physics_tick * 10_000_000,
        "coordinate_basis": "canonical-z-up-right-handed-meters",
        "identity": {
            **identity.__dict__,
            "terrain_epoch": "terrain-a",
            "terrain_revision": 2,
            "world_generation": 3,
        },
        "gravity_m_s2": [0.0, 0.0, -9.80665],
        "bodies": [
            {
                "name": name,
                "transform": [
                    [1.0, 0.0, 0.0, 1.0],
                    [0.0, 1.0, 0.0, 2.0],
                    [0.0, 0.0, 1.0, 3.0],
                    [0.0, 0.0, 0.0, 1.0],
                ],
                "linear_velocity_m_s": [0.0, 0.0, 0.0],
                "angular_velocity_rad_s": [0.0, 0.0, 0.0],
                "sleeping": False,
            }
            for name in ("chassis", "upper", "boom", "arm", "bucket")
        ],
        "joints": [
            {"name": name, "position_rad": 0.0, "velocity_rad_s": 0.0, "effort_n": 0.0}
            for name in ("swing_joint", "boom_joint", "arm_joint", "bucket_joint")
        ],
        "tracks": {
            "left_command": 0.0,
            "right_command": 0.0,
            "left_speed_m_s": 0.0,
            "right_speed_m_s": 0.0,
            "grounded": True,
            "left_contact_count": 0,
            "right_contact_count": 0,
            "left_slip_ratio": 0.0,
            "right_slip_ratio": 0.0,
            "left_saturated": False,
            "right_saturated": False,
            "terrain_identity_valid": True,
        },
        "payload": {
            "mass_kg": 0.0,
            "volume_m3": 0.0,
            "fill_ratio": 0.0,
            "center_of_mass_m": [0.0, 0.0, 0.0],
        },
        "contacts": [],
        "quality_flags": ["shadow_observation"],
    }


def _identity(
    session_id: str = "session", simulation_epoch: str = "simulation"
) -> ShadowTruthIdentity:
    return ShadowTruthIdentity(
        session_id=session_id,
        simulation_epoch=simulation_epoch,
        model_id="sy205",
        model_version="sy205-glb-urdf-v4",
        rig_id="sy205-jolt-rig",
        rig_version="sy205-jolt-rig-v2",
        calibration_version="machine-calibration-v2",
    )


def test_rig_descriptors_match_strict_schema() -> None:
    schema = json.loads(PHYSICS_RIG_SCHEMA_PATH.read_text(encoding="utf-8"))
    Draft202012Validator.check_schema(schema)
    validator = Draft202012Validator(schema)
    for name in ("sy205", "sy135"):
        descriptor = json.loads(
            (PROJECT_ROOT / f"godot/client/resources/physics/{name}_physics_rig.json").read_text(
                encoding="utf-8"
            )
        )
        validator.validate(descriptor)
        assert len({body["name"] for body in descriptor["bodies"]}) == 5
        assert len({joint["name"] for joint in descriptor["joints"]}) == 4
        invalid_descriptor = json.loads(json.dumps(descriptor))
        invalid_descriptor["bodies"][0]["inertia_diagonal_kg_m2"][0] = 0.0
        assert list(validator.iter_errors(invalid_descriptor))

    identity_fixture = json.loads(
        (
            PROJECT_ROOT / "godot/client/tests/fixtures/simulation_truth_identity_cases.json"
        ).read_text(encoding="utf-8")
    )
    manifest_models = json.loads(
        (PROJECT_ROOT / "protocol/simulation-authority-v1.json").read_text(encoding="utf-8")
    )["models"]
    for identity in identity_fixture["valid"]:
        expected = manifest_models[identity["model_id"]]
        assert all(identity[field] == expected[field] for field in expected)
    for identity in identity_fixture["invalid"]:
        expected = manifest_models[identity["model_id"]]
        assert any(identity[field] != expected[field] for field in expected)


def test_shadow_decoder_is_typed_immutable_and_strictly_ordered() -> None:
    identity = _identity()
    raw = _snapshot(identity)
    envelope = decode_client_message(
        json.dumps(
            {
                "type": "simulation_truth_shadow",
                "protocol_version": "godot-pinocchio-v3",
                "snapshot": raw,
            }
        )
    )
    assert isinstance(envelope, SimulationTruthShadowMessage)
    first = decode_shadow_truth(envelope.snapshot, identity)
    raw["bodies"][0]["transform"][0][3] = 999.0
    assert first.as_dict()["bodies"][0]["transform"][0][3] == 1.0
    second = decode_shadow_truth(_snapshot(identity, sequence=2, physics_tick=11), identity)
    validate_shadow_order(first, second)
    with pytest.raises(ProtocolError, match="must increase"):
        validate_shadow_order(second, first)
    invalid = _snapshot(identity)
    invalid["bodies"][0]["transform"][0][0] = 2.0
    with pytest.raises(ProtocolError, match="normalized"):
        decode_shadow_truth(invalid, identity)
    authoritative = _snapshot(identity)
    authoritative["authority_profile"] = "jolt_authoritative"
    with pytest.raises(ProtocolError, match="shadow transport requires jolt_shadow"):
        decode_shadow_truth(authoritative, identity)
    duplicate_body = _snapshot(identity)
    duplicate_body["bodies"][1]["name"] = "chassis"
    with pytest.raises(ProtocolError, match="five unique named bodies"):
        decode_shadow_truth(duplicate_body, identity)


def test_shadow_terrain_identity_is_monotonic_within_world_generation() -> None:
    identity = _identity()
    first = decode_shadow_truth(_snapshot(identity), identity)
    stale_revision_raw = _snapshot(identity, sequence=2, physics_tick=11)
    stale_revision_raw["identity"]["terrain_revision"] = 1
    with pytest.raises(ProtocolError, match="terrain identity"):
        validate_shadow_order(first, decode_shadow_truth(stale_revision_raw, identity))

    changed_epoch_raw = _snapshot(identity, sequence=2, physics_tick=11)
    changed_epoch_raw["identity"]["terrain_epoch"] = "terrain-b"
    with pytest.raises(ProtocolError, match="terrain identity"):
        validate_shadow_order(first, decode_shadow_truth(changed_epoch_raw, identity))

    next_world_raw = _snapshot(identity, sequence=2, physics_tick=11)
    next_world_raw["identity"].update(
        {"world_generation": 4, "terrain_epoch": "terrain-b", "terrain_revision": 0}
    )
    validate_shadow_order(first, decode_shadow_truth(next_world_raw, identity))


def test_new_simulation_epoch_starts_a_fresh_shadow_order_domain() -> None:
    previous_identity = _identity(simulation_epoch="simulation-a")
    current_identity = _identity(simulation_epoch="simulation-b")
    previous = decode_shadow_truth(
        _snapshot(previous_identity, sequence=20, physics_tick=30), previous_identity
    )
    current = decode_shadow_truth(
        _snapshot(current_identity, sequence=0, physics_tick=0), current_identity
    )
    validate_shadow_order(previous, current)


async def _receive_type(ws: ClientWebSocketResponse, expected: str) -> dict[str, Any]:
    for _ in range(20):
        message = await ws.receive_json(timeout=1.0)
        if message.get("type") == expected:
            return message
    raise AssertionError(f"did not receive {expected}")


@pytest.mark.asyncio
async def test_shadow_transport_is_negotiated_observational_and_cleared(
    model: ExcavatorModel,
    calibration: MachineCalibration,
    tmp_path: Path,
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("<html></html>", encoding="utf-8")
    runtime = RuntimeController(model, calibration, profile="motion-only")
    client = TestClient(TestServer(create_app(runtime, frontend_dir=frontend)))
    await client.start_server()
    try:
        before = runtime.latest.read().state
        origin = str(client.make_url("/")).rstrip("/")
        ws = await client.ws_connect("/ws", headers={"Origin": origin})
        await ws.send_json(
            {
                "type": "hello",
                "protocol_version": "godot-pinocchio-v3",
                "capabilities": ["input_snapshot", "commands"],
                "optional_capabilities": ["simulation_truth_shadow_v1"],
            }
        )
        hello = await _receive_type(ws, "hello_ack")
        assert hello["negotiated_optional_capabilities"] == ["simulation_truth_shadow_v1"]
        identity = _identity(hello["session_id"], hello["simulation_epoch"])
        authoritative = _snapshot(identity)
        authoritative["authority_profile"] = "jolt_authoritative"
        await ws.send_json(
            {
                "type": "simulation_truth_shadow",
                "protocol_version": "godot-pinocchio-v3",
                "snapshot": authoritative,
            }
        )
        error = await _receive_type(ws, "error")
        assert error["code"] == "shadow_schema_validation_failed"
        assert (await (await client.get("/health")).json())["simulation_truth_shadow"] is None
        await ws.send_json(
            {
                "type": "simulation_truth_shadow",
                "protocol_version": "godot-pinocchio-v3",
                "snapshot": _snapshot(identity),
            }
        )
        await asyncio.sleep(0)
        health = await (await client.get("/health")).json()
        assert health["simulation_truth_shadow"]["snapshot"]["physics_tick"] == 10
        after = runtime.latest.read().state
        assert after.joint_position == before.joint_position
        assert after.frame_transforms == before.frame_transforms
        await ws.close()
        for _ in range(20):
            await asyncio.sleep(0.05)
            if (await (await client.get("/health")).json())["simulation_truth_shadow"] is None:
                break
        assert (await (await client.get("/health")).json())["simulation_truth_shadow"] is None
    finally:
        await client.close()
