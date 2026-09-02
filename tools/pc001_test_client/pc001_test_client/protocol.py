"""Pure-Python decoder for the Gateway PC001 TCP wire protocol."""

from __future__ import annotations

import struct
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

SERVER_GREETING = b"who"
CLIENT_IDENTITY = b"PC001"
BATCH_PREFIX_STRUCT = struct.Struct("<H")
CAN_FRAME_STRUCT = struct.Struct("<IBBBB8s")
CHANNEL_STRUCT = struct.Struct("<i")
FRAME_WIRE_SIZE = CAN_FRAME_STRUCT.size + CHANNEL_STRUCT.size
MAX_BATCH_FRAMES = 100

CAN_EFF_FLAG = 0x80000000
CAN_EFF_MASK = 0x1FFFFFFF
CAN_SFF_MASK = 0x7FF
SUPPORTED_CHANNELS = frozenset((0, 2, 3))


class SocketReader(Protocol):
    def recv(self, size: int) -> bytes: ...


class SocketWriter(Protocol):
    def sendall(self, data: bytes) -> None: ...


class SocketLike(SocketReader, SocketWriter, Protocol):
    pass


class Pc001Error(Exception):
    """Base class for stable client diagnostics."""


class Pc001ConnectionClosed(Pc001Error):
    """The peer closed before the current protocol unit was complete."""


class Pc001ReceiveCancelled(Pc001Error):
    """The local client cancelled an in-flight receive."""


class Pc001HandshakeError(Pc001Error):
    """The server greeting did not match the PC001 contract."""


class Pc001ProtocolError(Pc001Error):
    """The peer emitted bytes outside the supported PC001 contract."""


class Pc001TimeoutError(Pc001Error):
    """A handshake or partially received protocol unit exceeded its deadline."""


@dataclass(frozen=True, slots=True)
class Pc001Frame:
    """One decoded frame with canonical identity and logical channel."""

    can_id: int
    is_extended: bool
    dlc: int
    payload: bytes
    channel: int
    wire_can_id: int

    @property
    def identity_text(self) -> str:
        width = 8 if self.is_extended else 3
        return f"0x{self.can_id:0{width}X}"

    @property
    def payload_text(self) -> str:
        return " ".join(f"{value:02X}" for value in self.payload)


@dataclass(frozen=True, slots=True)
class Pc001Batch:
    frames: tuple[Pc001Frame, ...]

    @property
    def count(self) -> int:
        return len(self.frames)


def recv_exact(
    reader: SocketReader,
    size: int,
    *,
    cancelled: Callable[[], bool] | None = None,
    timeout_s: float | None = None,
    timeout_after_first_byte: bool = False,
) -> bytes:
    """Read exactly ``size`` bytes while preserving partial TCP reads."""

    if size < 0:
        raise ValueError("size must be non-negative")
    if timeout_s is not None and timeout_s <= 0.0:
        raise ValueError("timeout_s must be positive")
    chunks: list[bytes] = []
    remaining = size
    deadline = (
        None
        if timeout_s is None or timeout_after_first_byte
        else time.monotonic() + timeout_s
    )
    while remaining:
        if cancelled is not None and cancelled():
            raise Pc001ReceiveCancelled("receive cancelled")
        try:
            chunk = reader.recv(remaining)
        except TimeoutError:
            if deadline is not None and time.monotonic() >= deadline:
                received = size - remaining
                raise Pc001TimeoutError(
                    f"timed out receiving {size} bytes ({received} received)"
                ) from None
            continue
        if not chunk:
            received = size - remaining
            raise Pc001ConnectionClosed(
                f"peer closed while receiving {size} bytes ({received} received)"
            )
        chunks.append(chunk)
        remaining -= len(chunk)
        if deadline is None and timeout_s is not None:
            deadline = time.monotonic() + timeout_s
    return b"".join(chunks)


def perform_handshake(
    sock: SocketLike,
    *,
    cancelled: Callable[[], bool] | None = None,
    timeout_s: float = 3.0,
) -> None:
    """Validate the server greeting and identify as the PC001 client."""

    greeting = recv_exact(
        sock,
        len(SERVER_GREETING),
        cancelled=cancelled,
        timeout_s=timeout_s,
    )
    if greeting != SERVER_GREETING:
        raise Pc001HandshakeError(f"unexpected server greeting: {greeting!r}")
    sock.sendall(CLIENT_IDENTITY)


def decode_frame(wire: bytes) -> Pc001Frame:
    if len(wire) != FRAME_WIRE_SIZE:
        raise Pc001ProtocolError(
            f"frame size must be {FRAME_WIRE_SIZE} bytes, got {len(wire)}"
        )
    frame_wire = wire[: CAN_FRAME_STRUCT.size]
    channel_wire = wire[CAN_FRAME_STRUCT.size :]
    wire_can_id, dlc, pad, reserved, len8_dlc, payload_padded = CAN_FRAME_STRUCT.unpack(
        frame_wire
    )
    if dlc > 8:
        raise Pc001ProtocolError(f"invalid CAN DLC {dlc}")
    if pad != 0 or reserved != 0 or len8_dlc != 0:
        raise Pc001ProtocolError("CAN frame reserved bytes must be zero")
    (channel,) = CHANNEL_STRUCT.unpack(channel_wire)
    if channel not in SUPPORTED_CHANNELS:
        raise Pc001ProtocolError(f"unsupported PC001 channel {channel}")

    is_extended = bool(wire_can_id & CAN_EFF_FLAG)
    can_id = wire_can_id & (CAN_EFF_MASK if is_extended else CAN_SFF_MASK)
    return Pc001Frame(
        can_id=can_id,
        is_extended=is_extended,
        dlc=dlc,
        payload=payload_padded[:dlc],
        channel=channel,
        wire_can_id=wire_can_id,
    )


def recv_batch(
    reader: SocketReader,
    *,
    cancelled: Callable[[], bool] | None = None,
    partial_timeout_s: float = 2.0,
) -> Pc001Batch:
    header = recv_exact(
        reader,
        BATCH_PREFIX_STRUCT.size,
        cancelled=cancelled,
        timeout_s=partial_timeout_s,
        timeout_after_first_byte=True,
    )
    (count,) = BATCH_PREFIX_STRUCT.unpack(header)
    if count < 1 or count > MAX_BATCH_FRAMES:
        raise Pc001ProtocolError(
            f"batch count must be within 1..{MAX_BATCH_FRAMES}, got {count}"
        )
    body = recv_exact(
        reader,
        count * FRAME_WIRE_SIZE,
        cancelled=cancelled,
        timeout_s=partial_timeout_s,
    )
    frames = tuple(
        decode_frame(body[offset : offset + FRAME_WIRE_SIZE])
        for offset in range(0, len(body), FRAME_WIRE_SIZE)
    )
    return Pc001Batch(frames)
