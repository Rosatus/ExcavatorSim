"""Frame sinks: where encoded CAN frames go after encoding.

CsvFrameSink wraps the CANape CSV writer (Windows/any platform).
SocketCanSink writes raw 16-byte can_frame structs to a Linux SocketCAN
interface, including the product's physical can0 transport.
"""

from __future__ import annotations

import contextlib
import errno
import socket
import struct
from collections import deque
from collections.abc import Callable
from dataclasses import dataclass, replace
from typing import Literal, Protocol

from csv_writer import CanapeCsvWriter

CAN_FRAME_STRUCT = struct.Struct("<IBBBB8s")
CAN_FRAME_DLC = 8
CAN_SFF_MASK = 0x7FF
CAN_EFF_MASK = 0x1FFFFFFF
CAN_EFF_FLAG = 0x80000000
SOCKETCAN_MAX_PENDING_IDS = 128
SOCKETCAN_SERVICE_BUDGET = 32
SOCKETCAN_CONGESTION_ERRNOS = frozenset(
    value for value in (errno.ENOBUFS, errno.EAGAIN, errno.EWOULDBLOCK) if value is not None
)

SocketCanOutcome = Literal[
    "submitted",
    "sent",
    "congestion_dropped",
    "coalesced",
    "terminal_error",
]


@dataclass(frozen=True)
class SocketCanStats:
    submitted: int = 0
    sent: int = 0
    congestion_dropped: int = 0
    coalesced: int = 0
    terminal_error: int = 0
    pending: int = 0


@dataclass(frozen=True)
class SocketCanDelta:
    source: str
    family: str
    can_id: int
    is_extended: bool
    payload: bytes
    outcome: SocketCanOutcome
    reason: str = ""


@dataclass(frozen=True)
class _PendingSocketCanFrame:
    source: str
    family: str
    can_id: int
    is_extended: bool
    payload: bytes
    generation: int | None = None


class FrameSink(Protocol):
    def append(self, can_id: int, payload: bytes) -> None: ...

    def close(self) -> None: ...


def pack_can_frame(can_id: int, payload: bytes) -> bytes:
    """16-byte Linux can_frame (can_id, dlc, pad, res0, len8_dlc, data[8])."""
    if can_id < 0:
        raise ValueError("CAN ID must be non-negative")
    flagged = bool(can_id & CAN_EFF_FLAG)
    raw_id = can_id & CAN_EFF_MASK
    if can_id & ~(CAN_EFF_FLAG | CAN_EFF_MASK):
        raise ValueError(f"unsupported CAN ID flags: 0x{can_id:X}")
    packed_id = raw_id | CAN_EFF_FLAG if flagged or raw_id > CAN_SFF_MASK else raw_id
    dlc = min(len(payload), CAN_FRAME_DLC)
    data = payload[:dlc].ljust(CAN_FRAME_DLC, b"\x00")
    return CAN_FRAME_STRUCT.pack(packed_id, dlc, 0, 0, 0, data)


class CsvFrameSink:
    """Adapter exposing CanapeCsvWriter through the FrameSink protocol."""

    def __init__(self, writer: CanapeCsvWriter) -> None:
        self._writer = writer

    @property
    def row_count(self) -> int:
        return self._writer.row_count

    @property
    def path(self):
        return self._writer.path

    def append(self, can_id: int, payload: bytes) -> None:
        self._writer.append(can_id, payload)

    def close(self) -> None:
        self._writer.close()


