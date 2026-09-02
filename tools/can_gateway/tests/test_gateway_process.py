"""Process-level owner-loop integration for the standalone DBC Web controls."""

from __future__ import annotations

import asyncio
import json
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

from aiohttp import ClientSession, WSMsgType

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from control_protocol import CMD_RECORD_STOP, CMD_SHUTDOWN, build_control  # noqa: E402
from conventions import PACKET_MAGIC  # noqa: E402
from pc001_sink import BATCH_PREFIX_STRUCT, SINGLE_FRAME_SIZE  # noqa: E402


def free_port(*, udp: bool = False) -> int:
    kind = socket.SOCK_DGRAM if udp else socket.SOCK_STREAM
    probe = socket.socket(socket.AF_INET, kind)
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


def request_json(url: str, method: str = "GET", body: dict | None = None) -> dict:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data is not None else {},
    )
    with urllib.request.urlopen(request, timeout=3.0) as response:
        return json.loads(response.read())


def recv_exact(client: socket.socket, size: int) -> bytes:
    result = b""
    while len(result) < size:
        chunk = client.recv(size - len(result))
        if not chunk:
            raise ConnectionError("PC001 connection closed")
        result += chunk
    return result


def make_telemetry_packet(tick_ms: int) -> bytes:
    raw = struct.pack("<IBBHQ", PACKET_MAGIC, 1, 0, 0, tick_ms)
    for index in range(5):
        raw += struct.pack("<4f3f", 0.0, 0.0, 0.0, 1.0, float(index), 0.0, 0.0)
    return raw + struct.pack("<5f", 0.0, 0.0, 0.0, 0.0, 0.0)


async def mutate_and_wait_event(
    base: str,
    after: int,
    kind: str,
    mutation,
) -> dict:
    async with ClientSession() as session, session.ws_connect(
        f"{base}/api/v1/events?after={after}",
        origin=base,
    ) as websocket:
        result = await asyncio.to_thread(mutation)
        while True:
            message = await websocket.receive(timeout=3.0)
            if message.type != WSMsgType.TEXT:
                raise AssertionError(f"unexpected WebSocket message {message.type}")
            envelope = message.json()
            if (
                envelope.get("type") == "event"
                and envelope.get("event", {}).get("kind") == kind
            ):
                return result


