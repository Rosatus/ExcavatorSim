"""Travel pilot pressure frame encoder (0x256, standard frame).

Reference: ProtocolParser::parseTravelHandle / decodePilotPressure — left
pressure at bytes 4-5, right at bytes 6-7, little-endian int. Values > 50
invalidate the frame; >= 8 means bodyMoving.
"""

from __future__ import annotations

import struct

TRAVEL_CAN_ID = 0x256


def encode_travel_frame(left_pressure: int, right_pressure: int) -> bytes:
    def clamp(value: int) -> int:
        return max(-32768, min(32767, int(value)))

    return struct.pack("<HHHH", 0, 0, clamp(left_pressure) & 0xFFFF, clamp(right_pressure) & 0xFFFF)


def decode_travel(payload: bytes) -> tuple[int, int]:
    left = struct.unpack("<h", payload[4:6])[0]
    right = struct.unpack("<h", payload[6:8])[0]
    return left, right


def travel_body_moving(left: int, right: int, moving_threshold_kg: int = 8, max_kg: int = 50) -> bool | None:
    """Mirror parseTravelHandle semantics; None == invalid frame."""
    if abs(left) > max_kg or abs(right) > max_kg:
        return None
    return abs(left) >= moving_threshold_kg or abs(right) >= moving_threshold_kg
