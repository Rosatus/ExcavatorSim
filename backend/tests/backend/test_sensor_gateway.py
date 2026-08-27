from __future__ import annotations

import json
from dataclasses import replace

import pytest
from aiohttp.test_utils import TestClient, TestServer

from babylon_sim.protocol import ProtocolError, decode_client_message
from babylon_sim.runtime import RuntimeCommandError, RuntimeController
from babylon_sim.sensor_gateway import (
    SensorTelemetryIdentity,
    decode_sensor_batch,
)
from babylon_sim.shadow_state import load_authority_manifest
from babylon_sim.web import create_app


def _batch(identity: SensorTelemetryIdentity, *, batch_sequence: int = 1, tick: int = 1) -> dict:
    return {
        "type": "sensor_telemetry_batch",
        "protocol_version": "godot-pinocchio-v4",
        "session_id": identity.session_id,
        "simulation_epoch": identity.simulation_epoch,
        "model_id": identity.model_id,
        "model_version": identity.model_version,
        "rig_id": identity.rig_id,
        "rig_version": identity.rig_version,
        "calibration_version": identity.calibration_version,
        "authority_profile": "jolt_authoritative",
        "authority_epoch": "authority-1",
        "physics_tick": tick,
        "monotonic_time_ns": tick * 1_000_000,
        "batch_sequence": batch_sequence,
        "source": "godot_fixed_tick",
        "samples": [
            {
                "sensor_id": "encoder/boom_joint",
                "kind": "encoder",
                "frame_id": "boom_joint",
                "sample_sequence": batch_sequence,
                "sample_time_ns": tick * 1_000_000,
                "units": "rad,rad_s,N",
                "coordinate_basis": "canonical-z-up-right-handed-meters",
                "valid": True,
                "quality": "high",
                "value": [0.1, 0.2, 3.0],
                "noise": {
                    "config_version": "simulated-noise-v1",
                    "sigma": [0.0, 0.0, 0.0],
                    "bias": [0.0, 0.0, 0.0],
                },
            }
        ],
        "gaps": [],
    }


def _identity() -> SensorTelemetryIdentity:
    model = load_authority_manifest()["models"]["sy205"]
    return SensorTelemetryIdentity(
        session_id="session",
        simulation_epoch="stream",
        model_id="sy205",
        model_version=model["model_version"],
        rig_id=model["rig_id"],
        rig_version=model["rig_version"],
        calibration_version=model["calibration_version"],
    )


def test_sensor_batch_decodes_with_shared_protocol_schema() -> None:
    identity = _identity()
    raw = json.dumps(_batch(identity))
    message = decode_client_message(raw)
    assert message.batch["source"] == "godot_fixed_tick"  # type: ignore[attr-defined]
    decoded = decode_sensor_batch(message.batch, identity)  # type: ignore[attr-defined]
    assert decoded.samples[0]["sensor_id"] == "encoder/boom_joint"


def test_sensor_batch_rejects_wrong_identity_and_stale_order() -> None:
    identity = _identity()
    first = decode_sensor_batch(_batch(identity), identity)
    second = decode_sensor_batch(_batch(identity, batch_sequence=2, tick=2), identity)
    assert second.batch_sequence > first.batch_sequence
    with pytest.raises(ProtocolError, match="identity"):
        decode_sensor_batch(_batch(identity, batch_sequence=3), replace(identity, model_id="sy135"))


def test_sensor_batch_rejects_kind_layout_mismatch() -> None:
    identity = _identity()
    malformed = _batch(identity)
    malformed["samples"][0]["value"] = [0.1]
    with pytest.raises(ProtocolError, match="length"):
        decode_sensor_batch(malformed, identity)


def test_runtime_sensor_store_rejects_duplicate_batches(
    model, calibration
) -> None:
    identity = _identity()
    runtime = RuntimeController(model, calibration, profile="motion-only")
    try:
        first = decode_sensor_batch(_batch(identity), identity)
        runtime.submit_sensor_telemetry(identity.session_id, first)
        with pytest.raises(RuntimeCommandError, match="sequence"):
            runtime.submit_sensor_telemetry(identity.session_id, first)
        latest = runtime.latest_sensor_telemetry()
        assert latest is not None
        assert latest["batch"]["batch_sequence"] == 1
        exported = runtime.sensor_telemetry_export()
        assert exported["count"] == 1
        assert exported["truncated"] is False
    finally:
        runtime.stop()


def test_sensor_store_expires_latest_but_keeps_bounded_export(
    model, calibration
) -> None:
    now = [10.0]
    runtime = RuntimeController(model, calibration, profile="motion-only", clock=lambda: now[0])
    try:
        identity = _identity()
        batch = decode_sensor_batch(_batch(identity), identity)
        runtime.submit_sensor_telemetry(identity.session_id, batch)
        now[0] += 1.1
        assert runtime.latest_sensor_telemetry() is None
        export = runtime.sensor_telemetry_export()
        assert export["count"] == 1
        assert export["batches"][0]["batch_sequence"] == 1  # type: ignore[index]
    finally:
        runtime.stop()


def test_sensor_store_clears_on_simulation_reset(
    model, calibration
) -> None:
    runtime = RuntimeController(model, calibration, profile="motion-only")
    try:
        identity = _identity()
        batch = decode_sensor_batch(_batch(identity), identity)
        runtime.submit_sensor_telemetry(identity.session_id, batch)
        runtime.start()
        runtime.submit_command("session", "reset-sensor-epoch", "reset").result(timeout=1.0)
        assert runtime.latest_sensor_telemetry() is None
        assert runtime.sensor_telemetry_export()["count"] == 0
    finally:
        runtime.stop()


@pytest.mark.asyncio
async def test_websocket_sensor_batch_is_negotiated_and_exposed(
    model, calibration, tmp_path
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("<html></html>", encoding="utf-8")
    runtime = RuntimeController(model, calibration, profile="motion-only")
    client = TestClient(TestServer(create_app(runtime, frontend_dir=frontend)))
    await client.start_server()
    try:
        origin = str(client.make_url("/")).rstrip("/")
        ws = await client.ws_connect("/ws", headers={"Origin": origin})
        await ws.send_json(
            {
                "type": "hello",
                "protocol_version": "godot-pinocchio-v4",
                "capabilities": ["input_snapshot", "commands"],
                "optional_capabilities": ["sensor_telemetry_v1"],
            }
        )
        hello = await ws.receive_json()
        assert hello["type"] == "hello_ack"
        assert hello["negotiated_optional_capabilities"] == ["sensor_telemetry_v1"]
        identity = replace(
            _identity(),
            session_id=hello["session_id"],
            simulation_epoch=hello["simulation_epoch"],
            model_version=model.model_version,
        )
        await ws.send_json(_batch(identity))
        for _ in range(20):
            if runtime.latest_sensor_telemetry() is not None:
                break
            await ws.receive(timeout=0.05)
        latest = runtime.latest_sensor_telemetry()
        assert latest is not None
        assert latest["batch"]["source"] == "godot_fixed_tick"
        await ws.close()
    finally:
        await client.close()
