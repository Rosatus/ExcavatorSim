"""Tests for the loopback Gateway Web API boundary."""

from __future__ import annotations

import asyncio
import socket
import sys
import tempfile
import unittest
from pathlib import Path

from aiohttp.test_utils import TestClient, TestServer

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from gateway_runtime import (  # noqa: E402
    GatewayConfigStore,
    GatewayRuntimeCore,
    RuntimeEventLog,
)
from gateway_web import GatewayWebServer  # noqa: E402


def free_port() -> int:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


class GatewayWebApiTest(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.events = RuntimeEventLog(directory=root / "logs", ring_capacity=3)
        self.core = GatewayRuntimeCore(
            mode="godot-managed",
            platform="windows",
            transport_kind="tcp",
            tcp_host="0.0.0.0",
            tcp_port=5678,
            can_interface="can0",
            event_log=self.events,
            config_store=GatewayConfigStore(root / "config.json"),
        )
        self.boundary = GatewayWebServer(self.core, port=free_port())
        self.client = TestClient(TestServer(self.boundary.create_app()))
        await self.client.start_server()

    async def asyncTearDown(self) -> None:
        await self.client.close()
        self.core.close()
        self.tmp.cleanup()

    async def test_status_is_json_and_managed_mode_is_read_only(self) -> None:
        response = await self.client.get("/api/v1/status")
        self.assertEqual(response.status, 200)
        status = (await response.json())["status"]
        self.assertEqual(status["mode"], "godot-managed")
        denied = await self.client.put(
            "/api/v1/transport/tcp",
            json={"host": "127.0.0.1", "port": 6000, "expected_revision": 0},
        )
        self.assertEqual(denied.status, 403)
        self.assertEqual((await denied.json())["error"]["code"], "managed_mode_read_only")
        dbc = await self.client.get("/api/v1/dbc")
        self.assertEqual(dbc.status, 200)
        combined = await dbc.json()
        self.assertFalse(combined["dbc"]["armed"])
        self.assertEqual(combined["status"]["revision"], status["revision"])
        denied_dbc = await self.client.post("/api/v1/dbc/start", json={"expected_revision": 0})
        self.assertEqual(denied_dbc.status, 403)
        self.assertEqual((await denied_dbc.json())["error"]["code"], "managed_mode_read_only")
        denied_preview = await self.client.post(
            "/api/v1/dbc/messages/key/preview",
            json={"expected_revision": 0, "payload_hex": "00"},
        )
        self.assertEqual(denied_preview.status, 403)
        self.assertEqual((await denied_preview.json())["error"]["code"], "managed_mode_read_only")

    async def test_preview_is_allowlisted_and_submitted_to_the_owner(self) -> None:
        self.core.mode = "standalone"
        unknown = await self.client.post(
            "/api/v1/dbc/messages/key/preview",
            json={"expected_revision": 0, "payload_hex": "00", "typo": True},
        )
        self.assertEqual(unknown.status, 400)
        self.assertEqual((await unknown.json())["error"]["code"], "request_field_unknown")
        self.assertEqual(self.core.take_commands(), [])

        async def complete_preview() -> None:
            while True:
                commands = self.core.take_commands()
                if commands:
                    command = commands[0]
                    self.assertEqual(command.kind, "dbc_message_preview")
                    self.assertEqual(command.payload["payload_hex"], "00")
                    self.core.complete(
                        command,
                        {"preview": {"values": {"X": 0.0}, "payload_hex": "00"}},
                    )
                    return
                await asyncio.sleep(0)

        owner = asyncio.create_task(complete_preview())
        response = await self.client.post(
            "/api/v1/dbc/messages/key/preview",
            json={"payload_hex": "00"},
        )
        await owner
        self.assertEqual(response.status, 200)
        self.assertEqual((await response.json())["result"]["preview"]["payload_hex"], "00")
        self.assertEqual(self.core.snapshot().revision, 0)

    async def test_dbc_edit_source_types_are_rejected_before_queue(self) -> None:
        self.core.mode = "standalone"
        cases = (
            ({"values": {}, "payload_hex": "00"}, "dbc_edit_source_conflict"),
            ({"payload_hex": None}, "dbc_payload_invalid"),
            ({"values": []}, "dbc_values_invalid"),
        )
        for body, expected_code in cases:
            with self.subTest(expected_code=expected_code):
                response = await self.client.put(
                    "/api/v1/dbc/messages/key",
                    json={"expected_revision": 0, **body},
                )
                self.assertEqual(response.status, 400)
                self.assertEqual((await response.json())["error"]["code"], expected_code)
                self.assertEqual(self.core.take_commands(), [])

    async def test_strict_json_and_content_type_are_enforced(self) -> None:
        self.core.mode = "standalone"
        wrong = await self.client.put("/api/v1/transport/tcp", data="{}")
        self.assertEqual(wrong.status, 415)
        invalid = await self.client.put(
            "/api/v1/transport/tcp",
            data='{"host":"127.0.0.1","port":NaN,"expected_revision":0}',
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(invalid.status, 400)
        self.assertEqual((await invalid.json())["error"]["code"], "json_invalid")

        oversized = await self.client.put(
            "/api/v1/transport/tcp",
            data=b"{" + b'"padding":"' + b"x" * (64 * 1024) + b'"}',
            headers={"Content-Type": "application/json"},
        )
        self.assertEqual(oversized.status, 413)
        self.assertEqual((await oversized.json())["error"]["code"], "request_too_large")

        bad_revision = await self.client.put(
            "/api/v1/transport/tcp",
            json={"host": "127.0.0.1", "port": 6000, "expected_revision": -1},
        )
        self.assertEqual(bad_revision.status, 400)
        self.assertEqual((await bad_revision.json())["error"]["code"], "revision_invalid")

    async def test_wrong_platform_transport_is_rejected_before_queue(self) -> None:
        self.core.mode = "standalone"
        response = await self.client.post(
            "/api/v1/transport/can0/restart",
            json={"confirm": True, "expected_revision": 0},
        )
        self.assertEqual(response.status, 409)
        self.assertEqual((await response.json())["error"]["code"], "capability_unavailable")
        self.assertEqual(self.core.take_commands(), [])

    async def test_websocket_replays_bounded_events_and_reports_gap(self) -> None:
        for index in range(5):
            self.core.emit_event("state", "test", index=index)
        ws = await self.client.ws_connect("/api/v1/events?after=0")
        try:
            message = await ws.receive_json(timeout=2.0)
            self.assertEqual(message["type"], "gap")
            event = await ws.receive_json(timeout=2.0)
            self.assertEqual(event["type"], "event")
        finally:
            await ws.close()

    async def test_current_and_retained_logs_are_downloadable(self) -> None:
        self.core.emit_event("state", "test", value=1)
        current = await self.client.get("/api/v1/logs/current")
        self.assertEqual(current.status, 200)
        self.assertIn(b'"kind":"state"', await current.read())

        archive = await self.client.get("/api/v1/logs/archive")
        self.assertEqual(archive.status, 200)
        self.assertTrue((await archive.read()).startswith(b"PK"))


class GatewayWebBindTest(unittest.TestCase):
    def test_bind_conflict_is_fatal_and_never_selects_another_port(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            occupied = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            occupied.bind(("127.0.0.1", 0))
            occupied.listen(1)
            port = occupied.getsockname()[1]
            events = RuntimeEventLog(directory=root / "logs")
            core = GatewayRuntimeCore(
                mode="standalone",
                platform="windows",
                transport_kind="tcp",
                tcp_host="0.0.0.0",
                tcp_port=5678,
                can_interface="can0",
                event_log=events,
                config_store=GatewayConfigStore(root / "config.json"),
            )
            server = GatewayWebServer(core, port=port)
            try:
                with self.assertRaisesRegex(RuntimeError, f"127.0.0.1:{port}"):
                    server.start()
            finally:
                server.close()
                core.close()
                occupied.close()


if __name__ == "__main__":
    unittest.main()