class SocketCanSink:
    """Bounded latest-value SocketCAN sender serviced by the Gateway owner loop."""

    def __init__(self, interface: str = "can0", *, setup_check: bool = False) -> None:
        # Preparation belongs to the caller. Retain the keyword for source
        # compatibility without giving this byte-oriented sink setup authority.
        del setup_check
        try:
            self.sock = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
        except (AttributeError, OSError) as exc:
            raise RuntimeError(
                f"AF_CAN / CAN_RAW unavailable ({exc}); SocketCAN requires Linux with CAN support"
            ) from exc
        try:
            self.sock.setblocking(False)
            self.sock.bind((interface,))
        except OSError as exc:
            self.sock.close()
            raise RuntimeError(
                f"cannot bind SocketCAN interface '{interface}': {exc}. "
                "Check that it exists, is UP, and is configured for the CAN bus"
            ) from exc
        self.interface = interface
        self.last_send_error: OSError | None = None
        self._pending: dict[int, _PendingSocketCanFrame] = {}
        self._family_ids: dict[str, deque[int]] = {}
        self._family_ring: deque[str] = deque()
        self._stats = SocketCanStats()
        self._observer: Callable[[SocketCanDelta], None] | None = None

    def peer_name(self) -> str:
        return f"socketcan:{self.interface}"

    @property
    def stats(self) -> SocketCanStats:
        return replace(self._stats, pending=len(self._pending))

    def set_outcome_observer(self, observer: Callable[[SocketCanDelta], None] | None) -> None:
        self._observer = observer

    def append(self, can_id: int, payload: bytes) -> None:
        self.submit(can_id, payload, source="unspecified", family="other")

    def submit(
        self,
        can_id: int,
        payload: bytes,
        *,
        source: str,
        family: str,
        generation: int | None = None,
        is_extended: bool | None = None,
    ) -> None:
        if self.last_send_error is not None:
            return
        raw_id = can_id & CAN_EFF_MASK
        extended = bool(can_id & CAN_EFF_FLAG) or raw_id > CAN_SFF_MASK
        if is_extended is not None:
            extended = is_extended
        normalized_id = raw_id | (CAN_EFF_FLAG if extended else 0)
        frame = _PendingSocketCanFrame(
            source=source,
            family=family,
            can_id=raw_id,
            is_extended=extended,
            payload=bytes(payload),
            generation=generation,
        )
        self._count(frame, "submitted")
        previous = self._pending.get(normalized_id)
        if previous is not None:
            if previous.family != family:
                self._remove_family_id(previous.family, normalized_id)
                self._append_family_id(family, normalized_id)
            self._pending[normalized_id] = frame
            self._count(previous, "coalesced", reason="newer_value")
            return
        if len(self._pending) >= SOCKETCAN_MAX_PENDING_IDS:
            self._count(frame, "congestion_dropped", reason="capacity")
            return
        self._pending[normalized_id] = frame
        self._append_family_id(family, normalized_id)

    def service(self, maximum: int = SOCKETCAN_SERVICE_BUDGET) -> int:
        if maximum < 0:
            raise ValueError("SocketCAN service budget must be non-negative")
        attempts = 0
        while attempts < maximum and self._pending and self.last_send_error is None:
            frame = self._pop_next()
            if frame is None:
                break
            attempts += 1
            try:
                transport_id = frame.can_id | (CAN_EFF_FLAG if frame.is_extended else 0)
                self.sock.send(pack_can_frame(transport_id, frame.payload))
            except OSError as exc:
                if exc.errno in SOCKETCAN_CONGESTION_ERRNOS:
                    self._count(frame, "congestion_dropped", reason="kernel_congestion")
                    break
                self.last_send_error = exc
                self._count(frame, "terminal_error", reason="send_failed")
                break
            self._count(frame, "sent")
        return attempts

    def purge(
        self,
        *,
        generation: int | None = None,
        family: str | None = None,
        can_id: int | None = None,
        is_extended: bool | None = None,
        reason: str,
    ) -> int:
        selected = [
            normalized_id
            for normalized_id, frame in self._pending.items()
            if (generation is None or frame.generation == generation)
            and (family is None or frame.family == family)
            and (
                can_id is None
                or normalized_id
                == (
                    (can_id & CAN_EFF_MASK)
                    | (
                        CAN_EFF_FLAG
                        if (
                            is_extended
                            if is_extended is not None
                            else bool(can_id & CAN_EFF_FLAG)
                            or (can_id & CAN_EFF_MASK) > CAN_SFF_MASK
                        )
                        else 0
                    )
                )
            )
        ]
        for normalized_id in selected:
            frame = self._remove_pending(normalized_id)
            if frame is not None:
                self._count(frame, "congestion_dropped", reason=reason)
        return len(selected)

    def _count(
        self,
        frame: _PendingSocketCanFrame,
        outcome: SocketCanOutcome,
        *,
        reason: str = "",
    ) -> None:
        self._stats = replace(
            self._stats,
            **{outcome: getattr(self._stats, outcome) + 1},
        )
        if self._observer is not None:
            self._observer(
                SocketCanDelta(
                    source=frame.source,
                    family=frame.family,
                    can_id=frame.can_id,
                    is_extended=frame.is_extended,
                    payload=frame.payload,
                    outcome=outcome,
                    reason=reason,
                )
            )

    def _append_family_id(self, family: str, normalized_id: int) -> None:
        family_ids = self._family_ids.get(family)
        if family_ids is None:
            family_ids = deque()
            self._family_ids[family] = family_ids
            self._family_ring.append(family)
        family_ids.append(normalized_id)

    def _remove_family_id(self, family: str, normalized_id: int) -> None:
        family_ids = self._family_ids.get(family)
        if family_ids is None:
            return
        try:
            family_ids.remove(normalized_id)
        except ValueError:
            return
        if not family_ids:
            del self._family_ids[family]
            with contextlib.suppress(ValueError):
                self._family_ring.remove(family)

    def _remove_pending(self, normalized_id: int) -> _PendingSocketCanFrame | None:
        frame = self._pending.pop(normalized_id, None)
        if frame is not None:
            self._remove_family_id(frame.family, normalized_id)
        return frame

    def _pop_next(self) -> _PendingSocketCanFrame | None:
        while self._family_ring:
            family = self._family_ring[0]
            self._family_ring.rotate(-1)
            family_ids = self._family_ids.get(family)
            if not family_ids:
                with contextlib.suppress(ValueError):
                    self._family_ring.remove(family)
                continue
            normalized_id = family_ids.popleft()
            if not family_ids:
                del self._family_ids[family]
                with contextlib.suppress(ValueError):
                    self._family_ring.remove(family)
            frame = self._pending.pop(normalized_id, None)
            if frame is not None:
                return frame
        return None

    def close(self) -> None:
        self._pending.clear()
        self._family_ids.clear()
        self._family_ring.clear()
        self.sock.close()
