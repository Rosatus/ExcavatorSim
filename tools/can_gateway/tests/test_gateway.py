"""Golden + roundtrip tests. Run: python -m unittest discover -s tools/can_gateway/tests"""

from __future__ import annotations

import json
import math
import struct
import sys
import unittest
from pathlib import Path
from typing import ClassVar
from unittest.mock import patch

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

import gateway  # noqa: E402
from control_protocol import (  # noqa: E402
    CMD_ICT_START,
    CMD_ICT_STOP,
    CMD_RECORD_START,
    CMD_RECORD_STOP,
    CMD_SHUTDOWN,
    CMD_TIMED_CAN_START,
    HEARTBEAT_FLAG_ICT_HANDSHAKE,
    HEARTBEAT_FLAG_PLATFORM_LINUX,
    HEARTBEAT_FLAG_RECORDING,
    ICT_ERR_INTERFACE_MISSING,
    ICT_OK,
    build_control,
    build_heartbeat,
    build_ict_result,
    build_session_done,
    parse_control,
    parse_control_packet,
    parse_heartbeat,
    parse_heartbeat_flags,
    parse_ict_result,
    parse_session_done,
)
from conventions import (  # noqa: E402
    PACKET_MAGIC,
    PACKET_STRUCT,
    MachineState,
    parse_packet,
)
from csv_writer import CanapeCsvWriter  # noqa: E402
from encoders.dxg_slew import decode_slew, encode_slew_frame  # noqa: E402
from encoders.ruifen_imu import decode_ruifen_slots, encode_ruifen_frame, reported_rpy  # noqa: E402
from encoders.sinan_rtk import (  # noqa: E402
    decode_alt,
    decode_geo_int64,
    decode_heading,
    decode_status,
    decode_time,
    decode_velocity,
    encode_alt_frame,
    encode_heading_frame,
    encode_lat_frame,
    encode_lon_frame,
    encode_status_frame,
    encode_time_frame,
    encode_velocity_frame,
)
from encoders.travel_pilot import (  # noqa: E402
    decode_travel,
    encode_travel_frame,
    travel_body_moving,
)
from gateway import (  # noqa: E402
    TIMED_CAN_DURATION_S,
    TIMED_CAN_FRAME_COUNT,
    TIMED_CAN_ID,
    TIMED_CAN_PAYLOAD,
    TIMED_CAN_PERIOD_S,
    TimedCanBurst,
)

FIXTURES = Path(__file__).parent / "fixtures" / "golden_capture.json"


def golden_rows(can_id: str) -> list[bytes]:
    rows = json.loads(FIXTURES.read_text(encoding="utf-8"))[can_id]
    return [bytes.fromhex(row) for row in rows]


def make_packet(
    tick_ms: int, swing_rad: float = 0.0, left: float = 0.0, right: float = 0.0
) -> bytes:
    raw = struct.pack("<IBBHQ", PACKET_MAGIC, 1, 0, 0, tick_ms)
    for index in range(5):
        raw += struct.pack("<4f3f", 0.0, 0.0, 0.0, 1.0, float(index), 0.0, 0.0)
    raw += struct.pack("<5f", swing_rad, left, right, 0.0, 0.0)
    return raw


class RuifenGoldenTest(unittest.TestCase):
    def test_golden_decode_reencode_first_six_bytes(self) -> None:
        for can_id in ("18ff3a00", "18ff3b00", "18ff3c00", "18ff3d00"):
            for payload in golden_rows(can_id):
                slots = decode_ruifen_slots(payload)
                counts = tuple(round((s + 180.0) * 100.0) for s in slots)
                reencoded = encode_ruifen_frame(counts)
                self.assertEqual(reencoded[0:6], payload[0:6], f"{can_id}: {payload.hex()}")

    def test_full_range_roundtrip_within_quantum(self) -> None:
        for step in range(974):
            slot = max(-179.99, min(179.99, step * 0.37 - 179.99))
            encoded = encode_ruifen_frame((max(1, round((slot + 180.0) / 0.01)), 32768, 65535))
            s0 = decode_ruifen_slots(encoded)[0]
            self.assertLessEqual(abs(s0 - slot), 0.010001)

    def test_reported_rpy_matches_parser_remap(self) -> None:
        # slots(1000,20000,30000) -> s=(-170,+20,+120); remap roll=s1 pitch=-s0 yaw=s2
        roll, pitch, yaw = reported_rpy(encode_ruifen_frame((1000, 20000, 30000)))
        self.assertAlmostEqual(roll, 20.0, places=2)
        self.assertAlmostEqual(pitch, 170.0, places=2)
        self.assertAlmostEqual(yaw, 120.0, places=2)

    def test_encoder_never_emits_invalid_zero_triple(self) -> None:
        payload = encode_ruifen_frame(MachineState.sensor_slots(0.0, 179.995, 0.0))
        self.assertNotEqual(payload[0:6], b"\x00\x00\x00\x00\x00\x00")
        payload = encode_ruifen_frame(MachineState.sensor_slots(0.0, -179.995, 0.0))
        self.assertNotEqual(payload[0:6], b"\x00\x00\x00\x00\x00\x00")


