"""Sinan CGI610 RTK frame family encoders (0x0CFDA000..A900).

Byte layouts default to the historical gateway product decision: the whole
family is LITTLE-endian, including velocity. QML compatibility mode overrides
only A800 velocity to BIG-endian because the immutable ProtocolParser reads its
four i16 fields in network order:

- LITTLE-endian: GPS week, GPS time-of-week ms, gps age,
  lon/lat int64 (1e8), altitude int32 (mm), heading u16 (1e-2 deg),
  velocity ve/vn/vu/v as 4 x i16 (1e-2 m/s)

Encoders and decoders accept explicit byte order for cross-checks.
"""

from __future__ import annotations

import struct

RTK_IDS_ORDERED = (
    0x0CFDA000,
    0x0CFDA100,
    0x0CFDA200,
    0x0CFDA300,
    0x0CFDA400,
    0x0CFDA500,
    0x0CFDA600,
    0x0CFDA700,
    0x0CFDA800,
    0x0CFDA900,
)

# Synthetic-but-plausible fix quality.
_STATUS_SYSTEM_FIX = 2
_STATUS_SATS_SEARCHED = 24
_STATUS_SATS_USED = 18


def _endian(byteorder: str) -> str:
    return "<" if byteorder == "little" else ">"


def encode_time_frame(week: int, gps_seconds: float) -> bytes:
    ms = round(gps_seconds * 1000.0) & 0xFFFFFFFF
    return struct.pack("<HI2x", week & 0xFFFF, ms)


def encode_status_frame(gps_age_cs: int = 12, satellite_status: int = 0) -> bytes:
    if not 0 <= satellite_status <= 0xFF:
        raise ValueError("satellite_status must fit uint8")
    return struct.pack(
        "<BBBBHBB",
        _STATUS_SYSTEM_FIX,
        _STATUS_SATS_USED,
        satellite_status,
        _STATUS_SATS_USED,
        gps_age_cs & 0xFFFF,
        _STATUS_SATS_SEARCHED,
        _STATUS_SATS_SEARCHED,
    )


def encode_lon_frame(lon_deg: float, byteorder: str = "little") -> bytes:
    return struct.pack(f"{_endian(byteorder)}q", round(lon_deg * 1e8))


def encode_lat_frame(lat_deg: float, byteorder: str = "little") -> bytes:
    return struct.pack(f"{_endian(byteorder)}q", round(lat_deg * 1e8))


def encode_alt_frame(alt_m: float, byteorder: str = "little") -> bytes:
    return struct.pack(f"{_endian(byteorder)}i4x", round(alt_m * 1000.0))


def encode_velocity_frame(
    ve: float, vn: float, vu: float, speed: float, byteorder: str = "little"
) -> bytes:
    def centi(value: float) -> int:
        return max(-32768, min(32767, round(value * 100.0)))

    return struct.pack(f"{_endian(byteorder)}hhhh", centi(ve), centi(vn), centi(vu), centi(speed))


def encode_heading_frame(heading_deg: float, byteorder: str = "little") -> bytes:
    counts = round((heading_deg % 360.0) * 100.0) & 0xFFFF
    return struct.pack(f"{_endian(byteorder)}H6x", counts)


# ---- reference decoders (protocolparser.cpp parity, for tests) ----


def decode_time(payload: bytes) -> tuple[int, float]:
    week = int.from_bytes(payload[0:2], "little")
    ms = int.from_bytes(payload[2:6], "little")
    return week, ms * 0.001


def decode_status(payload: bytes) -> dict[str, int]:
    return {
        "systemStatus": payload[0],
        "gpsNumStatsUsed": payload[1],
        "satelliteStatus": payload[2],
        "viceGpsNumStatsUsed": payload[3],
        "gpsAgeCs": int.from_bytes(payload[4:6], "little"),
        "gpsNumSats": payload[6],
        "viceGpsNumSats": payload[7],
    }


def decode_geo_int64(payload: bytes, byteorder: str = "little") -> float:
    return int.from_bytes(payload[0:8], byteorder, signed=True) / 1e8


def decode_alt(payload: bytes, byteorder: str = "little") -> float:
    return int.from_bytes(payload[0:4], byteorder, signed=True) * 0.001


def decode_velocity(payload: bytes, byteorder: str = "little") -> tuple[float, float, float, float]:
    fmt = struct.Struct(f"{_endian(byteorder)}hhhh")
    return tuple(v * 0.01 for v in fmt.unpack(payload[0:8]))


def decode_heading(payload: bytes, byteorder: str = "little") -> float:
    return int.from_bytes(payload[0:2], byteorder) * 0.01


GPS_WEEK_EPOCH_OFFSET_S = 315964800  # Unix seconds at GPS epoch 1980-01-06.


def build_rtk_frames(
    state,
    byteorder: str = "little",
    satellite_status: int = 0,
    velocity_byteorder: str | None = None,
) -> dict[int, bytes]:
    """Assemble the full A000..A900 family from a conventions.MachineState."""
    lat, lon, alt = state.geodetic()
    vlat, vlon, valt = state.vice_antenna_geodetic()
    heading = state.heading_degrees()
    ve, vn, vu, speed = state.velocity_enu()
    unix_s = (
        state.wall_clock_unix_s() if hasattr(state, "wall_clock_unix_s") else _default_wall_clock()
    )
    gps_week = int((unix_s - GPS_WEEK_EPOCH_OFFSET_S) // (7 * 86400))
    week_ms_in_week = (unix_s - GPS_WEEK_EPOCH_OFFSET_S) % (7 * 86400)
    return {
        RTK_IDS_ORDERED[0]: encode_time_frame(gps_week, week_ms_in_week),
        RTK_IDS_ORDERED[1]: encode_status_frame(satellite_status=satellite_status),
        RTK_IDS_ORDERED[2]: encode_lon_frame(lon, byteorder),
        RTK_IDS_ORDERED[3]: encode_lat_frame(lat, byteorder),
        RTK_IDS_ORDERED[4]: encode_alt_frame(alt, byteorder),
        RTK_IDS_ORDERED[5]: encode_lon_frame(vlon, byteorder),
        RTK_IDS_ORDERED[6]: encode_lat_frame(vlat, byteorder),
        RTK_IDS_ORDERED[7]: encode_alt_frame(valt, byteorder),
        RTK_IDS_ORDERED[8]: encode_velocity_frame(
            ve,
            vn,
            vu,
            speed,
            byteorder if velocity_byteorder is None else velocity_byteorder,
        ),
        RTK_IDS_ORDERED[9]: encode_heading_frame(heading, byteorder),
    }


def _default_wall_clock() -> float:
    import time

    return time.time()
