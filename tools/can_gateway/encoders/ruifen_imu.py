"""Ruifen IMU RPY extended frame encoder (18FF3A00/3B00/3C00/3D00).

Reference: ProtocolParser::parseVg325eRpyEx — each axis is a little-endian
u16 count, value = count * 0.01 - 180 deg. A triple of zero counts is the
parser's invalid marker, so the encoder never emits zero.
"""

from __future__ import annotations

import struct

RUFINEN_IDS = {"body": 0x18FF3A00, "boom": 0x18FF3B00, "arm": 0x18FF3C00, "bucket": 0x18FF3D00}


def encode_ruifen_frame(slot_counts: tuple[int, int, int]) -> bytes:
    s0, s1, s2 = (max(1, min(int(c), 65535)) for c in slot_counts)
    return struct.pack("<HHH2x", s0, s1, s2)


def decode_ruifen_slots(payload: bytes) -> tuple[float, float, float]:
    """Reference decoder (protocolparser.cpp parity, for tests)."""
    s0 = int.from_bytes(payload[0:2], "little") * 0.01 - 180.0
    s1 = int.from_bytes(payload[2:4], "little") * 0.01 - 180.0
    s2 = int.from_bytes(payload[4:6], "little") * 0.01 - 180.0
    return s0, s1, s2


def reported_rpy(payload: bytes) -> tuple[float, float, float]:
    """Apply the parser's mounting remap: roll=s1, pitch=-s0, yaw=s2."""
    s0, s1, s2 = decode_ruifen_slots(payload)
    return s1, -s0, s2
