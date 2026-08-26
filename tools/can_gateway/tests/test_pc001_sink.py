"""Tests for the PC001 TCP sink. Run: python -m unittest discover -s tools/can_gateway/tests"""

from __future__ import annotations

import socket
import struct
import sys
import time
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from pc001_sink import (  # noqa: E402
    BATCH_PREFIX_STRUCT,
    CAN_FRAME_SIZE,
    MAX_BATCH_FRAMES,
    SINGLE_FRAME_SIZE,
    TcpPc001Sink,
)


def free_port() -> int:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


class _Client:
    def __init__(self, port: int, handshake: bytes = b"PC001") -> None:
        self.sock = socket.create_connection(("127.0.0.1", port), timeout=3)
        who = self._recv_exact(3)
        assert who == b"who", f"bad server greeting {who!r}"
        self.sock.sendall(handshake)

    def recv_batch(self) -> tuple[int, list[tuple[int, bytes]]]:
        header = self._recv_exact(BATCH_PREFIX_STRUCT.size)
        (count,) = BATCH_PREFIX_STRUCT.unpack(header)
        body = self._recv_exact(count * SINGLE_FRAME_SIZE)
        frames = []
        for i in range(count):
            off = i * SINGLE_FRAME_SIZE
            can_id, dlc = struct.unpack("<IB", body[off:off + 5])
            payload = body[off + 8:off + 8 + dlc]
            channel, = struct.unpack("<i", body[off + CAN_FRAME_SIZE:off + SINGLE_FRAME_SIZE])
            frames.append((can_id, payload))
            del channel  # protocol carries it; sink always sends 0
        return count, frames

    def _recv_exact(self, n: int) -> bytes:
        data = b""
        while len(data) < n:
            chunk = self.sock.recv(n - len(data))
            if not chunk:
                raise ConnectionError("closed")
            data += chunk
        return data

    def close(self) -> None:
        self.sock.close()


class TcpPc001SinkTest(unittest.TestCase):
    def setUp(self) -> None:
        self.port = free_port()
        self.sink = TcpPc001Sink("127.0.0.1", self.port)

    def tearDown(self) -> None:
        self.sink.close()

    def test_handshake_and_frame_bytes(self) -> None:
        client = _Client(self.port)
        try:
            # wait for client registration
            for _ in range(50):
                if "connected" in self.sink.peer_name():
                    break
                time.sleep(0.02)
            self.sink.append(0x256, b"\x09\x00\x00\x00\xfb\xff\xff\xff")
            count, frames = client.recv_batch()
            self.assertEqual(count, 1)
            can_id, payload = frames[0]
            self.assertEqual(can_id, 0x256)
            self.assertEqual(payload, b"\x09\x00\x00\x00\xfb\xff\xff\xff")
        finally:
            client.close()

    def test_bad_handshake_rejected_then_recovery(self) -> None:
        bad = _Client(self.port, handshake=b"WRONG")
        bad.close()
        good = _Client(self.port)
        try:
            for _ in range(50):
                if "connected" in self.sink.peer_name():
                    break
                time.sleep(0.02)
            self.sink.append(0x123, b"\x01" * 8)
            count, frames = good.recv_batch()
            self.assertEqual(count, 1)
            self.assertEqual(frames[0][0], 0x123)
        finally:
            good.close()

    def test_no_client_append_is_safe(self) -> None:
        self.sink.append(0x456, b"\x02" * 8)
        self.assertIn("waiting", self.sink.peer_name())

    def test_large_burst_split_into_batches(self) -> None:
        client = _Client(self.port)
        try:
            for _ in range(50):
                if "connected" in self.sink.peer_name():
                    break
                time.sleep(0.02)
            total = MAX_BATCH_FRAMES + 30
            for i in range(total):
                self.sink.append(0x100 + (i % 8), bytes([i % 256]) * 8)
            received = 0
            batches = 0
            client.sock.settimeout(5)
            while received < total:
                count, _frames = client.recv_batch()
                self.assertLessEqual(count, MAX_BATCH_FRAMES)
                received += count
                batches += 1
            self.assertGreaterEqual(batches, 2)
        finally:
            client.close()

    def test_reconnect_recovers_and_requeues(self) -> None:
        first = _Client(self.port)
        for _ in range(50):
            if "connected" in self.sink.peer_name():
                break
            time.sleep(0.02)
        self.sink.append(0x111, b"\x03" * 8)
        first.close()  # drop without reading: frame should be requeued
        deadline = time.time() + 2
        while time.time() < deadline and self.sink._client is None:
            time.sleep(0.02)

        second = _Client(self.port)
        try:
            second.sock.settimeout(5)
            count, frames = second.recv_batch()
            self.assertEqual(count, 1)
            self.assertEqual(frames[0][0], 0x111)
        finally:
            second.close()

    def test_close_idempotent(self) -> None:
        self.sink.close()
        self.sink.close()


if __name__ == "__main__":
    unittest.main()
