"""Tests for the PC001 TCP sink. Run: python -m unittest discover -s tools/can_gateway/tests"""

from __future__ import annotations

import socket
import struct
import sys
import threading
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
from sinks import CAN_EFF_FLAG  # noqa: E402


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
            can_id, dlc = struct.unpack("<IB", body[off : off + 5])
            payload = body[off + 8 : off + 8 + dlc]
            (channel,) = struct.unpack("<i", body[off + CAN_FRAME_SIZE : off + SINGLE_FRAME_SIZE])
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

    def wait_handshake_state(self, expected: bool, timeout: float = 2.0) -> bool:
        deadline = time.time() + timeout
        while time.time() < deadline:
            if self.sink.is_handshake_connected() == expected:
                return True
            time.sleep(0.02)
        return self.sink.is_handshake_connected() == expected

    def test_handshake_and_frame_bytes(self) -> None:
        self.assertFalse(self.sink.is_handshake_connected())
        client = _Client(self.port)
        try:
            self.assertTrue(self.wait_handshake_state(True))
            self.sink.append(0x256, b"\x09\x00\x00\x00\xfb\xff\xff\xff")
            count, frames = client.recv_batch()
            self.assertEqual(count, 1)
            can_id, payload = frames[0]
            self.assertEqual(can_id, 0x256)
            self.assertEqual(payload, b"\x09\x00\x00\x00\xfb\xff\xff\xff")
        finally:
            client.close()

    def test_egress_observer_runs_only_after_successful_batch_write(self) -> None:
        observed: list[tuple[str, str, int, bool, bytes, float]] = []
        self.sink.set_egress_observer(
            lambda source, family, can_id, is_extended, payload, completed_s: observed.append(
                (source, family, can_id, is_extended, payload, completed_s)
            )
        )
        client = _Client(self.port)
        try:
            self.assertTrue(self.wait_handshake_state(True))
            payload = b"\x33" * 8
            self.sink.submit(0x18FF3A00, payload, source="godot", family="imu")
            self.assertEqual(observed, [])
            client.recv_batch()
            deadline = time.time() + 1.0
            while not observed and time.time() < deadline:
                time.sleep(0.01)
            self.assertEqual(observed[0][:5], ("godot", "imu", 0x18FF3A00, True, payload))
            self.assertIsInstance(observed[0][5], float)
        finally:
            client.close()

    def test_handshake_state_clears_on_disconnect_and_close(self) -> None:
        client = _Client(self.port)
        self.assertTrue(self.wait_handshake_state(True))
        client.close()
        self.assertTrue(self.wait_handshake_state(False))
        replacement = _Client(self.port)
        self.assertTrue(self.wait_handshake_state(True))
        self.sink.close()
        self.assertFalse(self.sink.is_handshake_connected())
        replacement.close()

    def test_bad_handshake_rejected_then_recovery(self) -> None:
        bad = _Client(self.port, handshake=b"WRONG")
        bad.close()
        self.assertTrue(self.wait_handshake_state(False))
        good = _Client(self.port)
        try:
            self.assertTrue(self.wait_handshake_state(True))
            self.sink.append(0x123, b"\x01" * 8)
            count, frames = good.recv_batch()
            self.assertEqual(count, 1)
            self.assertEqual(frames[0][0], 0x123)
        finally:
            good.close()

    def test_extended_id_is_sent_with_socketcan_eff_flag(self) -> None:
        client = _Client(self.port)
        try:
            for _ in range(50):
                if "connected" in self.sink.peer_name():
                    break
                time.sleep(0.02)
            self.sink.append(0x18FF3A00, b"\x44" * 8)
            _count, frames = client.recv_batch()
            self.assertEqual(frames[0][0], CAN_EFF_FLAG | 0x18FF3A00)
        finally:
            client.close()

    def test_low_numeric_extended_id_uses_explicit_eff_flag(self) -> None:
        client = _Client(self.port)
        try:
            self.assertTrue(self.wait_handshake_state(True))
            self.sink.submit(
                0x123,
                b"\x55" * 8,
                source="web",
                family="dbc",
                is_extended=True,
            )
            _count, frames = client.recv_batch()
            self.assertEqual(frames[0][0], CAN_EFF_FLAG | 0x123)
        finally:
            client.close()

    def test_timed_frame_wire_id_and_payload(self) -> None:
        client = _Client(self.port)
        try:
            for _ in range(50):
                if "connected" in self.sink.peer_name():
                    break
                time.sleep(0.02)
            payload = bytes.fromhex("01 00 00 00 00 00 00 00")
            self.sink.append(0x18FFF100, payload)
            count, frames = client.recv_batch()
            self.assertEqual(count, 1)
            self.assertEqual(frames, [(CAN_EFF_FLAG | 0x18FFF100, payload)])
        finally:
            client.close()

    def test_no_client_append_is_safe(self) -> None:
        self.sink.append(0x456, b"\x02" * 8)
        self.assertIn("waiting", self.sink.peer_name())
        status = self.sink.status_snapshot()
        self.assertEqual(status.queued_frames, 0)
        self.assertEqual(status.dropped_no_client, 1)
        self.assertEqual(status.dropped_frames, 1)

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

    def test_reconnect_does_not_replay_disconnected_frames(self) -> None:
        first = _Client(self.port)
        for _ in range(50):
            if "connected" in self.sink.peer_name():
                break
            time.sleep(0.02)
        first.close()
        self.assertTrue(self.wait_handshake_state(False))
        self.sink.append(0x111, b"\x03" * 8)
        self.assertEqual(self.sink.status_snapshot().dropped_no_client, 1)

        second = _Client(self.port)
        try:
            self.assertTrue(self.wait_handshake_state(True))
            second.sock.settimeout(0.2)
            with self.assertRaises(socket.timeout):
                second.recv_batch()
            self.sink.append(0x112, b"\x04" * 8)
            second.sock.settimeout(5)
            count, frames = second.recv_batch()
            self.assertEqual(count, 1)
            self.assertEqual(frames[0][0], 0x112)
        finally:
            second.close()

    def test_status_counts_sent_frames(self) -> None:
        client = _Client(self.port)
        try:
            self.assertTrue(self.wait_handshake_state(True))
            self.sink.append(0x321, b"\x05" * 8)
            count, _frames = client.recv_batch()
            self.assertEqual(count, 1)
            deadline = time.time() + 1.0
            while self.sink.status_snapshot().sent_frames != 1 and time.time() < deadline:
                time.sleep(0.01)
            status = self.sink.status_snapshot()
            self.assertEqual(status.sent_frames, 1)
            self.assertEqual(status.queued_frames, 0)
            self.assertEqual(status.dropped_frames, 0)
        finally:
            client.close()

    def test_queue_is_bounded_and_only_service_thread_writes_batches(self) -> None:
        self.sink.close()
        entered = threading.Event()
        release = threading.Event()
        send_threads: list[str] = []

        class ControlledSink(TcpPc001Sink):
            def _take_batch(self, client):
                entered.set()
                release.wait(timeout=2.0)
                return super()._take_batch(client)

            def _send_batch(self, client, batch):
                send_threads.append(threading.current_thread().name)
                return super()._send_batch(client, batch)

        self.sink = ControlledSink("127.0.0.1", self.port, queue_capacity=8)
        client = _Client(self.port)
        try:
            self.assertTrue(self.wait_handshake_state(True))
            self.assertTrue(entered.wait(timeout=1.0))
            producers = [
                threading.Thread(
                    target=self.sink.append,
                    args=(0x200 + index, bytes([index]) * 8),
                    name=f"producer-{index}",
                )
                for index in range(16)
            ]
            for producer in producers:
                producer.start()
            for producer in producers:
                producer.join(timeout=1.0)
            status = self.sink.status_snapshot()
            self.assertEqual(status.queued_frames, 8)
            self.assertEqual(status.dropped_queue_full, 8)
            release.set()
            count, frames = client.recv_batch()
            self.assertEqual(count, 8)
            self.assertEqual(len({can_id for can_id, _payload in frames}), 8)
            deadline = time.time() + 1.0
            while not send_threads and time.time() < deadline:
                time.sleep(0.01)
            self.assertEqual(send_threads, ["pc001-service"])
        finally:
            release.set()
            client.close()

    def test_close_idempotent(self) -> None:
        self.sink.close()
        self.sink.close()


if __name__ == "__main__":
    unittest.main()
