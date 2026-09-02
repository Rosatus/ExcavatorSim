"""PC001 TCP transport sink: gateway serves frames to an ICT-side bridge.

Wire protocol mirrors dev_arch2.0 tools/can_replay (pc001_server.py +
socket_bridge.py) byte-for-byte:
  - on accept the server sends b"who"; a valid client answers b"PC001"
    within 10 s
  - frames stream as [u16 LE count] + count x [can_frame(16B LE) + i32 LE
    channel]; batches never exceed MAX_BATCH_FRAMES

The sink runs one accept/send service thread. Producers only enqueue while a
handshaken client is current; missing-client, queue-full, and disconnect drops
are counted and no frame is replayed into a later client session.
"""

from __future__ import annotations

import socket
import struct
import threading
import time
from collections import deque
from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass

from can_channel import CanChannel, channel_number
from sinks import pack_can_frame

CAN_FRAME_SIZE = 16
CHANNEL_STRUCT = struct.Struct("<i")
BATCH_PREFIX_STRUCT = struct.Struct("<H")
SINGLE_FRAME_SIZE = CAN_FRAME_SIZE + CHANNEL_STRUCT.size
MAX_BATCH_FRAMES = 100
HANDSHAKE_TIMEOUT_S = 10.0
SEND_TIMEOUT_S = 1.0
DEFAULT_QUEUE_CAPACITY = 1_000


@dataclass(frozen=True)
class Pc001Status:
    handshake_connected: bool
    queued_frames: int
    sent_frames: int
    dropped_no_client: int
    dropped_queue_full: int
    dropped_disconnect: int

    @property
    def dropped_frames(self) -> int:
        return self.dropped_no_client + self.dropped_queue_full + self.dropped_disconnect


@dataclass(frozen=True)
class _PendingFrame:
    wire: bytes
    source: str
    family: str
    can_id: int
    is_extended: bool
    payload: bytes


