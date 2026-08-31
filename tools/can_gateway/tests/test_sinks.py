"""Tests for frame sinks. Run: python -m unittest discover -s tools/can_gateway/tests"""

from __future__ import annotations

import errno
import struct
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from csv_writer import CanapeCsvWriter  # noqa: E402
from sinks import (  # noqa: E402
    CAN_EFF_FLAG,
    SOCKETCAN_MAX_PENDING_IDS,
    CsvFrameSink,
    SocketCanSink,
    pack_can_frame,
)


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

    def test_extended_id_preserves_29_bits_and_sets_eff_flag(self):
        for raw_id in (0x800, 0x0CFDA000, 0x18FF3A00, 0x18FFF000, 0x18FFF100, 0x1FFFFFFF):
            can_id = struct.unpack("<I", pack_can_frame(raw_id, b"")[:4])[0]
            self.assertEqual(can_id, raw_id | CAN_EFF_FLAG)

    def test_standard_and_already_flagged_ids_are_preserved(self):
        self.assertEqual(struct.unpack("<I", pack_can_frame(0x7FF, b"")[:4])[0], 0x7FF)
        flagged = CAN_EFF_FLAG | 0x18FF3A00
        self.assertEqual(struct.unpack("<I", pack_can_frame(flagged, b"")[:4])[0], flagged)


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

    def test_timed_extended_frame_keeps_raw_csv_id(self):
        with tempfile.TemporaryDirectory() as tmp:
            writer = CanapeCsvWriter(Path(tmp) / "out.csv")
            sink = CsvFrameSink(writer)
            sink.append(0x18FFF100, bytes.fromhex("01 00 00 00 00 00 00 00"))
            sink.close()
            fields = Path(sink.path).read_text(encoding="utf-8-sig").splitlines()[1].split(",")
            self.assertEqual(fields[5], "0x18FFF100")
            self.assertEqual(fields[7], "扩展帧")
            self.assertEqual(fields[9].strip(), "x| 01 00 00 00 00 00 00 00")


