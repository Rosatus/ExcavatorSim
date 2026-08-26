"""Tests for frame sinks. Run: python -m unittest discover -s tools/can_gateway/tests"""

from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from csv_writer import CanapeCsvWriter  # noqa: E402
from sinks import CsvFrameSink, SocketCanSink, pack_can_frame  # noqa: E402


class PackCanFrameTest(unittest.TestCase):
    def test_16_byte_layout(self):
        frame = pack_can_frame(0x256, b"\x01\x02\x03\x04\x05\x06\x07\x08")
        self.assertEqual(len(frame), 16)
        can_id, dlc, pad, res0, len8, data = struct.unpack("<IBBBB8s", frame)
        self.assertEqual(can_id, 0x256)
        self.assertEqual(dlc, 8)
        self.assertEqual((pad, res0, len8), (0, 0, 0))
        self.assertEqual(data, b"\x01\x02\x03\x04\x05\x06\x07\x08")

    def test_short_payload_padded(self):
        data = struct.unpack("<IBBBB8s", pack_can_frame(0x123, b"\xaa"))[5]
        self.assertEqual(data[:1], b"\xaa")
        self.assertTrue(all(b == 0 for b in data[1:]))

    def test_extended_id_masked_to_sff(self):
        can_id = struct.unpack("<I", pack_can_frame(0x18FFF000 | 0x1FFF0000, b"")[:4])[0]
        self.assertLessEqual(can_id, 0x7FF)


class CsvFrameSinkTest(unittest.TestCase):
    def test_wraps_writer(self):
        with tempfile.TemporaryDirectory() as tmp:
            writer = CanapeCsvWriter(Path(tmp) / "out.csv")
            sink = CsvFrameSink(writer)
            payload = bytes(range(8))
            sink.append(0x256, payload)
            sink.close()
            self.assertEqual(sink.row_count, 1)
            body = Path(sink.path).read_text(encoding="utf-8-sig").splitlines()
            self.assertIn("x| " + payload.hex(" ").upper(), body[1])


class _FakeSocket:
    def __init__(self, *args, **kwargs):
        self.bound = None
        self.sent: list[bytes] = []
        self.closed = False

    def bind(self, interface_tuple):
        self.bound = interface_tuple

    def send(self, data):
        self.sent.append(data)

    def close(self):
        self.closed = True


class SocketCanSinkTest(unittest.TestCase):
    def setUp(self):
        import sinks as sinks_mod
        self._sinks = sinks_mod

    def _patch_socket(self, factory):
        original = self._sinks.socket.socket
        self._sinks.socket.socket = factory
        self.addCleanup(setattr, self._sinks.socket, "socket", original)
        # also patch AF_CAN/CAN_RAW for Windows (absent there)
        has_af_can = hasattr(self._sinks.socket, "AF_CAN")
        if not has_af_can:
            self._sinks.socket.AF_CAN = 29
            self._sinks.socket.CAN_RAW = 1
            def restore():
                del self._sinks.socket.AF_CAN
                del self._sinks.socket.CAN_RAW
            self.addCleanup(restore)

    def test_append_sends_packed_frame(self):
        fake = _FakeSocket()
        self._patch_socket(lambda *a, **k: fake)

    def test_af_can_unavailable_message(self):
        class SocketFail:
            def __init__(self, *args, **kwargs):
                raise OSError(95, "Operation not supported")

        self._patch_socket(SocketFail)
        with self.assertRaises(RuntimeError) as ctx:
            SocketCanSink("vcan0", setup_check=False)
        self.assertIn("AF_CAN", str(ctx.exception))

    def test_bind_failure_guidance(self):
        class BindFail(_FakeSocket):
            def bind(self, interface_tuple):
                raise OSError(19, "No such device")

        self._patch_socket(lambda *a, **k: BindFail())
        with self.assertRaises(RuntimeError) as ctx:
            SocketCanSink("vcan99", setup_check=False)
        self.assertIn("--setup-vcan", str(ctx.exception))


if __name__ == "__main__":
    unittest.main()