class GatewayStandaloneDbcProcessTest(unittest.TestCase):
    def test_api_commands_execute_in_owner_and_disconnect_disarms(self) -> None:
        udp_port = free_port(udp=True)
        ack_port = free_port(udp=True)
        tcp_port = free_port()
        web_port = free_port()
        with tempfile.TemporaryDirectory() as tmp:
            environment = dict(os.environ)
            environment["LOCALAPPDATA"] = str(Path(tmp, "local"))
            environment["XDG_CONFIG_HOME"] = str(Path(tmp, "config"))
            environment["XDG_STATE_HOME"] = str(Path(tmp, "state"))
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(TOOLS_DIR / "gateway.py"),
                    "--mode",
                    "standalone",
                    "--sink",
                    "tcp",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(udp_port),
                    "--ack-port",
                    str(ack_port),
                    "--tcp-host",
                    "127.0.0.1",
                    "--tcp-port",
                    str(tcp_port),
                    "--web-port",
                    str(web_port),
                    "--out",
                    str(Path(tmp, "output")),
                ],
                cwd=TOOLS_DIR.parents[1],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            base = f"http://127.0.0.1:{web_port}"
            client: socket.socket | None = None
            try:
                deadline = time.time() + 8.0
                while True:
                    try:
                        status = request_json(f"{base}/api/v1/status")["status"]
                        break
                    except (OSError, urllib.error.URLError):
                        if time.time() >= deadline:
                            self.fail("Gateway Web API did not become ready")
                        time.sleep(0.05)

                self.assertEqual(status["tcp_port"], tcp_port)
                with urllib.request.urlopen(f"{base}/", timeout=3.0) as response:
                    root_html = response.read().decode("utf-8")
                self.assertIn("Gateway CAN Console", root_html)
                with urllib.request.urlopen(f"{base}/operator/messages", timeout=3.0) as response:
                    fallback_html = response.read().decode("utf-8")
                self.assertEqual(fallback_html, root_html)
                self.assertIn('<base href="/"', fallback_html)
                client = socket.create_connection(("127.0.0.1", tcp_port), timeout=3.0)
                self.assertEqual(recv_exact(client, 3), b"who")
                client.sendall(b"PC001")
                deadline = time.time() + 3.0
                while not status["pc001_handshake"] and time.time() < deadline:
                    time.sleep(0.05)
                    status = request_json(f"{base}/api/v1/status")["status"]
                self.assertTrue(status["pc001_handshake"])

                snapshot = request_json(f"{base}/api/v1/can-console")
                console = snapshot["console"]
                status = snapshot["status"]
                message = next(
                    item
                    for item in console["messages"]
                    if item["message"]["frame_id"] == 0x0CFDA800
                )
                key = urllib.parse.quote(message["key"], safe="")
                preview = request_json(
                    f"{base}/api/v1/can-console/messages/{key}/preview",
                    "POST",
                    {
                        "payload_hex": "7B 00 C7 FF 00 00 87 00",
                    },
                )["result"]["preview"]
                self.assertEqual(preview["payload_hex"], "7B 00 C7 FF 00 00 87 00")
                self.assertAlmostEqual(preview["values"]["VelE"], 1.23)
                self.assertEqual(
                    request_json(f"{base}/api/v1/status")["status"]["revision"],
                    status["revision"],
                )
                authority = asyncio.run(
                    mutate_and_wait_event(
                        base,
                        status["event_sequence"],
                        "can_console_authority_updated",
                        lambda: request_json(
                            f"{base}/api/v1/can-console/messages/{key}/authority",
                            "PUT",
                            {
                                "expected_revision": status["revision"],
                                "authority": "custom",
                            },
                        ),
                    )
                )
                revision = authority["result"]["status"]["revision"]
                updated = request_json(
                    f"{base}/api/v1/can-console/messages/{key}",
                    "PUT",
                    {
                        "expected_revision": revision,
                        "payload_hex": "7B 00 C7 FF 00 00 87 00",
                        "frequency_hz": 50,
                    },
                )
                revision = updated["result"]["status"]["revision"]
                started = request_json(
                    f"{base}/api/v1/can-console/start",
                    "POST",
                    {"expected_revision": revision},
                )
                self.assertTrue(started["result"]["status"]["periodic_armed"])
                target_frame: bytes | None = None
                deadline = time.time() + 3.0
                while target_frame is None and time.time() < deadline:
                    (count,) = BATCH_PREFIX_STRUCT.unpack(
                        recv_exact(client, BATCH_PREFIX_STRUCT.size)
                    )
                    body = recv_exact(client, count * SINGLE_FRAME_SIZE)
                    for offset in range(0, len(body), SINGLE_FRAME_SIZE):
                        frame = body[offset : offset + SINGLE_FRAME_SIZE]
                        if struct.unpack("<I", frame[:4])[0] & 0x1FFFFFFF == 0x0CFDA800:
                            target_frame = frame
                            break
                self.assertIsNotNone(target_frame)
                assert target_frame is not None
                self.assertEqual(target_frame[8:16].hex(), "7b00c7ff00008700")

                revision = started["result"]["status"]["revision"]
                stopped = request_json(
                    f"{base}/api/v1/can-console/stop",
                    "POST",
                    {"expected_revision": revision},
                )
                self.assertFalse(stopped["result"]["status"]["periodic_armed"])

                client.close()
                client = None
                deadline = time.time() + 3.0
                while time.time() < deadline:
                    status = request_json(f"{base}/api/v1/status")["status"]
                    if not status["periodic_armed"]:
                        break
                    time.sleep(0.05)
                self.assertFalse(status["periodic_armed"])
            finally:
                if client is not None:
                    client.close()
                sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sender.sendto(build_control(CMD_SHUTDOWN), ("127.0.0.1", udp_port))
                sender.close()
                try:
                    process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=3.0)
                self.assertEqual(process.returncode, 0)