class SlewGoldenTest(unittest.TestCase):
    def test_golden_decode_reencode_counts_and_sta(self) -> None:
        for payload in golden_rows("18fff000"):
            angle, sta = decode_slew(payload)
            reencoded = encode_slew_frame(angle, status=sta)
            self.assertEqual(reencoded[0:3], payload[0:3], payload.hex())

    def test_full_revolution_roundtrip_one_lsb(self) -> None:
        lsb_deg = 360.0 / 65536.0
        for step in range(50):
            deg = step * 7.31
            angle, _ = decode_slew(encode_slew_frame(deg))
            self.assertLessEqual(abs(angle - deg % 360.0) / lsb_deg, 1.0)


class RtkGoldenTest(unittest.TestCase):
    """Manual little-endian oracles reproduce the historical capture bytes."""

    CASES: ClassVar[dict[str, str]] = {
        "0cfda000": "time",
        "0cfda800": "velocity",
        "0cfda900": "heading",
        "0cfda200": "lon",
        "0cfda300": "lat",
        "0cfda500": "lon",
        "0cfda600": "lat",
        "0cfda400": "alt",
        "0cfda700": "alt",
    }

    @staticmethod
    def _codec(kind: str):
        if kind == "lon":
            return decode_geo_int64, encode_lon_frame
        if kind == "lat":
            return decode_geo_int64, encode_lat_frame
        if kind == "alt":
            return decode_alt, encode_alt_frame
        if kind == "velocity":
            return decode_velocity, lambda v: encode_velocity_frame(*v)
        if kind == "heading":
            return decode_heading, encode_heading_frame
        return decode_time, lambda v: encode_time_frame(v[0], v[1])

    def test_golden_default_encoders_reproduce_capture(self) -> None:
        for can_id, kind in self.CASES.items():
            decoder, encoder = self._codec(kind)
            for payload in golden_rows(can_id):
                decoded = decoder(payload)
                reencoded = encoder(decoded)
                self.assertEqual(reencoded.ljust(8, b"\x00"), payload.ljust(8, b"\x00"), can_id)

    def test_synthetic_values(self) -> None:
        week, seconds = decode_time(encode_time_frame(2300, 452967.891))
        self.assertEqual((week, round(seconds, 3)), (2300, 452967.891))
        status = decode_status(encode_status_frame(gps_age_cs=42))
        self.assertEqual(status["gpsAgeCs"], 42)
        self.assertEqual(status["gpsNumStatsUsed"], status["viceGpsNumStatsUsed"])
        self.assertEqual(status["satelliteStatus"], 0)
        self.assertEqual(
            decode_status(encode_status_frame(satellite_status=4))["satelliteStatus"],
            4,
        )
        lon = decode_geo_int64(encode_lon_frame(120.09331234))
        self.assertAlmostEqual(lon, 120.09331234, places=7)
        alt = decode_alt(encode_alt_frame(-12.345))
        self.assertAlmostEqual(alt, -12.345, places=3)
        vel = decode_velocity(encode_velocity_frame(1.234, -0.567, 0.001, 1.35))
        self.assertAlmostEqual(vel[0], 1.234, places=2)
        self.assertAlmostEqual(vel[1], -0.567, places=2)
        self.assertAlmostEqual(vel[3], 1.35, places=2)
        heading = decode_heading(encode_heading_frame(359.99))
        self.assertAlmostEqual(heading, 359.99, places=2)