class _FakeSocket:
    def __init__(self, *args, **kwargs):
        self.bound = None
        self.sent: list[bytes] = []
        self.closed = False
        self.blocking = True

    def setblocking(self, blocking):
        self.blocking = blocking

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
        sink = SocketCanSink("can0")
        sink.append(0x18FF3A00, b"\x01" * 8)
        self.assertFalse(fake.blocking)
        self.assertEqual(sink.stats.pending, 1)
        sink.service()
        self.assertEqual(struct.unpack("<I", fake.sent[0][:4])[0], CAN_EFF_FLAG | 0x18FF3A00)
        self.assertEqual(sink.stats.sent, 1)
        sink.close()

    def test_af_can_unavailable_message(self):
        class SocketFail:
            def __init__(self, *args, **kwargs):
                raise OSError(95, "Operation not supported")

        self._patch_socket(SocketFail)
        with self.assertRaises(RuntimeError) as ctx:
            SocketCanSink("can0")
        self.assertIn("AF_CAN", str(ctx.exception))

    def test_bind_failure_guidance(self):
        class BindFail(_FakeSocket):
            def bind(self, interface_tuple):
                raise OSError(19, "No such device")

        self._patch_socket(lambda *a, **k: BindFail())
        with self.assertRaises(RuntimeError) as ctx:
            SocketCanSink("can0")
        self.assertIn("configured for the CAN bus", str(ctx.exception))

    def test_recoverable_send_failures_drop_without_latching_terminal_error(self):
        class SendFail(_FakeSocket):
            def __init__(self, error_number):
                super().__init__()
                self.error_number = error_number

            def send(self, data):
                raise OSError(self.error_number, "congested")

        for error_number in {errno.ENOBUFS, errno.EAGAIN, errno.EWOULDBLOCK}:
            with self.subTest(error_number=error_number):
                fake = SendFail(error_number)
                self._patch_socket(lambda *a, fake=fake, **k: fake)
                sink = SocketCanSink("can0")
                sink.append(0x18FFF100, bytes(8))
                self.assertEqual(sink.service(), 1)
                self.assertIsNone(sink.last_send_error)
                self.assertEqual(sink.stats.congestion_dropped, 1)
                self.assertEqual(sink.stats.pending, 0)
                sink.close()

    def test_terminal_send_failure_is_latched(self):
        class SendFail(_FakeSocket):
            def send(self, data):
                raise OSError(errno.ENETDOWN, "Network is down")

        fake = SendFail()
        self._patch_socket(lambda *a, **k: fake)
        sink = SocketCanSink("can0")
        sink.append(0x18FFF100, bytes(8))
        sink.service()
        self.assertEqual(sink.last_send_error.errno, errno.ENETDOWN)
        self.assertEqual(sink.stats.terminal_error, 1)
        sink.close()

    def test_same_id_coalesces_to_latest_payload(self):
        fake = _FakeSocket()
        self._patch_socket(lambda *a, **k: fake)
        outcomes = []
        sink = SocketCanSink("can0")
        sink.set_outcome_observer(outcomes.append)
        sink.submit(0x123, b"old", source="godot", family="imu")
        sink.submit(0x123, b"new", source="godot", family="imu")
        self.assertEqual(sink.stats.submitted, 2)
        self.assertEqual(sink.stats.coalesced, 1)
        self.assertEqual(sink.stats.pending, 1)
        sink.service()
        self.assertEqual(struct.unpack("<IBBBB8s", fake.sent[0])[-1][:3], b"new")
        self.assertEqual(
            [item.outcome for item in outcomes], ["submitted", "submitted", "coalesced", "sent"]
        )

    def test_low_numeric_sff_and_eff_ids_keep_distinct_pending_slots(self):
        fake = _FakeSocket()
        self._patch_socket(lambda *a, **k: fake)
        sink = SocketCanSink("can0")
        sink.submit(
            0x123,
            b"sff",
            source="web",
            family="dbc",
            is_extended=False,
        )
        sink.submit(
            0x123,
            b"eff",
            source="web",
            family="dbc",
            is_extended=True,
        )
        self.assertEqual(sink.stats.pending, 2)
        self.assertEqual(sink.stats.coalesced, 0)
        sink.service(maximum=2)
        sent_ids = {struct.unpack("<I", frame[:4])[0] for frame in fake.sent}
        self.assertEqual(sent_ids, {0x123, CAN_EFF_FLAG | 0x123})

    def test_purge_matches_full_sff_eff_identity(self):
        fake = _FakeSocket()
        self._patch_socket(lambda *a, **k: fake)
        sink = SocketCanSink("can0")
        sink.submit(0x123, b"sff", source="web", family="dbc", is_extended=False)
        sink.submit(0x123, b"eff", source="web", family="dbc", is_extended=True)
        self.assertEqual(
            sink.purge(can_id=0x123, is_extended=True, reason="authority_change"),
            1,
        )
        sink.service()
        self.assertEqual(struct.unpack("<I", fake.sent[0][:4])[0], 0x123)

    def test_pending_ids_are_bounded_and_capacity_drop_keeps_existing_values(self):
        fake = _FakeSocket()
        self._patch_socket(lambda *a, **k: fake)
        sink = SocketCanSink("can0")
        for can_id in range(SOCKETCAN_MAX_PENDING_IDS):
            sink.submit(can_id, bytes([can_id & 0xFF]), source="web", family="dbc")
        sink.submit(0x1000, b"overflow", source="web", family="dbc")
        self.assertEqual(sink.stats.pending, SOCKETCAN_MAX_PENDING_IDS)
        self.assertEqual(sink.stats.congestion_dropped, 1)
        self.assertEqual(sink.service(maximum=32), 32)
        self.assertEqual(len(fake.sent), 32)

    def test_family_round_robin_prevents_low_rate_starvation(self):
        fake = _FakeSocket()
        self._patch_socket(lambda *a, **k: fake)
        sink = SocketCanSink("can0")
        for can_id in range(10, 20):
            sink.submit(can_id, bytes([can_id]), source="godot", family="imu")
        sink.submit(0x200, b"rtk", source="godot", family="rtk")
        sink.submit(0x201, b"travel", source="godot", family="travel")
        sink.service(maximum=3)
        sent_ids = [struct.unpack("<I", frame[:4])[0] for frame in fake.sent]
        self.assertEqual(sent_ids, [10, 0x200, 0x201])

    def test_replacement_can_migrate_between_families_without_duplicate_slots(self):
        fake = _FakeSocket()
        self._patch_socket(lambda *a, **k: fake)
        sink = SocketCanSink("can0")
        sink.submit(0x100, b"old", source="godot", family="imu")
        sink.submit(0x100, b"new", source="web", family="dbc")
        sink.submit(0x101, b"imu", source="godot", family="imu")
        self.assertEqual(sink.stats.pending, 2)
        sink.service(maximum=2)
        sent_ids = [struct.unpack("<I", frame[:4])[0] for frame in fake.sent]
        self.assertEqual(sent_ids, [0x100, 0x101])
        self.assertEqual(struct.unpack("<IBBBB8s", fake.sent[0])[-1][:3], b"new")

    def test_congestion_yields_after_one_syscall_and_csv_remains_complete(self):
        class CongestedSocket(_FakeSocket):
            def send(self, data):
                raise OSError(errno.ENOBUFS, "No buffer space available")

        fake = CongestedSocket()
        self._patch_socket(lambda *a, **k: fake)
        socketcan = SocketCanSink("can0")
        with tempfile.TemporaryDirectory() as tmp:
            csv = CsvFrameSink(CanapeCsvWriter(Path(tmp) / "out.csv"))
            for can_id in range(5):
                payload = bytes([can_id]) * 8
                csv.append(can_id, payload)
                socketcan.submit(can_id, payload, source="godot", family="imu")
            self.assertEqual(socketcan.service(maximum=32), 1)
            self.assertIsNone(socketcan.last_send_error)
            self.assertEqual(socketcan.stats.pending, 4)
            self.assertEqual(csv.row_count, 5)
            csv.close()

    def test_generation_purge_prevents_late_timed_send(self):
        fake = _FakeSocket()
        self._patch_socket(lambda *a, **k: fake)
        sink = SocketCanSink("can0")
        sink.submit(
            0x18FFF100,
            bytes.fromhex("01 00 00 00 00 00 00 00"),
            source="timed",
            family="timed",
            generation=7,
        )
        self.assertEqual(sink.purge(generation=7, reason="deadline"), 1)
        sink.service()
        self.assertEqual(fake.sent, [])
        self.assertEqual(sink.stats.congestion_dropped, 1)


if __name__ == "__main__":
    unittest.main()