class GatewayGodotActivityProcessTest(unittest.TestCase):
    def test_only_valid_telemetry_drives_managed_godot_connection(self) -> None:
        udp_port = free_port(udp=True)
        ack_port = free_port(udp=True)
        tcp_port = free_port()
        web_port = free_port()
        with tempfile.TemporaryDirectory() as tmp:
            environment = dict(os.environ)
            environment["LOCALAPPDATA"] = str(Path(tmp, "local"))
            environment["XDG_CONFIG_HOME"] = str(Path(tmp, "config"))
            environment["XDG_STATE_HOME"] = str(Path(tmp, "state"))
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(TOOLS_DIR / "gateway.py"),
                    "--mode",
                    "godot-managed",
                    "--sink",
                    "tcp",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(udp_port),
                    "--ack-port",
                    str(ack_port),
                    "--tcp-host",
                    "127.0.0.1",
                    "--tcp-port",
                    str(tcp_port),
                    "--web-port",
                    str(web_port),
                    "--out",
                    str(Path(tmp, "output")),
                ],
                cwd=TOOLS_DIR.parents[1],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            base = f"http://127.0.0.1:{web_port}"
            sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            try:
                deadline = time.time() + 8.0
                while True:
                    try:
                        status = request_json(f"{base}/api/v1/status")["status"]
                        break
                    except (OSError, urllib.error.URLError):
                        if time.time() >= deadline:
                            self.fail("managed Gateway Web API did not become ready")
                        time.sleep(0.05)
                self.assertFalse(status["godot_connected"])

                sender.sendto(build_control(CMD_RECORD_STOP), ("127.0.0.1", udp_port))
                sender.sendto(b"not-telemetry", ("127.0.0.1", udp_port))
                time.sleep(0.1)
                self.assertFalse(
                    request_json(f"{base}/api/v1/status")["status"]["godot_connected"]
                )

                sender.sendto(make_telemetry_packet(1), ("127.0.0.1", udp_port))
                deadline = time.time() + 2.0
                while time.time() < deadline:
                    if request_json(f"{base}/api/v1/status")["status"]["godot_connected"]:
                        break
                    time.sleep(0.05)
                self.assertTrue(
                    request_json(f"{base}/api/v1/status")["status"]["godot_connected"]
                )

                deadline = time.time() + 3.5
                while time.time() < deadline:
                    if not request_json(f"{base}/api/v1/status")["status"]["godot_connected"]:
                        break
                    time.sleep(0.05)
                self.assertFalse(
                    request_json(f"{base}/api/v1/status")["status"]["godot_connected"]
                )

                sender.sendto(make_telemetry_packet(2), ("127.0.0.1", udp_port))
                deadline = time.time() + 2.0
                while time.time() < deadline:
                    if request_json(f"{base}/api/v1/status")["status"]["godot_connected"]:
                        break
                    time.sleep(0.05)
                self.assertTrue(
                    request_json(f"{base}/api/v1/status")["status"]["godot_connected"]
                )
            finally:
                sender.sendto(build_control(CMD_SHUTDOWN), ("127.0.0.1", udp_port))
                sender.close()
                try:
                    process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=3.0)
                self.assertEqual(process.returncode, 0)


