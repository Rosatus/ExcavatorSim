"""Travel pilot pressure frame encoder (0x256, standard frame).

Reference: ProtocolParser::parseTravelHandle / decodePilotPressure — left
pressure at bytes 4-5, right at bytes 6-7, little-endian UNSIGNED u16.
Physical quantity is hydraulic pilot pressure in kg; valid domain 0..50.
Values > 50 invalidate the frame; >= 8 means bodyMoving. The frame carries
no direction information — it only signals "is the body travelling".
"""

from __future__ import annotations

import struct

TRAVEL_CAN_ID = 0x256


def encode_travel_frame(left_pressure: int, right_pressure: int) -> bytes:
    def clamp(value: int) -> int:
        value = int(value)
        assert value >= 0, f"pilot pressure must be non-negative, got {value}"
        return min(50, value)

    return struct.pack("<HHHH", 0, 0, clamp(left_pressure), clamp(right_pressure))


def decode_travel(payload: bytes) -> tuple[int, int]:
    left = struct.unpack("<H", payload[4:6])[0]
    right = struct.unpack("<H", payload[6:8])[0]
    return left, right


def travel_body_moving(left: int, right: int, moving_threshold_kg: int = 8, max_kg: int = 50) -> bool | None:
    """Mirror parseTravelHandle semantics exactly; None == invalid frame."""
    if left > max_kg or right > max_kg:
        return None
    return left >= moving_threshold_kg or right >= moving_threshold_kg
