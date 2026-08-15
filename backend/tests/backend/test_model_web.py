from __future__ import annotations

import asyncio
from pathlib import Path

import pytest
from aiohttp.test_utils import TestClient, TestServer

from babylon_sim.session_manager import RuntimeSessionManager
from babylon_sim.web import create_app


async def _hello(client: TestClient, model_id: str):
    origin = str(client.make_url("/")).rstrip("/")
    ws = await client.ws_connect("/ws", headers={"Origin": origin})
    await ws.send_json(
        {
            "type": "hello",
            "protocol_version": "godot-pinocchio-v3",
            "capabilities": ["input_snapshot", "commands"],
            "requested_model_id": model_id,
        }
    )
    return ws, await ws.receive_json(timeout=2.0)


@pytest.mark.asyncio
async def test_websocket_switches_runtime_only_between_sessions(tmp_path: Path) -> None:
    frontend = tmp_path / "dist"
    frontend.mkdir()
    (frontend / "index.html").write_text("ok", encoding="utf-8")
    manager = RuntimeSessionManager(model_id="sy205", profile="motion-only")
    client = TestClient(TestServer(create_app(manager, frontend_dir=frontend)))
    await client.start_server()
    try:
        sy135_ws, sy135_ack = await _hello(client, "sy135")
        assert sy135_ack["type"] == "hello_ack"
        assert sy135_ack["model_id"] == "sy135"
        assert sy135_ack["versions"]["model_version"] == "sy135-reference-urdf-v1"
        health = await client.get("/health")
        assert health.status == 200
        assert (await health.json())["model_id"] == "sy135"

        busy_ws, busy_error = await _hello(client, "sy205")
        assert busy_error["type"] == "error"
        assert busy_error["code"] == "model_switch_busy"
        await busy_ws.close()

        await sy135_ws.close()
        for _ in range(20):
            if manager.established_session_count == 0:
                break
            await asyncio.sleep(0.01)
        sy205_ws, sy205_ack = await _hello(client, "sy205")
        assert sy205_ack["type"] == "hello_ack"
        assert sy205_ack["model_id"] == "sy205"
        assert sy205_ack["versions"]["model_version"] == "sy205-glb-urdf-v4"
        await sy205_ws.close()
    finally:
        await client.close()