class GatewayManagedOfflineCustomProcessTest(unittest.TestCase):
    def test_custom_authority_survives_missing_pc001_and_resumes_after_reconnect(self) -> None:
        udp_port = free_port(udp=True)
        ack_port = free_port(udp=True)
        tcp_port = free_port()
        web_port = free_port()
        with tempfile.TemporaryDirectory() as tmp:
            environment = dict(os.environ)
            environment["LOCALAPPDATA"] = str(Path(tmp, "local"))
            environment["XDG_CONFIG_HOME"] = str(Path(tmp, "config"))
            environment["XDG_STATE_HOME"] = str(Path(tmp, "state"))
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(TOOLS_DIR / "gateway.py"),
                    "--mode",
                    "godot-managed",
                    "--sink",
                    "tcp",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(udp_port),
                    "--ack-port",
                    str(ack_port),
                    "--tcp-host",
                    "127.0.0.1",
                    "--tcp-port",
                    str(tcp_port),
                    "--web-port",
                    str(web_port),
                    "--out",
                    str(Path(tmp, "output")),
                ],
                cwd=TOOLS_DIR.parents[1],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
            base = f"http://127.0.0.1:{web_port}"
            client: socket.socket | None = None
            try:
                deadline = time.time() + 8.0
                while True:
                    try:
                        status = request_json(f"{base}/api/v1/status")["status"]
                        break
                    except (OSError, urllib.error.URLError):
                        if time.time() >= deadline:
                            self.fail("managed Gateway Web API did not become ready")
                        time.sleep(0.05)

                snapshot = request_json(f"{base}/api/v1/can-console")
                message = next(
                    item
                    for item in snapshot["console"]["messages"]
                    if item["message"]["frame_id"] == 0x0CFDA800
                )
                key = urllib.parse.quote(message["key"], safe="")
                authority = request_json(
                    f"{base}/api/v1/can-console/messages/{key}/authority",
                    "PUT",
                    {"expected_revision": snapshot["status"]["revision"], "authority": "custom"},
                )
                revision = authority["result"]["status"]["revision"]
                updated = request_json(
                    f"{base}/api/v1/can-console/messages/{key}",
                    "PUT",
                    {
                        "expected_revision": revision,
                        "payload_hex": "7B 00 C7 FF 00 00 87 00",
                        "frequency_hz": 20,
                    },
                )
                revision = updated["result"]["status"]["revision"]

                deadline = time.time() + 3.0
                while time.time() < deadline:
                    current = request_json(f"{base}/api/v1/can-console")
                    row = next(
                        item
                        for item in current["console"]["messages"]
                        if item["key"] == message["key"]
                    )
                    status = current["status"]
                    if row["authority"] == "custom" and status["pc001_dropped_frames"] > 0:
                        break
                    time.sleep(0.05)
                self.assertEqual(row["authority"], "custom")
                self.assertGreater(status["pc001_dropped_frames"], 0)
                self.assertIsNone(row["runtime"]["actual_frequency_hz"])

                client = socket.create_connection(("127.0.0.1", tcp_port), timeout=3.0)
                self.assertEqual(recv_exact(client, 3), b"who")
                client.sendall(b"PC001")
                deadline = time.time() + 3.0
                while time.time() < deadline:
                    status = request_json(f"{base}/api/v1/status")["status"]
                    if status["pc001_handshake"]:
                        break
                    time.sleep(0.05)
                self.assertTrue(status["pc001_handshake"])
                client.settimeout(3.0)
                target_seen = False
                deadline = time.time() + 3.0
                while time.time() < deadline and not target_seen:
                    frame_count, = BATCH_PREFIX_STRUCT.unpack(
                        recv_exact(client, BATCH_PREFIX_STRUCT.size)
                    )
                    body = recv_exact(client, frame_count * SINGLE_FRAME_SIZE)
                    for offset in range(0, len(body), SINGLE_FRAME_SIZE):
                        frame = body[offset : offset + SINGLE_FRAME_SIZE]
                        if struct.unpack("<I", frame[:4])[0] & 0x1FFFFFFF == 0x0CFDA800:
                            self.assertEqual(frame[8:16].hex(), "7b00c7ff00008700")
                            target_seen = True
                            break
                self.assertTrue(target_seen, "custom frame did not resume after PC001 handshake")
                current = request_json(f"{base}/api/v1/can-console")
                row = next(
                    item
                    for item in current["console"]["messages"]
                    if item["key"] == message["key"]
                )
                self.assertEqual(row["authority"], "custom")
                self.assertGreaterEqual(row["runtime"]["sample_count"], 1)

                client.close()
                client = None
                deadline = time.time() + 3.0
                while time.time() < deadline:
                    if not request_json(f"{base}/api/v1/status")["status"]["pc001_handshake"]:
                        break
                    time.sleep(0.05)
                current = request_json(f"{base}/api/v1/can-console")
                row = next(
                    item
                    for item in current["console"]["messages"]
                    if item["key"] == message["key"]
                )
                self.assertEqual(row["authority"], "custom")

                client = socket.create_connection(("127.0.0.1", tcp_port), timeout=3.0)
                self.assertEqual(recv_exact(client, 3), b"who")
                client.sendall(b"PC001")
                deadline = time.time() + 3.0
                while time.time() < deadline:
                    if request_json(f"{base}/api/v1/status")["status"]["pc001_handshake"]:
                        break
                    time.sleep(0.05)
                self.assertTrue(request_json(f"{base}/api/v1/status")["status"]["pc001_handshake"])
                client.settimeout(3.0)
                target_seen = False
                deadline = time.time() + 3.0
                while time.time() < deadline and not target_seen:
                    frame_count, = BATCH_PREFIX_STRUCT.unpack(
                        recv_exact(client, BATCH_PREFIX_STRUCT.size)
                    )
                    body = recv_exact(client, frame_count * SINGLE_FRAME_SIZE)
                    for offset in range(0, len(body), SINGLE_FRAME_SIZE):
                        frame = body[offset : offset + SINGLE_FRAME_SIZE]
                        if struct.unpack("<I", frame[:4])[0] & 0x1FFFFFFF == 0x0CFDA800:
                            self.assertEqual(frame[8:16].hex(), "7b00c7ff00008700")
                            target_seen = True
                            break
                self.assertTrue(target_seen, "custom frame did not resume after reconnect")
            finally:
                if client is not None:
                    client.close()
                sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sender.sendto(build_control(CMD_SHUTDOWN), ("127.0.0.1", udp_port))
                sender.close()
                try:
                    process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    process.terminate()
                    process.wait(timeout=3.0)
                self.assertEqual(process.returncode, 0)


if __name__ == "__main__":
    unittest.main()
