from __future__ import annotations

import queue
import socket
import struct
import threading
import time
import unittest
from unittest.mock import patch

from pc001_test_client.protocol import CAN_EFF_FLAG, Pc001Batch
from pc001_test_client.receiver import Pc001Receiver, ReceiverEvent, ReceiverState


def _free_port() -> int:
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", 0))
    port = int(sock.getsockname()[1])
    sock.close()
    return port


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise ConnectionError("peer closed")
        data.extend(chunk)
    return bytes(data)


def _batch_wire() -> bytes:
    payload = bytes.fromhex("01 02 03 04")
    frame = struct.pack(
        "<IBBBB8s", CAN_EFF_FLAG | 0x18FFF100, len(payload), 0, 0, 0, payload.ljust(8, b"\0")
    ) + struct.pack("<i", 3)
    return struct.pack("<H", 1) + frame


class ReceiverTest(unittest.TestCase):
    def test_connects_handshakes_and_receives_fragmented_batch(self) -> None:
        port = _free_port()
        identity: queue.Queue[bytes] = queue.Queue()

        def serve() -> None:
            server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            server.bind(("127.0.0.1", port))
            server.listen(1)
            client, _ = server.accept()
            with client:
                client.sendall(b"w")
                client.sendall(b"ho")
                identity.put(_recv_exact(client, 5))
                wire = _batch_wire()
                for offset in range(0, len(wire), 2):
                    client.sendall(wire[offset : offset + 2])
            server.close()

        server_thread = threading.Thread(target=serve, daemon=True)
        server_thread.start()
        states: queue.Queue[ReceiverEvent] = queue.Queue()
        batches: queue.Queue[tuple[int, Pc001Batch, float]] = queue.Queue()
        receiver = Pc001Receiver(states.put, lambda generation, batch, received_s: batches.put(
            (generation, batch, received_s)
        ))
        try:
            generation = receiver.start("127.0.0.1", port)
            observed_states: list[ReceiverState] = []
            deadline = time.monotonic() + 3.0
            while ReceiverState.CONNECTED not in observed_states and time.monotonic() < deadline:
                observed_states.append(states.get(timeout=1).state)
            self.assertIn(ReceiverState.CONNECTING, observed_states)
            self.assertIn(ReceiverState.HANDSHAKING, observed_states)
            self.assertIn(ReceiverState.CONNECTED, observed_states)
            self.assertEqual(identity.get(timeout=1), b"PC001")
            batch_generation, batch, received_s = batches.get(timeout=2)
            self.assertEqual(batch_generation, generation)
            self.assertGreater(received_s, 0.0)
            self.assertEqual(batch.frames[0].can_id, 0x18FFF100)
            self.assertEqual(batch.frames[0].channel, 3)
        finally:
            receiver.stop()
            server_thread.join(timeout=2)

    def test_connection_failure_is_reported_and_can_restart(self) -> None:
        states: queue.Queue[ReceiverEvent] = queue.Queue()
        receiver = Pc001Receiver(states.put, lambda _generation, _batch, _received_s: None)
        port = _free_port()
        first_generation = receiver.start("127.0.0.1", port)
        error: ReceiverEvent | None = None
        deadline = time.monotonic() + 3.0
        while error is None and time.monotonic() < deadline:
            try:
                event = states.get(timeout=0.25)
            except queue.Empty:
                continue
            if event.state == ReceiverState.ERROR:
                error = event
        self.assertIsNotNone(error)
        self.assertEqual(error.generation if error else -1, first_generation)
        second_generation = receiver.start("127.0.0.1", port)
        self.assertGreater(second_generation, first_generation)
        receiver.stop()

    def test_stop_refuses_to_overlap_a_worker_that_has_not_joined(self) -> None:
        release = threading.Event()
        states: queue.Queue[ReceiverEvent] = queue.Queue()
        receiver = Pc001Receiver(states.put, lambda _generation, _batch, _received_s: None)

        def slow_connect(_address: tuple[str, int], timeout: float) -> socket.socket:
            del timeout
            release.wait(timeout=1.0)
            raise OSError("cancelled slow connect")

        with patch("pc001_test_client.receiver.socket.create_connection", slow_connect):
            receiver.start("127.0.0.1", 5678)
            self.assertEqual(states.get(timeout=1).state, ReceiverState.CONNECTING)
            with self.assertRaisesRegex(RuntimeError, "did not stop"):
                receiver.stop(join_timeout_s=0.01)
            release.set()
            receiver.stop(join_timeout_s=1.0)
        self.assertFalse(receiver.running)


if __name__ == "__main__":
    unittest.main()