class TravelSemanticsTest(unittest.TestCase):
    def test_forward_command_yields_moving(self) -> None:
        left, right = decode_travel(encode_travel_frame(9, 9))
        self.assertEqual((left, right), (9, 9))
        self.assertIs(travel_body_moving(left, right), True)

    def test_reverse_command_yields_moving(self) -> None:
        # Direction is not representable on this frame: reverse still emits
        # positive pressure magnitude (unsigned u16, 0..50 kg domain).
        left, right = decode_travel(encode_travel_frame(9, 9))
        self.assertIs(travel_body_moving(left, right), True)

    def test_negative_pressure_rejected(self) -> None:
        with self.assertRaises(AssertionError):
            encode_travel_frame(-9, 0)

    def test_invalid_above_50(self) -> None:
        # Raw decode of an out-of-domain frame mirrors the parser's invalid path.
        self.assertIsNone(travel_body_moving(51, 9))
        payload = encode_travel_frame(50, 9)
        left, right = decode_travel(payload)
        self.assertEqual((left, right), (50, 9))
        self.assertIs(travel_body_moving(left, right), True)

    def test_idle_yields_zero_pressure_not_moving(self) -> None:
        left, right = decode_travel(encode_travel_frame(0, 0))
        self.assertEqual((left, right), (0, 0))
        self.assertIs(travel_body_moving(left, right), False)


class PacketAndCsvTest(unittest.TestCase):
    def test_bridge_packet_roundtrip(self) -> None:
        sample = parse_packet(make_packet(12345, swing_rad=0.77, left=0.4))
        self.assertIsNotNone(sample)
        assert sample is not None
        self.assertEqual(sample.tick_ms, 12345)
        self.assertAlmostEqual(sample.bodies["boom"].origin_m[0], 2.0, places=5)
        self.assertAlmostEqual(sample.swing_rad, 0.77, places=5)
        self.assertEqual(PACKET_STRUCT.size, len(make_packet(0)))
        state = MachineState(sample)
        self.assertAlmostEqual(state.slew_degrees(), math.degrees(0.77) % 360.0, places=3)

    def test_bad_packets_rejected(self) -> None:
        self.assertIsNone(parse_packet(b"short"))
        self.assertIsNone(parse_packet(bytes(PACKET_STRUCT.size)))

    def test_csv_writer_dialect(self) -> None:
        path = Path(__file__).parent / "_tmp_dialect.csv"
        writer = CanapeCsvWriter(path)
        writer.append(0x18FF3A00, bytes.fromhex("9C278A46F24769 00".replace(" ", "")))
        writer.append(0x256, bytes(8))
        writer.close()
        lines = path.read_text(encoding="utf-8-sig").strip().splitlines()
        self.assertEqual(lines[0].split(",")[0], "\u5e8f\u53f7")
        fields = lines[1].split(",")
        self.assertEqual(fields[0], "00000")
        self.assertTrue(fields[1].startswith('="') and fields[1].endswith('"'))
        self.assertEqual(fields[5], "0x18FF3A00")
        self.assertEqual(fields[7], "\u6269\u5c55\u5e27")
        self.assertEqual(fields[9].strip(), "x| 9C 27 8A 46 F2 47 69 00")
        fields2 = lines[2].split(",")
        self.assertEqual(fields2[5], "0x256")
        self.assertEqual(fields2[7], "\u6807\u51c6\u5e27")
        path.unlink()

    def test_csv_loadable_by_dev_arch_reader(self) -> None:
        reader_path = Path("E:/projects/dev_arch2.0_36b5586c/tools/can_replay/csv_parser.py")
        if not reader_path.exists():
            self.skipTest("dev_arch2.0 repo not available")
        sys.path.insert(0, str(reader_path.parent))
        try:
            from csv_parser import read_can_csv  # type: ignore
        finally:
            sys.path.remove(str(reader_path.parent))
        path = Path(__file__).parent / "_tmp_reader.csv"
        writer = CanapeCsvWriter(path)
        for can_id in (0x18FF3A00, 0x256, 0x18FFF000):
            writer.append(can_id, bytes(range(1, 9)))
        writer.close()
        frames = read_can_csv(str(path))
        eff_mask = 0x1FFFFFFF
        self.assertEqual([f.can_id & eff_mask for f in frames], [0x18FF3A00, 0x256, 0x18FFF000])
        self.assertTrue(frames[0].is_extended and not frames[1].is_extended)
        self.assertEqual(frames[0].data, bytes(range(1, 9)))
        path.unlink()


