"""Control-plane codec between the Godot bridge and the gateway process.

Control (bridge -> gateway), 12 bytes LE "<IBBHI":
    magic 0x43544E43 "CTNC" | ver=1 | cmd | reserved u16 | seq u32
    cmd: 1=RECORD_START 2=RECORD_STOP 3=SHUTDOWN 4=ICT_START 5=ICT_STOP
         6=TIMED_CAN_START

Heartbeat (gateway -> bridge), 16 bytes LE "<IBBHQ":
    magic 0x43544E4B "CTNK" | ver=1 | flags(recording/linux/PC001 handshake) |
    reserved u16 | tick_ms u64

Session-done (gateway -> bridge after a stopped segment is closed),
variable length LE "<IBBH" + utf8 path:
    magic 0x43544E44 "CTND" | ver=1 | reserved u16 | path
"""

from __future__ import annotations

import struct

CONTROL_MAGIC = 0x43544E43  # "CTNC"
HEARTBEAT_MAGIC = 0x43544E4B  # "CTNK"
SESSION_DONE_MAGIC = 0x43544E44  # "CTND"
PROTOCOL_VERSION = 1

CMD_RECORD_START = 1
CMD_RECORD_STOP = 2
CMD_SHUTDOWN = 3
CMD_ICT_START = 4
CMD_ICT_STOP = 5
CMD_TIMED_CAN_START = 6

_VALID_COMMANDS = frozenset(
    (
        CMD_RECORD_START,
        CMD_RECORD_STOP,
        CMD_SHUTDOWN,
        CMD_ICT_START,
        CMD_ICT_STOP,
        CMD_TIMED_CAN_START,
    )
)

HEARTBEAT_FLAG_RECORDING = 0x01
HEARTBEAT_FLAG_PLATFORM_LINUX = 0x02
HEARTBEAT_FLAG_ICT_HANDSHAKE = 0x04

_CONTROL_STRUCT = struct.Struct("<IBBHI")
_HEARTBEAT_STRUCT = struct.Struct("<IBBHQ")
_DONE_HEADER = struct.Struct("<IBBH")


def build_control(cmd: int, seq: int = 0) -> bytes:
    return _CONTROL_STRUCT.pack(CONTROL_MAGIC, PROTOCOL_VERSION, cmd, 0, seq & 0xFFFFFFFF)


def parse_control(data: bytes) -> int | None:
    if len(data) != _CONTROL_STRUCT.size:
        return None
    magic, version, cmd, _reserved, _seq = _CONTROL_STRUCT.unpack(data)
    if magic != CONTROL_MAGIC or version != PROTOCOL_VERSION:
        return None
    if cmd not in _VALID_COMMANDS:
        return None
    return cmd


def build_heartbeat(
    tick_ms: int,
    recording: bool,
    platform_linux: bool = False,
    ict_handshake: bool = False,
) -> bytes:
    flags = 0
    if recording:
        flags |= HEARTBEAT_FLAG_RECORDING
    if platform_linux:
        flags |= HEARTBEAT_FLAG_PLATFORM_LINUX
    if ict_handshake:
        flags |= HEARTBEAT_FLAG_ICT_HANDSHAKE
    return _HEARTBEAT_STRUCT.pack(
        HEARTBEAT_MAGIC, PROTOCOL_VERSION, flags, 0, tick_ms & 0xFFFFFFFFFFFFFFFF
    )


def parse_heartbeat(data: bytes) -> tuple[bool, int] | None:
    parsed = parse_heartbeat_flags(data)
    if parsed is None:
        return None
    recording, _platform_linux, tick_ms = parsed
    return recording, tick_ms


def parse_heartbeat_flags(data: bytes) -> tuple[bool, bool, int] | None:
    if len(data) != _HEARTBEAT_STRUCT.size:
        return None
    magic, version, flags, _reserved, tick_ms = _HEARTBEAT_STRUCT.unpack(data)
    if magic != HEARTBEAT_MAGIC or version != PROTOCOL_VERSION:
        return None
    return (
        bool(flags & HEARTBEAT_FLAG_RECORDING),
        bool(flags & HEARTBEAT_FLAG_PLATFORM_LINUX),
        tick_ms,
    )


def build_session_done(path: str) -> bytes:
    return _DONE_HEADER.pack(SESSION_DONE_MAGIC, PROTOCOL_VERSION, 0, 0) + path.encode("utf-8")


def parse_session_done(data: bytes) -> str | None:
    if len(data) <= _DONE_HEADER.size:
        return None
    magic, version, _reserved, _reserved2 = _DONE_HEADER.unpack(data[: _DONE_HEADER.size])
    if magic != SESSION_DONE_MAGIC or version != PROTOCOL_VERSION:
        return None
    try:
        return data[_DONE_HEADER.size :].decode("utf-8")
    except UnicodeDecodeError:
        return None
