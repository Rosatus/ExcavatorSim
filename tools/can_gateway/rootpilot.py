"""SY135C_RT wire projection and RootPilot's fixed eight-fragment GNSS transport."""

from __future__ import annotations

import math
import time

IMU_IDS = dict(
    zip(
        ("body", "boom", "arm", "bucket", "boom2"),
        (0x18F00000, 0x18F10000, 0x18F20000, 0x18F30000, 0x18F40000),
        strict=True,
    )
)
COG_ID = 0x09F80230
GNSS_ID = 0x09F80530


def gnss_fragments(payload: bytes) -> tuple[bytes, ...]:
    """Receiver uses sequence 1..8, NOT standard N2K transfer-ID/index bits."""
    if len(payload) != 64 or any(payload[51:]):
        raise ValueError("RootPilot requires a 51-byte payload in a zero-padded 64-byte buffer")
    data = payload[:51]
    return (
        b"\x01\x33" + data[:6],
        *(
            (bytes([index + 2]) + data[6 + index * 7 : 13 + index * 7]).ljust(8, b"\xff")
            for index in range(7)
        ),
    )


def encode_imu(codec, frame_id: int, rpy: tuple[float, float, float]) -> bytes:
    roll, pitch, yaw = rpy
    # Parser: roll=DBC Roll, pitch=-DBC Pitch, yaw=DBC Yaw. Zero is valid.
    return codec.encode_frame(
        frame_id,
        {
            "Roll_Angle": ((round(roll * 100) + 18000) % 36000 - 18000) / 100,
            "Pitch_Angle": ((round(-pitch * 100) + 18000) % 36000 - 18000) / 100,
            "Yaw_Angle": (round(yaw * 100) % 36000) / 100,
            "Reserved_1": 0,
            "Reserved_2": 0,
        },
    )


def encode_gnss(codec, state, tick_ms: int, *, unix_s: float | None = None):
    now = time.time() if unix_s is None else unix_s
    sid = (tick_ms // 100) % 253
    lat, lon, alt = state.geodetic()
    _, _, _, speed = state.velocity_enu()
    # The supplier confirms COG carries computed equipment heading, even at rest.
    heading = round(math.radians(state.heading_degrees() % 360) / 0.0001) % 62832
    cog = codec.encode_frame(
        COG_ID,
        {
            "Sequence_ID": sid,
            "COG_Reference": 0,
            "NMEA_Reserved_1": 63,
            "Course_Over_Ground": heading * 0.0001,
            "Speed_Over_Ground": speed,
            "NMEA_Reserved_2": 255,
            "Sol_Status": 0,
            "Pos_Type": 50,
        },
    )
    position = codec.encode_frame(
        GNSS_ID,
        {
            "Sequence_ID": sid,
            "Position_Date": int(now // 86400),
            "Position_Time": now % 86400,
            "Latitude": lat,
            "Longitude": lon,
            "Altitude": alt,
            "Type_of_System": 5,
            "Method_GNSS": 4,
            "Integrity": 1,
            "NMEA_Reserved": 63,
            "Number_of_SVs": 18,
            "HDOP": 0.8,
            "PDOP": 1.2,
            "Geoidal_Separation": 0,
            "Number_of_Reference_Stations": 1,
            "Reference_Station_Type_1": 0,
            "Reference_Station_ID_1": 0,
            "Age_of_DGNSS_Corrections_1": 0.12,
            "Heading_Standard_Deviation": 0.01,
        },
    )
    gnss_fragments(position)  # Validate before any frame can reach a sink.
    return {COG_ID: cog, GNSS_ID: position}
