"""Dxing slew sensor PDO frame encoder (0x18FFF000).

Reference: ProtocolParser::parseDxingSlewPDO — Byte0-1 little-endian u16 angle
count (65536 counts <-> 360 deg), Byte2 STA status word (0 == valid), rest 0.
"""

from __future__ import annotations

import struct

SLEW_CAN_ID = 0x18FFF000
SLEW_COUNTS_PER_REV = 65536


def encode_slew_frame(angle_degrees: float, status: int = 0) -> bytes:
    counts = int(round((angle_degrees % 360.0) / 360.0 * SLEW_COUNTS_PER_REV)) % SLEW_COUNTS_PER_REV
    return struct.pack("<HBBBBBB", counts, status & 0xFF, 0, 0, 0, 0, 0)


def decode_slew(payload: bytes) -> tuple[float, int]:
    counts = int.from_bytes(payload[0:2], "little")
    sta = payload[2]
    return counts / SLEW_COUNTS_PER_REV * 360.0, sta