class ControlProtocolTest(unittest.TestCase):
    def test_control_roundtrip(self) -> None:
        for cmd in (
            CMD_RECORD_START,
            CMD_RECORD_STOP,
            CMD_SHUTDOWN,
            CMD_ICT_START,
            CMD_ICT_STOP,
            CMD_TIMED_CAN_START,
        ):
            self.assertEqual(parse_control(build_control(cmd, seq=7)), cmd)
            self.assertEqual(parse_control_packet(build_control(cmd, seq=7)), (cmd, 7))

    def test_control_rejects_garbage(self) -> None:
        self.assertIsNone(parse_control(b"short"))
        self.assertIsNone(parse_control(bytes(12)))
        self.assertIsNone(parse_control(build_control(99)))

    def test_heartbeat_roundtrip_and_flags(self) -> None:
        idle = parse_heartbeat(build_heartbeat(1234, recording=False))
        rec = parse_heartbeat(build_heartbeat(5678, recording=True))
        self.assertEqual(idle, (False, 1234))
        self.assertEqual(rec, (True, 5678))
        self.assertIsNone(parse_heartbeat(b"x" * 15))
        self.assertIsNone(parse_heartbeat(bytes(16)))

    def test_heartbeat_platform_flag(self) -> None:
        win = parse_heartbeat_flags(build_heartbeat(10, False, False))
        linux = parse_heartbeat_flags(build_heartbeat(20, True, True))
        self.assertEqual(win, (False, False, 10))
        self.assertEqual(linux, (True, True, 20))
        # legacy 2-tuple parser ignores platform bit
        self.assertEqual(parse_heartbeat(build_heartbeat(20, True, True)), (True, 20))
        raw = build_heartbeat(1, False, True)
        flags = struct.unpack("<IBBHQ", raw)[2]
        self.assertEqual(flags & HEARTBEAT_FLAG_PLATFORM_LINUX, HEARTBEAT_FLAG_PLATFORM_LINUX)
        self.assertEqual(flags & HEARTBEAT_FLAG_RECORDING, 0)

    def test_heartbeat_ict_handshake_flag_is_additive(self) -> None:
        raw = build_heartbeat(30, False, False, True)
        self.assertEqual(len(raw), 16)
        flags = struct.unpack("<IBBHQ", raw)[2]
        self.assertEqual(flags & HEARTBEAT_FLAG_ICT_HANDSHAKE, HEARTBEAT_FLAG_ICT_HANDSHAKE)
        self.assertEqual(parse_heartbeat(raw), (False, 30))
        self.assertEqual(parse_heartbeat_flags(raw), (False, False, 30))

    def test_session_done_roundtrip(self) -> None:
        path = "E:/dir/can_telemetry_20260825_120000.csv"
        payload = build_session_done(path)
        self.assertEqual(parse_session_done(payload), path)
        self.assertIsNone(parse_session_done(b"tiny"))
        self.assertIsNone(parse_session_done(bytes(16)))

    def test_ict_result_roundtrip_and_validation(self) -> None:
        success = build_ict_result(42, ICT_OK)
        failure = build_ict_result(43, ICT_ERR_INTERFACE_MISSING, "can0 missing")
        self.assertEqual(parse_ict_result(success), (42, ICT_OK, ""))
        self.assertEqual(
            parse_ict_result(failure),
            (43, ICT_ERR_INTERFACE_MISSING, "can0 missing"),
        )
        self.assertIsNone(parse_ict_result(failure[:-1]))
        self.assertIsNone(parse_ict_result(bytes(14)))
        with self.assertRaises(ValueError):
            build_ict_result(1, ICT_OK, "x" * 161)


class _CaptureSink:
    def __init__(self) -> None:
        self.frames: list[tuple[int, bytes]] = []

    def append(self, can_id: int, payload: bytes) -> None:
        self.frames.append((can_id, payload))

    def close(self) -> None:
        pass

    def peer_name(self) -> str:
        return "capture"


class VcanCompatibilityTest(unittest.TestCase):
    def test_missing_vcan_is_prepared_before_socket_bind(self) -> None:
        events: list[tuple[str, str]] = []

        def ensure(interface: str) -> None:
            events.append(("ensure", interface))

        class FakeSocketCanSink:
            def __init__(self, interface: str, **_kwargs) -> None:
                events.append(("bind", interface))

        with (
            patch.object(gateway, "ensure_vcan_interface", side_effect=ensure),
            patch.object(gateway, "SocketCanSink", FakeSocketCanSink),
        ):
            sink = gateway._open_vcan("vcan0")

        self.assertIsNotNone(sink)
        self.assertEqual(events, [("ensure", "vcan0"), ("bind", "vcan0")])


