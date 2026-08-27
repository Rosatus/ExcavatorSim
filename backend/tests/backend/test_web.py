from __future__ import annotations

import asyncio
import json
from pathlib import Path
from typing import Any

import pytest
from aiohttp import ClientWebSocketResponse, WSServerHandshakeError
from aiohttp.test_utils import TestClient, TestServer

from babylon_sim.calibration import MachineCalibration
from babylon_sim.model import ExcavatorModel
from babylon_sim.replay_contract import SourceMode
from babylon_sim.runtime import RuntimeController
from babylon_sim.session_manager import RuntimeSessionManager
from babylon_sim.web import create_app


async def _receive_type(ws: ClientWebSocketResponse, expected: str) -> dict[str, Any]:
    for _ in range(20):
        message = await ws.receive_json(timeout=1.0)
        if message.get("type") == expected:
            return message
    raise AssertionError(f"did not receive message type {expected!r}")


@pytest.mark.asyncio
async def test_motion_only_negotiates_capabilities_and_rejects_optional_routes(
    model: ExcavatorModel, calibration: MachineCalibration, tmp_path: Path
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("<html></html>", encoding="utf-8")
    runtime = RuntimeController(model, calibration, profile="motion-only")
    client = TestClient(TestServer(create_app(runtime, frontend_dir=frontend)))
    await client.start_server()
    try:
        optional_routes = (
            ("get", "/api/recording/series"),
            ("get", "/api/recording/export"),
            ("post", "/api/recording/import/validate"),
            ("post", "/api/recording/import/commit"),
            ("delete", "/api/recording/import/token"),
            ("post", "/api/terrain/preview"),
            ("get", "/api/terrain/preview/token/snapshot"),
            ("delete", "/api/terrain/preview/token"),
            ("get", "/api/terrain/snapshot"),
        )
        for method, path in optional_routes:
            response = await getattr(client, method)(path)
            assert response.status == 409
            assert "capability_unavailable" in await response.text()
        origin = str(client.make_url("/")).rstrip("/")
        ws = await client.ws_connect("/ws", headers={"Origin": origin})
        await ws.send_json(
            {
                "type": "hello",
                "protocol_version": "godot-pinocchio-v4",
                "capabilities": ["input_snapshot", "commands", "playback", "recording", "terrain"],
            }
        )
        hello = await _receive_type(ws, "hello_ack")
        assert hello["capabilities"] == ["commands", "input_snapshot"]
        view = await _receive_type(ws, "view_state")
        assert view["source_mode"] == "live"
        await ws.send_json(
            {
                "type": "playback_command",
                "id": "unsupported",
                "expected_recording_epoch": hello["recording_epoch"],
                "action": "pause",
            }
        )
        error = await _receive_type(ws, "error")
        assert error["code"] == "capability_unavailable"
        assert error["request_id"] == "unsupported"
        await ws.send_json(
            {
                "type": "terrain_command",
                "id": "unsupported-terrain",
                "expected_recording_epoch": hello["recording_epoch"],
                "expected_terrain_epoch": "unused",
                "action": "reset_terrain",
            }
        )
        error = await _receive_type(ws, "error")
        assert error["code"] == "capability_unavailable"
        assert error["request_id"] == "unsupported-terrain"
        await ws.close()
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_gateway_only_handshake_has_no_python_view_state(
    tmp_path: Path,
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("<html></html>", encoding="utf-8")
    manager = RuntimeSessionManager(model_id="sy205", profile="gateway-only")
    client = TestClient(TestServer(create_app(manager, frontend_dir=frontend)))
    await client.start_server()
    try:
        health = await client.get("/health")
        payload = await health.json()
        assert payload["capabilities"] == [
            "bucket_load_feedback_v1",
            "commands",
            "input_snapshot",
            "sensor_telemetry_v1",
        ]
        assert payload["sensor_telemetry"] is None
        assert (await client.get("/api/recording/export")).status == 409
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
        hello = await _receive_type(ws, "hello_ack")
        assert hello["negotiated_optional_capabilities"] == ["sensor_telemetry_v1"]
        with pytest.raises(asyncio.TimeoutError):
            await ws.receive_json(timeout=0.1)
        await ws.close()
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_bucket_feedback_requires_negotiation_and_expires_with_session(
    model: ExcavatorModel, calibration: MachineCalibration, tmp_path: Path
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("<html></html>", encoding="utf-8")
    runtime = RuntimeController(model, calibration, profile="motion-only")
    client = TestClient(TestServer(create_app(runtime, frontend_dir=frontend)))
    await client.start_server()
    try:
        capabilities = await client.get("/api/capabilities")
        assert capabilities.status == 200
        assert (await capabilities.json())["optional_capabilities"] == [
            "bucket_load_feedback_v1",
            "simulation_truth_shadow_v1",
            "sensor_telemetry_v1",
        ]
        origin = str(client.make_url("/")).rstrip("/")
        ws = await client.ws_connect("/ws", headers={"Origin": origin})
        await ws.send_json(
            {
                "type": "hello",
                "protocol_version": "godot-pinocchio-v4",
                "capabilities": ["input_snapshot", "commands"],
                "optional_capabilities": ["bucket_load_feedback_v1"],
            }
        )
        hello = await _receive_type(ws, "hello_ack")
        assert hello["negotiated_optional_capabilities"] == [
            "bucket_load_feedback_v1"
        ]
        feedback = {
            "type": "bucket_load_feedback",
            "protocol_version": "godot-pinocchio-v4",
            "session_id": hello["session_id"],
            "simulation_epoch": hello["simulation_epoch"],
            "model_id": "sy205",
            "model_version": model.model_version,
            "world_generation": 1,
            "authority_generation": 2,
            "client_sequence": 0,
            "payload_mass_kg": 120.0,
            "center_of_mass_local": [0.0, 0.1, -0.2],
            "fill_ratio": 0.4,
            "resistance": 0.2,
            "quality": "balanced",
            "client_sent_ms": 12.0,
        }
        await ws.send_json(feedback)
        await asyncio.sleep(0)
        health = await (await client.get("/health")).json()
        assert health["bucket_load_feedback"]["client_sequence"] == 0
        await ws.send_json(feedback)
        error = await _receive_type(ws, "error")
        assert error["code"] == "stale_feedback"
        await ws.close()
        cleared = False
        for _ in range(20):
            await asyncio.sleep(0.05)
            if (await (await client.get("/health")).json())["bucket_load_feedback"] is None:
                cleared = True
                break
        assert cleared

        unnegotiated = await client.ws_connect("/ws", headers={"Origin": origin})
        await unnegotiated.send_json(
            {
                "type": "hello",
                "protocol_version": "godot-pinocchio-v4",
                "capabilities": ["input_snapshot", "commands"],
            }
        )
        legacy_hello = await _receive_type(unnegotiated, "hello_ack")
        assert "negotiated_optional_capabilities" not in legacy_hello
        feedback["session_id"] = legacy_hello["session_id"]
        feedback["simulation_epoch"] = legacy_hello["simulation_epoch"]
        feedback["client_sequence"] = 1
        await unnegotiated.send_json(feedback)
        error = await _receive_type(unnegotiated, "error")
        assert error["code"] == "capability_unavailable"
        await unnegotiated.close()
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_health_model_and_realtime_round_trip(
    model: ExcavatorModel,
    calibration: MachineCalibration,
    tmp_path: Path,
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("<html>BabylonSim</html>", encoding="utf-8")
    runtime = RuntimeController(model, calibration)
    client = TestClient(TestServer(create_app(runtime, frontend_dir=frontend)))
    await client.start_server()
    try:
        health = await client.get("/health")
        assert health.status == 200
        assert (await health.json())["status"] == "ok"
        model_response = await client.get("/api/model")
        assert model_response.status == 200
        assert 'robot name="sy205_glb_derived_v4"' in await model_response.text()
        visual_model_response = await client.get("/api/visual-model")
        assert visual_model_response.status == 200
        visual_model = await visual_model_response.json()
        assert visual_model["visual_model_version"] == "original-skin-v1"
        assert len(visual_model["entries"]) == 5
        base_asset = await client.get("/api/visual-assets/base")
        assert base_asset.status == 200
        assert base_asset.headers["Content-Type"] == "model/gltf-binary"
        assert base_asset.headers["Cache-Control"] == "public, max-age=31536000, immutable"
        assert (await base_asset.read())[:4] == b"glTF"
        assert (await client.get("/api/visual-assets/unknown")).status == 404
        assert (await client.get("/api/visual-assets/unknown/path")).status == 404
        series_response = await client.get(
            "/api/recording/series",
            params={
                "fields": "joint_position.swing_joint,simulation_time_s",
                "from_ns": "0",
                "to_ns": "999999999999",
                "max_points": "16",
            },
        )
        assert series_response.status == 200
        series = await series_response.json()
        assert series["recording_epoch"] == runtime.recording.recording_epoch
        assert sorted(series["series"]) == [
            "joint_position.swing_joint",
            "simulation_time_s",
        ]

        origin = str(client.make_url("/")).rstrip("/")
        ws = await client.ws_connect("/ws", headers={"Origin": origin})
        await ws.send_json(
            {
                "type": "hello",
                "protocol_version": "godot-pinocchio-v4",
                "capabilities": [
                    "input_snapshot", "commands", "latency", "playback", "recording", "terrain"
                ],
            }
        )
        hello = await _receive_type(ws, "hello_ack")
        assert hello["capabilities"] == [
            "commands",
            "input_snapshot",
            "latency",
            "playback",
            "recording",
            "terrain",
        ]
        assert hello["recording_epoch"] == runtime.recording.recording_epoch
        terrain = await _receive_type(ws, "terrain_view")
        assert terrain["recording_epoch"] == hello["recording_epoch"]
        assert terrain["terrain_revision"] == 0
        assert terrain["rows"] == terrain["columns"] == 81

        terrain_headers = {"X-Godot-Pinocchio-Session": hello["session_id"]}
        preview = await client.post(
            "/api/terrain/preview",
            headers=terrain_headers,
            json={
                "expected_recording_epoch": hello["recording_epoch"],
                "expected_terrain_epoch": terrain["terrain_epoch"],
                "spec": {
                    "terrain_spec_version": "terrain-spec-v1",
                    "kind": "slope",
                    "width_m": 20.0,
                    "depth_m": 20.0,
                    "spacing_m": 0.25,
                    "elevation_m": 0.0,
                    "seed": 0,
                    "noise_amplitude_m": 0.0,
                    "noise_scale_m": 4.0,
                    "angle_deg": 10.0,
                    "direction": "north",
                },
            },
        )
        assert preview.status == 200
        staged = await preview.json()
        preview_snapshot = await client.get(
            f"/api/terrain/preview/{staged['token']}/snapshot", headers=terrain_headers
        )
        assert preview_snapshot.status == 200
        assert preview_snapshot.headers["Content-Type"] == (
            "application/vnd.godot-pinocchio.terrain-f32le"
        )
        assert len(await preview_snapshot.read()) == staged["snapshot_bytes"]
        assert (
            await client.get(
                f"/api/terrain/preview/{staged['token']}/snapshot",
                headers={"X-Godot-Pinocchio-Session": "other-session"},
            )
        ).status == 404

        await ws.send_json(
            {
                "type": "terrain_command",
                "id": "apply-slope",
                "expected_recording_epoch": hello["recording_epoch"],
                "expected_terrain_epoch": terrain["terrain_epoch"],
                "action": "apply_preview",
                "preview_token": staged["token"],
            }
        )
        terrain_applied = await _receive_type(ws, "terrain_applied")
        assert terrain_applied["id"] == "apply-slope"
        assert terrain_applied["recording_epoch"] == hello["recording_epoch"]
        assert terrain_applied["terrain_epoch"] != terrain["terrain_epoch"]
        converged_terrain = await _receive_type(ws, "terrain_view")
        assert converged_terrain["terrain_epoch"] == terrain_applied["terrain_epoch"]
        assert converged_terrain["terrain_revision"] == terrain_applied["terrain_revision"]
        assert converged_terrain["terrain_config_id"] == terrain_applied["terrain_config_id"]
        active_snapshot = await client.get(
            "/api/terrain/snapshot",
            headers=terrain_headers,
            params={
                "recording_epoch": hello["recording_epoch"],
                "terrain_epoch": terrain_applied["terrain_epoch"],
                "terrain_revision": terrain_applied["terrain_revision"],
                "request_id": "snapshot-slope",
            },
        )
        assert active_snapshot.status == 200
        assert active_snapshot.headers["X-Terrain-Epoch"] == terrain_applied["terrain_epoch"]

        await ws.send_json(
            {
                "type": "input_snapshot",
                "client_sequence": 0,
                "connected": True,
                "focused": True,
                "axes": [0, 0, 0, 0],
                "client_sent_ms": 0,
            }
        )
        input_ack = await _receive_type(ws, "input_ack")
        assert input_ack == {"type": "input_ack", "client_sequence": 0, "accepted": True}

        await ws.send_str(json.dumps({"type": "command", "id": "run", "command": "start"}))
        applied = await _receive_type(ws, "command_applied")
        assert applied["id"] == "run"
        assert applied["lifecycle"] == "running"
        state = await _receive_type(ws, "view_state")
        assert state["joint_names"] == [
            "swing_joint",
            "boom_joint",
            "arm_joint",
            "bucket_joint",
        ]
        await ws.send_json(
            {
                "type": "playback_command",
                "id": "seek-start",
                "expected_recording_epoch": hello["recording_epoch"],
                "action": "seek",
                "recording_time_ns": 0,
            }
        )
        playback = await _receive_type(ws, "playback_applied")
        assert playback["id"] == "seek-start"
        assert playback["playback_state"] == "paused"
        await ws.send_str(json.dumps({"type": "command", "id": "run", "command": "reset"}))
        conflict = await _receive_type(ws, "error")
        assert conflict["code"] == "command_id_conflict"
        assert conflict["request_id"] == "run"
        await ws.close()
    finally:
        await client.close()
    assert runtime.is_running() is False


@pytest.mark.asyncio
async def test_series_route_rejects_unknown_fields(
    model: ExcavatorModel, calibration: MachineCalibration, tmp_path: Path
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("ok", encoding="utf-8")
    runtime = RuntimeController(model, calibration)
    client = TestClient(TestServer(create_app(runtime, frontend_dir=frontend)))
    await client.start_server()
    try:
        response = await client.get(
            "/api/recording/series",
            params={
                "fields": "joint_position.bad",
                "from_ns": "0",
                "to_ns": "1",
            },
        )
        assert response.status == 400
        assert "unsupported series field" in await response.text()
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_rrd_http_validate_commit_and_export(
    model: ExcavatorModel, calibration: MachineCalibration, tmp_path: Path
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("ok", encoding="utf-8")
    runtime = RuntimeController(model, calibration)
    client = TestClient(TestServer(create_app(runtime, frontend_dir=frontend)))
    await client.start_server()
    session_headers = {"X-Godot-Pinocchio-Session": "http-session"}
    try:
        epoch = runtime.recording.recording_epoch
        export = await client.get("/api/recording/export", headers=session_headers)
        assert export.status == 200
        rrd_bytes = await export.read()
        assert len(rrd_bytes) > 0

        validate = await client.post(
            "/api/recording/import/validate",
            params={"expected_recording_epoch": epoch},
            headers=session_headers,
            data=rrd_bytes,
        )
        assert validate.status == 200
        summary = await validate.json()
        assert summary["profile"] == "godot-pinocchio/rrd-v1"
        assert summary["sample_count"] >= 1

        commit = await client.post(
            "/api/recording/import/commit",
            headers=session_headers,
            json={
                "token": summary["token"],
                "expected_recording_epoch": epoch,
            },
        )
        assert commit.status == 200
        committed = await commit.json()
        assert committed["source_mode"] == "imported"
        assert committed["playback_state"] == "paused"
        assert runtime.replay.latest.read().source_mode is SourceMode.IMPORTED
        imported_view = runtime.replay.latest.read()
        assert runtime.terrain.view_for(
            imported_view.recording_epoch,
            imported_view.selected_sample_sequence,
            imported_view.source_mode,
        ).read_only
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_websocket_rejects_binary_first_message_with_unsupported_data_close(
    model: ExcavatorModel,
    calibration: MachineCalibration,
    tmp_path: Path,
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("ok", encoding="utf-8")
    runtime = RuntimeController(model, calibration)
    client = TestClient(TestServer(create_app(runtime, frontend_dir=frontend)))
    await client.start_server()
    try:
        origin = str(client.make_url("/")).rstrip("/")
        ws = await client.ws_connect("/ws", headers={"Origin": origin})
        await ws.send_bytes(b"not supported")
        error = await _receive_type(ws, "error")
        assert error["code"] == "binary_not_supported"
        await ws.receive(timeout=1.0)
        assert ws.close_code == 1003
    finally:
        await client.close()


@pytest.mark.asyncio
async def test_websocket_rejects_cross_origin(
    model: ExcavatorModel,
    calibration: MachineCalibration,
    tmp_path: Path,
) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("ok", encoding="utf-8")
    runtime = RuntimeController(model, calibration)
    client = TestClient(TestServer(create_app(runtime, frontend_dir=frontend)))
    await client.start_server()
    try:
        with pytest.raises(WSServerHandshakeError) as rejected:
            await client.ws_connect("/ws", headers={"Origin": "https://example.invalid"})
        assert rejected.value.status == 403
    finally:
        await client.close()
