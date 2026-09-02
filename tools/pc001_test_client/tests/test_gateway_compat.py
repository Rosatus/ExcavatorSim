from __future__ import annotations

import importlib
import socket
import sys
import time
import unittest
from collections.abc import Callable
from pathlib import Path
from typing import Literal, Protocol, cast

from pc001_test_client.protocol import Pc001Frame, perform_handshake, recv_batch

GATEWAY_DIR = Path(__file__).resolve().parents[2] / "can_gateway"
sys.path.insert(0, str(GATEWAY_DIR))

CanChannel = Literal["ch0", "ch2", "ch3"]


class _GatewaySink(Protocol):
    def is_handshake_connected(self) -> bool: ...

    def submit(
        self,
        can_id: int,
        payload: bytes,
        *,
        channel: CanChannel,
        source: str,
        family: str,
        is_extended: bool | None = None,
    ) -> None: ...

    def close(self) -> None: ...


SinkFactory = Callable[[str, int], _GatewaySink]
TcpPc001Sink = cast(
    SinkFactory,
    vars(importlib.import_module("pc001_sink"))["TcpPc001Sink"],
)


def _free_port() -> int:
    probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    probe.bind(("127.0.0.1", 0))
    port = int(probe.getsockname()[1])
    probe.close()
    return port


class GatewayCompatibilityTest(unittest.TestCase):
    def test_real_sink_matches_client_wire_decoder_and_channels(self) -> None:
        port = _free_port()
        sink = TcpPc001Sink("127.0.0.1", port)
        client = socket.create_connection(("127.0.0.1", port), timeout=2.0)
        client.settimeout(2.0)
        try:
            perform_handshake(client)
            deadline = time.monotonic() + 2.0
            while not sink.is_handshake_connected() and time.monotonic() < deadline:
                time.sleep(0.01)
            self.assertTrue(sink.is_handshake_connected())

            expected: tuple[tuple[int, bool, bytes, CanChannel, int], ...] = (
                (0x18FF3A00, True, b"\x33" * 8, "ch3", 3),
                (0x18FF5400, True, b"\x22" * 8, "ch2", 2),
                (0x18FFF100, True, b"\x11" * 8, "ch3", 3),
                (0x256, False, b"\x00" * 8, "ch0", 0),
            )
            for can_id, is_extended, payload, channel, _channel_number in expected:
                sink.submit(
                    can_id,
                    payload,
                    channel=channel,
                    source="test",
                    family="test",
                    is_extended=is_extended,
                )

            observed: list[Pc001Frame] = []
            while len(observed) < len(expected):
                observed.extend(recv_batch(client).frames)
            self.assertEqual(
                [
                    (frame.can_id, frame.is_extended, frame.payload, frame.channel)
                    for frame in observed
                ],
                [
                    (can_id, is_extended, payload, channel_number)
                    for can_id, is_extended, payload, _channel, channel_number in expected
                ],
            )
        finally:
            client.close()
            sink.close()


if __name__ == "__main__":
    unittest.main()
