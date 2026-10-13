"""Independent RootPilot receiver layout and ordered classic-CAN transport checks."""

from __future__ import annotations

import errno
import math
import struct
import sys
import threading
import unittest
from collections import deque
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from gateway import FrameScheduler, append_frame, emit_frames, protocol_codec
from pc001_sink import TcpPc001Sink
from qml_compat import QmlCanMapper, QmlRtkState
from qml_profile import load_qml_profile
from rootpilot import COG_ID, GNSS_ID, IMU_IDS, encode_gnss, encode_imu
from sinks import SocketCanSink
from test_sinks import _FakeSocket
from test_sy155w import articulated_sample


def assemble(frames):
    assert len(frames) == 8
    assert [part[0] for part in frames] == list(range(1, 9))
    assert frames[0][1] == 51
    assert frames[-1][4:] == b"\xff" * 4
    return frames[0][2:] + b"".join(part[1:] for part in frames[1:7]) + frames[7][1:4]


class RootPilotTest(unittest.TestCase):
    def setUp(self):
        self.codec = protocol_codec("sy155w")
        self.profile = load_qml_profile("builtin:qml-sy155w-ground-truth")

    def test_rt_baseline_messages_preserved_and_only_one_imu_added(self):
        import cantools

        root = Path(__file__).resolve().parents[1] / "resources/dbc"
        for channel in ("can3", "can4"):
            reference = cantools.database.load_file(
                root / "sy135c_rt_reference" / f"{channel}.sy135c_RT.dbc"
            )
            derived = cantools.database.load_file(root / "sy155w" / f"{channel}.sy155w.dbc")
            self.assertEqual(len(derived.messages), len(reference.messages) + (channel == "can3"))
            for message in reference.messages:
                actual = derived.get_message_by_frame_id(message.frame_id)
                self.assertEqual(actual.length, message.length)
                self.assertEqual(actual.is_extended_frame, message.is_extended_frame)
                self.assertEqual(str(actual.signals), str(message.signals))

    def test_zero_angles_valid_and_signed_pitch_axis_order(self):
        self.assertEqual(encode_imu(self.codec, IMU_IDS["boom2"], (0, 0, 0)), bytes(8))
        payload = encode_imu(self.codec, IMU_IDS["boom2"], (-12.34, 56.78, -90))
        self.assertEqual(struct.unpack("<hhHBB", payload), (-1234, -5678, 27000, 0, 0))

    def test_gnss_receiver_decode_real_frames(self):
        class Capture:
            def __init__(self):
                self.frames = []

            def append(self, can_id, payload, channel):
                self.frames.append((can_id, payload, channel))

        capture = Capture()
        sample = articulated_sample(body=(12, -8, 170))
        expected = QmlCanMapper(self.profile).project(sample)
        emit_frames(
            [capture],
            FrameScheduler(dict.fromkeys(("imu", "slew", "travel", "rtk"), 50)),
            sample,
            model="sy155w",
            qml_mapper=QmlCanMapper(self.profile),
        )
        self.assertEqual(len(capture.frames), 15)
        self.assertTrue(all(len(payload) == 8 for _, payload, _ in capture.frames))
        self.assertFalse(
            any(can_id in (0x18FFF000, 0x18FF3F00, 0x0CFDA000) for can_id, _, _ in capture.frames)
        )
        parts = [payload for can_id, payload, channel in capture.frames if can_id == GNSS_ID]
        self.assertTrue(
            all(
                channel == "ch2"
                for can_id, _, channel in capture.frames
                if can_id in (GNSS_ID, COG_ID)
            )
        )
        raw = assemble(parts)
        lat, lon, alt = struct.unpack_from(">qqq", raw, 7)
        expected_lat, expected_lon, expected_alt = expected.main_geodetic()
        self.assertAlmostEqual(lat * 1e-16, expected_lat, places=12)
        self.assertAlmostEqual(lon * 1e-16, expected_lon, places=12)
        self.assertAlmostEqual(alt * 1e-6, expected_alt, places=5)
        self.assertLessEqual(raw[0], 252)
        self.assertEqual(raw[31] & 15, 4)  # fixed RTK
        self.assertEqual(raw[32] >> 6, 1)  # safe
        cog = next(payload for can_id, payload, _ in capture.frames if can_id == COG_ID)
        self.assertEqual(cog[1], 252)  # true north + six reserved ones
        self.assertEqual(cog[6:], bytes((255, 200)))
        heading = struct.unpack_from("<H", cog, 2)[0] * 0.0001 * 180 / math.pi
        self.assertLess(abs((heading - expected.wire_heading_deg + 180) % 360 - 180), 0.003)

    def test_gnss_big_endian_date_time_and_heading_wrap(self):
        state = QmlRtkState(QmlCanMapper(self.profile).project(articulated_sample()))
        frames = encode_gnss(self.codec, state, 1000, unix_s=20000 * 86400 + 43210.1234)
        raw = frames[GNSS_ID]
        self.assertEqual(struct.unpack_from(">H", raw, 1)[0], 20000)
        self.assertEqual(struct.unpack_from(">I", raw, 3)[0], 432101234)
        self.assertEqual(raw[51:], bytes(13))
        with patch.object(QmlRtkState, "heading_degrees", return_value=359.99999):
            wrapped = encode_gnss(self.codec, state, 1000)[COG_ID]
            self.assertEqual(struct.unpack_from("<H", wrapped, 2)[0], 0)

    def virtual_payload(self):
        return bytes(range(51)) + bytes(13)

    def submit(self, sink, payload):
        append_frame(
            sink, GNSS_ID, payload, channel="ch2", source="godot", family="rtk", is_extended=True
        )

    def test_socketcan_coalesces_complete_transfer_and_recovers_after_congestion(self):
        with (
            patch("sinks.socket.socket", _FakeSocket),
            patch("sinks.socket.AF_CAN", 29, create=True),
            patch("sinks.socket.CAN_RAW", 1, create=True),
        ):
            sink = SocketCanSink()
        first = self.virtual_payload()
        second = b"\x42" + first[1:]
        self.submit(sink, first)
        self.submit(sink, second)
        self.assertEqual(sink.stats.coalesced, 8)
        sink.service()
        self.assertEqual(assemble([frame[8:16] for frame in sink.sock.sent]), second[:51])
        sink.sock.sent.clear()
        self.submit(sink, first)
        send = sink.sock.send
        calls = 0

        def congested(frame):
            nonlocal calls
            calls += 1
            if calls == 3:
                raise OSError(errno.ENOBUFS, "full")
            return send(frame)

        sink.sock.send = congested
        sink.service()
        self.assertEqual(sink.stats.pending, 0)
        self.assertEqual(sink.stats.congestion_dropped, 6)
        sink.sock.send = send
        sink.sock.sent.clear()
        self.submit(sink, second)
        sink.service()
        self.assertEqual(assemble([frame[8:16] for frame in sink.sock.sent]), second[:51])
        self.submit(sink, first)
        sink.purge(reason="model_switch")
        self.assertEqual(sink.stats.pending, 0)
        sink.close()

    def test_pc001_enqueues_whole_transfer_or_drops_whole_transfer(self):
        sink = TcpPc001Sink.__new__(TcpPc001Sink)
        sink._state = threading.Condition()
        sink._closing = False
        sink._client = object()
        sink._pending = deque()
        sink._queue_capacity = 7
        sink._dropped_queue_full = 0
        sink._dropped_no_client = 0
        self.submit(sink, self.virtual_payload())
        self.assertEqual(len(sink._pending), 0)
        self.assertEqual(sink._dropped_queue_full, 8)
        sink._queue_capacity = 8
        self.submit(sink, self.virtual_payload())
        self.assertEqual(assemble([frame.payload for frame in sink._pending]), bytes(range(51)))
