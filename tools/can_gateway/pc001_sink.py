"""PC001 TCP transport sink: gateway serves frames to an ICT-side bridge.

Wire protocol mirrors dev_arch2.0 tools/can_replay (pc001_server.py +
socket_bridge.py) byte-for-byte:
  - on accept the server sends b"who"; a valid client answers b"PC001"
    within 10 s
  - frames stream as [u16 LE count] + count x [can_frame(16B LE) + i32 LE
    channel]; batches never exceed MAX_BATCH_FRAMES

The sink runs an accept/send loop on a daemon thread. With no client
connected, appended frames are dropped silently; a new client replaces a
stale one.
"""

from __future__ import annotations

import socket
import struct
import threading
from contextlib import suppress

from sinks import pack_can_frame

CAN_FRAME_SIZE = 16
CHANNEL_STRUCT = struct.Struct("<i")
BATCH_PREFIX_STRUCT = struct.Struct("<H")
SINGLE_FRAME_SIZE = CAN_FRAME_SIZE + CHANNEL_STRUCT.size
MAX_BATCH_FRAMES = 100
HANDSHAKE_TIMEOUT_S = 10.0
SEND_TIMEOUT_S = 1.0


class TcpPc001Sink:
    """FrameSink writing packed can_frame batches to a connected PC001 client."""

    def __init__(self, host: str = "0.0.0.0", port: int = 5678) -> None:
        self.host = host
        self.port = port
        self._lock = threading.Lock()
        self._client_lock = threading.Lock()
        self._pending: list[bytes] = []
        self._client: socket.socket | None = None
        self._closing = False
        try:
            self._server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            self._server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            self._server.bind((host, port))
            self._server.listen(1)
        except OSError as exc:
            raise RuntimeError(
                f"cannot listen TCP {host}:{port}: {exc}. "
                "Check for a stale gateway with 'netstat -ano | findstr <port>'"
            ) from exc
        self._thread = threading.Thread(target=self._serve_loop, daemon=True)
        self._thread.start()

    def peer_name(self) -> str:
        state = "connected" if self.is_handshake_connected() else "waiting"
        return f"tcp:{self.host}:{self.port} ({state})"

    def is_handshake_connected(self) -> bool:
        """Return true only while an accepted PC001 client socket is current."""
        with self._client_lock:
            return not self._closing and self._client is not None

    def append(self, can_id: int, payload: bytes) -> None:
        if self._closing:
            return
        frame = pack_can_frame(can_id, payload)
        flush_needed = False
        with self._lock:
            self._pending.append(frame + CHANNEL_STRUCT.pack(0))
            flush_needed = len(self._pending) >= MAX_BATCH_FRAMES
        if flush_needed:
            self._flush_pending()

    def close(self) -> None:
        if self._closing:
            return
        self._closing = True
        with suppress(OSError):
            self._server.close()
        self._drop_client()
        self._thread.join(timeout=2.0)

    # --- internal ---

    def _drop_client(self) -> None:
        with self._client_lock:
            client, self._client = self._client, None
        if client is not None:
            with suppress(OSError):
                client.close()

    def _serve_loop(self) -> None:
        while not self._closing:
            try:
                client, _addr = self._server.accept()
            except OSError:
                break
            if not self._handshake(client):
                with suppress(OSError):
                    client.close()
                continue
            with self._client_lock:
                old, self._client = self._client, client
            if old is not None and old is not client:
                with suppress(OSError):
                    old.close()
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
        batch = b""
        try:
            client.settimeout(SEND_TIMEOUT_S)
            while not self._closing and self._is_current_client(client):
                batch = self._take_batch()
                if not batch:
                    # idle poll; keep detecting dead peers via timeout
                    self._probe_alive(client)
                    continue
                client.sendall(batch)
        except OSError:
            pass
        finally:
            with self._client_lock:
                was_current = self._client is client
                if was_current:
                    self._client = None
            if was_current:
                self._requeue(batch)
            with suppress(OSError):
                client.close()

    def _take_batch(self) -> bytes:
        with self._lock:
            count = min(len(self._pending), MAX_BATCH_FRAMES)
            if count == 0:
                return b""
            frames = self._pending[:count]
            del self._pending[:count]
        return BATCH_PREFIX_STRUCT.pack(count) + b"".join(frames)

    def _requeue(self, batch: bytes) -> None:
        """Put unsent frames of a failed batch back for the next client."""
        if len(batch) <= BATCH_PREFIX_STRUCT.size:
            return
        body = batch[BATCH_PREFIX_STRUCT.size :]
        frames = [body[i : i + SINGLE_FRAME_SIZE] for i in range(0, len(body), SINGLE_FRAME_SIZE)]
        with self._lock:
            self._pending = frames + self._pending

    def _flush_pending(self) -> None:
        """Best-effort immediate drain from the caller's thread."""
        with self._client_lock:
            client = self._client
        if client is None:
            return
        batch = self._take_batch()
        if not batch:
            return
        try:
            client.sendall(batch)
        except OSError:
            self._requeue(batch)

    def _is_current_client(self, client: socket.socket) -> bool:
        with self._client_lock:
            return self._client is client

    def _probe_alive(self, client: socket.socket) -> None:
        """Detect peer disconnects while idle; recv raises on EOF/reset.

        Uses MSG_PEEK so no data is consumed (protocol is server->client only).
        """
        import time

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