class TimedCanBurstTest(unittest.TestCase):
    def test_uninterrupted_virtual_time_emits_exactly_500_frames(self) -> None:
        burst = TimedCanBurst()
        sink = _CaptureSink()
        burst.trigger(10.0)
        for slot in range(TIMED_CAN_FRAME_COUNT):
            now_s = 10.0 + slot * TIMED_CAN_PERIOD_S
            self.assertTrue(burst.service(now_s, [sink]))
        self.assertFalse(burst.active)
        self.assertEqual(len(sink.frames), TIMED_CAN_FRAME_COUNT)
        self.assertEqual(set(sink.frames), {(TIMED_CAN_ID, TIMED_CAN_PAYLOAD)})

    def test_retrigger_replaces_remaining_window_without_overlap(self) -> None:
        burst = TimedCanBurst()
        sink = _CaptureSink()
        burst.trigger(1.0)
        self.assertTrue(burst.service(1.0, [sink]))
        self.assertFalse(burst.service(1.01, [sink]))
        burst.trigger(1.01)
        self.assertEqual(burst.emitted_count, 0)
        self.assertTrue(burst.service(1.01, [sink]))
        self.assertFalse(burst.service(1.02, [sink]))
        self.assertTrue(burst.service(1.03, [sink]))
        self.assertEqual(len(sink.frames), 3)

    def test_one_slot_fans_out_to_every_active_sink(self) -> None:
        burst = TimedCanBurst()
        recording = _CaptureSink()
        ict = _CaptureSink()
        burst.trigger(0.0)
        self.assertTrue(burst.service(0.0, [recording, ict]))
        expected = [(TIMED_CAN_ID, TIMED_CAN_PAYLOAD)]
        self.assertEqual(recording.frames, expected)
        self.assertEqual(ict.frames, expected)

    def test_late_service_does_not_emit_catchup_burst(self) -> None:
        burst = TimedCanBurst()
        sink = _CaptureSink()
        burst.trigger(0.0)
        self.assertTrue(burst.service(0.0, [sink]))
        self.assertTrue(burst.service(1.0, [sink]))
        self.assertEqual(len(sink.frames), 2)
        self.assertAlmostEqual(burst.timeout_s(1.0), TIMED_CAN_PERIOD_S)
        self.assertFalse(burst.service(TIMED_CAN_DURATION_S, [sink]))
        self.assertFalse(burst.active)
        self.assertEqual(len(sink.frames), 2)

    def test_disarm_discards_schedule_and_never_auto_resumes(self) -> None:
        burst = TimedCanBurst()
        sink = _CaptureSink()
        burst.trigger(0.0)
        self.assertTrue(burst.service(0.0, [sink]))
        burst.disarm()
        self.assertFalse(burst.active)
        self.assertFalse(burst.service(1.0, [sink]))
        self.assertEqual(len(sink.frames), 1)


class MachineStateSemanticTest(unittest.TestCase):
    def test_sensor_slots_invert_parser_remap(self) -> None:
        from encoders.ruifen_imu import encode_ruifen_frame as encode

        slots = MachineState.sensor_slots(10.0, -20.0, 30.0)
        roll, pitch, yaw = reported_rpy(encode(slots))
        self.assertAlmostEqual(roll, 10.0, places=2)
        self.assertAlmostEqual(pitch, -20.0, places=2)
        self.assertAlmostEqual(yaw, 30.0, places=2)

    def test_travel_pressures_magnitude_only(self) -> None:
        # Any |speed| >= epsilon yields positive pressure regardless of
        # direction; the 0x256 frame does not encode direction.
        state = MachineState(parse_packet(make_packet(1, left=0.5, right=-0.4)))
        self.assertEqual(state.travel_pressures(), (9, 9))
        idle = MachineState(parse_packet(make_packet(2, left=0.01, right=-0.02)))
        self.assertEqual(idle.travel_pressures(), (0, 0))

    def test_geodetic_offset_direction(self) -> None:
        state = MachineState(parse_packet(make_packet(1)))
        lat, lon, alt = state.geodetic()
        self.assertAlmostEqual(lat, 30.8675, places=6)
        self.assertAlmostEqual(lon, 120.0933, places=6)
        self.assertAlmostEqual(alt, 3.0, places=4)
        heading = state.heading_degrees()
        self.assertTrue(0.0 <= heading < 360.0)


if __name__ == "__main__":
    unittest.main()
