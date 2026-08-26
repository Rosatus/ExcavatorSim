"""Frame sinks: where encoded CAN frames go after encoding.

CsvFrameSink wraps the CANape CSV writer (Windows/any platform).
SocketCanSink writes raw 16-byte can_frame structs to a Linux SocketCAN
(vcan) interface, mirroring dev_arch2.0 tools/can_replay/vcan_client.py.
"""

from __future__ import annotations

import socket
import struct
from typing import Protocol

from csv_writer import CanapeCsvWriter
from vcan_setup import VcanSetupError, require_vcan_interface

CAN_FRAME_STRUCT = struct.Struct("<IBBBB8s")
CAN_FRAME_DLC = 8
CAN_SFF_MASK = 0x7FF


class FrameSink(Protocol):
    def append(self, can_id: int, payload: bytes) -> None: ...

    def close(self) -> None: ...


def pack_can_frame(can_id: int, payload: bytes) -> bytes:
    """16-byte Linux can_frame (can_id, dlc, pad, res0, len8_dlc, data[8])."""
    data = payload.ljust(CAN_FRAME_DLC, b"\x00")[:CAN_FRAME_DLC]
    return CAN_FRAME_STRUCT.pack(can_id & CAN_SFF_MASK, CAN_FRAME_DLC, 0, 0, 0, data)


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
    """Send frames to a SocketCAN interface via AF_CAN CAN_RAW."""

    def __init__(self, interface: str = "vcan0", *, setup_check: bool = True) -> None:
        try:
            self.sock = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
        except (AttributeError, OSError) as exc:
            raise RuntimeError(
                f"AF_CAN / CAN_RAW unavailable ({exc}); SocketCAN requires Linux with CAN support"
            ) from exc
        try:
            if setup_check:
                require_vcan_interface(interface)
            self.sock.bind((interface,))
        except OSError as exc:
            self.sock.close()
            raise RuntimeError(
                f"cannot bind SocketCAN interface '{interface}': {exc}. "
                f"Run first: gateway --setup-vcan --interface {interface}"
            ) from exc
        except VcanSetupError as exc:
            self.sock.close()
            raise RuntimeError(str(exc)) from exc
        self.interface = interface

    def peer_name(self) -> str:
        return f"vcan:{self.interface}"

    def append(self, can_id: int, payload: bytes) -> None:
        self.sock.send(pack_can_frame(can_id, payload))

    def close(self) -> None:
        self.sock.close()
