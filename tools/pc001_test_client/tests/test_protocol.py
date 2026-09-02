from __future__ import annotations

import struct
import unittest

from pc001_test_client.protocol import (
    CAN_EFF_FLAG,
    CLIENT_IDENTITY,
    Pc001ConnectionClosed,
    Pc001HandshakeError,
    Pc001ProtocolError,
    Pc001TimeoutError,
    decode_frame,
    perform_handshake,
    recv_batch,
    recv_exact,
)


class _FragmentedSocket:
    def __init__(self, chunks: list[bytes]) -> None:
        self.chunks = chunks
        self.sent = bytearray()

    def recv(self, size: int) -> bytes:
        if not self.chunks:
            return b""
        chunk = self.chunks.pop(0)
        self.chunks.insert(0, chunk[size:]) if len(chunk) > size else None
        return chunk[:size]

    def sendall(self, data: bytes) -> None:
        self.sent.extend(data)


class _TimeoutSocket:
    def recv(self, _size: int) -> bytes:
        raise TimeoutError

    def sendall(self, _data: bytes) -> None:
        pass


def _wire_frame(can_id: int, payload: bytes, channel: int) -> bytes:
    return struct.pack(
        "<IBBBB8s", can_id, len(payload), 0, 0, 0, payload.ljust(8, b"\0")
    ) + struct.pack(
        "<i",
        channel,
    )


class ProtocolTest(unittest.TestCase):
    def test_recv_exact_preserves_fragmented_reads(self) -> None:
        source = _FragmentedSocket([b"a", b"bc", b"def"])
        self.assertEqual(recv_exact(source, 6), b"abcdef")

    def test_recv_exact_reports_short_eof(self) -> None:
        with self.assertRaisesRegex(Pc001ConnectionClosed, "2 received"):
            recv_exact(_FragmentedSocket([b"ab"]), 3)

    def test_handshake_accepts_fragmented_greeting(self) -> None:
        sock = _FragmentedSocket([b"w", b"h", b"o"])
        perform_handshake(sock)
        self.assertEqual(bytes(sock.sent), CLIENT_IDENTITY)

    def test_handshake_rejects_wrong_greeting(self) -> None:
        with self.assertRaises(Pc001HandshakeError):
            perform_handshake(_FragmentedSocket([b"bad"]))

    def test_batch_decodes_sff_eff_payload_and_channels(self) -> None:
        frames = [
            _wire_frame(0x256, bytes.fromhex("01 02"), 0),
            _wire_frame(CAN_EFF_FLAG | 0x18FF3A00, bytes.fromhex("10 20 30"), 3),
            _wire_frame(CAN_EFF_FLAG | 0x18FF5400, bytes.fromhex("AA"), 2),
        ]
        wire = struct.pack("<H", len(frames)) + b"".join(frames)
        source = _FragmentedSocket([wire[index : index + 3] for index in range(0, len(wire), 3)])
        batch = recv_batch(source)
        self.assertEqual(batch.count, 3)
        self.assertEqual(
            [
                (frame.can_id, frame.is_extended, frame.payload, frame.channel)
                for frame in batch.frames
            ],
            [
                (0x256, False, b"\x01\x02", 0),
                (0x18FF3A00, True, b"\x10\x20\x30", 3),
                (0x18FF5400, True, b"\xAA", 2),
            ],
        )

    def test_invalid_batch_count_is_rejected(self) -> None:
        with self.assertRaisesRegex(Pc001ProtocolError, "batch count"):
            recv_batch(_FragmentedSocket([b"\x00\x00"]))

    def test_handshake_timeout_is_typed(self) -> None:
        sock = _TimeoutSocket()
        with self.assertRaises(Pc001TimeoutError):
            perform_handshake(sock, timeout_s=0.01)

    def test_partial_header_and_body_timeouts_are_typed(self) -> None:
        class _PartialHeader(_TimeoutSocket):
            first = True

            def recv(self, size: int) -> bytes:
                if self.first:
                    self.first = False
                    return b"\x01"
                return super().recv(size)

        with self.assertRaises(Pc001TimeoutError):
            recv_batch(_PartialHeader(), partial_timeout_s=0.01)

        class _PartialBody(_TimeoutSocket):
            first = True

            def recv(self, size: int) -> bytes:
                if self.first:
                    self.first = False
                    return b"\x01\x00"
                return super().recv(size)

        with self.assertRaises(Pc001TimeoutError):
            recv_batch(_PartialBody(), partial_timeout_s=0.01)

    def test_invalid_dlc_channel_and_reserved_bytes_are_rejected(self) -> None:
        invalid_dlc = struct.pack("<IBBBB8s", 0x123, 9, 0, 0, 0, b"\0" * 8) + struct.pack(
            "<i", 0
        )
        with self.assertRaisesRegex(Pc001ProtocolError, "DLC"):
            decode_frame(invalid_dlc)

        with self.assertRaisesRegex(Pc001ProtocolError, "channel"):
            decode_frame(_wire_frame(0x123, b"", 1))

        invalid_reserved = struct.pack("<IBBBB8s", 0x123, 0, 1, 0, 0, b"\0" * 8) + struct.pack(
            "<i", 0
        )
        with self.assertRaisesRegex(Pc001ProtocolError, "reserved"):
            decode_frame(invalid_reserved)


if __name__ == "__main__":
    unittest.main()