class TcpPc001Sink:
    """FrameSink writing packed can_frame batches to a connected PC001 client."""

    def __init__(
        self,
        host: str = "0.0.0.0",
        port: int = 5678,
        *,
        queue_capacity: int = DEFAULT_QUEUE_CAPACITY,
    ) -> None:
        if queue_capacity <= 0:
            raise ValueError("queue_capacity must be positive")
        self.host = host
        self.port = port
        self._queue_capacity = queue_capacity
        self._state = threading.Condition()
        self._pending: deque[_PendingFrame] = deque()
        self._egress_observer: Callable[[str, str, int, bool, bytes, float], None] | None = None
        self._client: socket.socket | None = None
        self._candidate: socket.socket | None = None
        self._closing = False
        self._sent_frames = 0
        self._dropped_no_client = 0
        self._dropped_queue_full = 0
        self._dropped_disconnect = 0
        try:
            self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._server.bind((host, port))
            self._server.listen(1)
            self._server.settimeout(0.2)
        except OSError as exc:
            raise RuntimeError(
                f"cannot listen TCP {host}:{port}: {exc}. "
                "Check for a stale gateway with 'netstat -ano | findstr <port>'"
            ) from exc
        self._thread = threading.Thread(target=self._serve_loop, name="pc001-service")
        self._thread.start()

    def peer_name(self) -> str:
        state = "connected" if self.is_handshake_connected() else "waiting"
        return f"tcp:{self.host}:{self.port} ({state})"

    def is_handshake_connected(self) -> bool:
        """Return true only while an accepted PC001 client socket is current."""
        with self._state:
            return not self._closing and self._client is not None

    def status_snapshot(self) -> Pc001Status:
        with self._state:
            return Pc001Status(
                handshake_connected=not self._closing and self._client is not None,
                queued_frames=len(self._pending),
                sent_frames=self._sent_frames,
                dropped_no_client=self._dropped_no_client,
                dropped_queue_full=self._dropped_queue_full,
                dropped_disconnect=self._dropped_disconnect,
            )

    def append(
        self, can_id: int, payload: bytes, channel: CanChannel = "ch0"
    ) -> None:
        self.submit(
            can_id, payload, channel=channel, source="unknown", family="unknown"
        )

    def submit(
        self,
        can_id: int,
        payload: bytes,
        *,
        channel: CanChannel = "ch0",
        source: str,
        family: str,
        is_extended: bool | None = None,
    ) -> None:
        raw_id = can_id & 0x1FFFFFFF
        extended = bool(can_id & 0x80000000) or raw_id > 0x7FF
        if is_extended is not None:
            extended = is_extended
        transport_id = raw_id | (0x80000000 if extended else 0)
        frame = pack_can_frame(transport_id, payload)
        with self._state:
            if self._closing or self._client is None:
                self._dropped_no_client += 1
                return
            if len(self._pending) >= self._queue_capacity:
                self._dropped_queue_full += 1
                return
            self._pending.append(
                _PendingFrame(
                    frame + CHANNEL_STRUCT.pack(channel_number(channel)),
                    source,
                    family,
                    raw_id,
                    extended,
                    bytes(payload),
                )
            )
            self._state.notify_all()

    def set_egress_observer(
        self, observer: Callable[[str, str, int, bool, bytes, float], None] | None
    ) -> None:
        with self._state:
            self._egress_observer = observer

    def close(self) -> None:
        with self._state:
            if self._closing:
                return
            self._closing = True
            client, self._client = self._client, None
            candidate, self._candidate = self._candidate, None
            self._dropped_disconnect += self._clear_pending_locked()
            self._state.notify_all()
        with suppress(OSError):
            self._server.close()
        for sock in (client, candidate):
            if sock is not None:
                with suppress(OSError):
                    sock.close()
        self._thread.join(timeout=2.0)

    # --- internal ---

    def _serve_loop(self) -> None:
        while True:
            with self._state:
                if self._closing:
                    return
            try:
                client, _addr = self._server.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            with self._state:
                if self._closing:
                    with suppress(OSError):
                        client.close()
                    return
                self._candidate = client
            if not self._handshake(client):
                with self._state:
                    if self._candidate is client:
                        self._candidate = None
                with suppress(OSError):
                    client.close()
                continue
            with self._state:
                if self._closing:
                    self._candidate = None
                    with suppress(OSError):
                        client.close()
                    return
                self._candidate = None
                self._client = client
                self._state.notify_all()
            print(f"PC001 client connected from {_addr}")
            self._client_session(client)

    def _handshake(self, client: socket.socket) -> bool:
        try:
            client.settimeout(HANDSHAKE_TIMEOUT_S)
            client.sendall(b"who")
            response = client.recv(32)
            return response.strip() == b"PC001"
        except OSError:
            return False

    def _client_session(self, client: socket.socket) -> None:
        batch_count = 0
        try:
            client.settimeout(SEND_TIMEOUT_S)
            while not self._closing and self._is_current_client(client):
                batch, frames = self._take_batch(client)
                batch_count = len(frames)
                if not batch:
                    # idle poll; keep detecting dead peers via timeout
                    self._probe_alive(client)
                    continue
                self._send_batch(client, batch)
                with self._state:
                    self._sent_frames += batch_count
                    observer = self._egress_observer
                if observer is not None:
                    completed_s = time.monotonic()
                    for frame in frames:
                        try:
                            observer(
                                frame.source,
                                frame.family,
                                frame.can_id,
                                frame.is_extended,
                                frame.payload,
                                completed_s,
                            )
                        except Exception:
                            # Metrics must never turn a successful wire write into
                            # a transport disconnect.
                            continue
                batch_count = 0
        except OSError:
            pass
        finally:
            with self._state:
                was_current = self._client is client
                if was_current:
                    self._client = None
                    self._dropped_disconnect += batch_count + self._clear_pending_locked()
                    self._state.notify_all()
            with suppress(OSError):
                client.close()

    def _take_batch(self, client: socket.socket) -> tuple[bytes, list[_PendingFrame]]:
        with self._state:
            if self._client is not client or self._closing:
                return b"", []
            count = min(len(self._pending), MAX_BATCH_FRAMES)
            if count == 0:
                return b"", []
            frames = [self._pending.popleft() for _ in range(count)]
        return BATCH_PREFIX_STRUCT.pack(count) + b"".join(frame.wire for frame in frames), frames

    def _send_batch(self, client: socket.socket, batch: bytes) -> None:
        """Single service-thread wire-write seam used by deterministic tests."""

        client.sendall(batch)

    def _clear_pending_locked(self) -> int:
        count = len(self._pending)
        self._pending.clear()
        return count

    def _is_current_client(self, client: socket.socket) -> bool:
        with self._state:
            return not self._closing and self._client is client

    def _probe_alive(self, client: socket.socket) -> None:
        """Detect peer disconnects while idle; recv raises on EOF/reset.

        Uses MSG_PEEK so no data is consumed (protocol is server->client only).
        """
        time.sleep(0.05)
        try:
            client.setblocking(False)
            try:
                data = client.recv(1, socket.MSG_PEEK)
                if data == b"":
                    raise ConnectionError("peer closed")
            except BlockingIOError:
                pass
            finally:
                client.setblocking(True)
                client.settimeout(SEND_TIMEOUT_S)
        except (ConnectionError, OSError):
            raise
