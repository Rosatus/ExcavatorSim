"""Threaded PC001 socket lifecycle, independent of any GUI framework."""

from __future__ import annotations

import socket
import threading
import time
from collections.abc import Callable
from contextlib import suppress
from dataclasses import dataclass
from enum import StrEnum

from .protocol import (
    Pc001Batch,
    Pc001ConnectionClosed,
    Pc001Error,
    Pc001ReceiveCancelled,
    perform_handshake,
    recv_batch,
)


class ReceiverState(StrEnum):
    CONNECTING = "connecting"
    HANDSHAKING = "handshaking"
    CONNECTED = "connected"
    DISCONNECTED = "disconnected"
    ERROR = "error"


@dataclass(frozen=True, slots=True)
class ReceiverEvent:
    generation: int
    state: ReceiverState
    detail: str = ""


StateCallback = Callable[[ReceiverEvent], None]
BatchCallback = Callable[[int, Pc001Batch, float], None]


class Pc001Receiver:
    """Own one reconnectable PC001 client worker and its generation guard."""

    def __init__(
        self,
        on_state: StateCallback,
        on_batch: BatchCallback,
        *,
        connect_timeout_s: float = 3.0,
        socket_poll_s: float = 0.25,
    ) -> None:
        self._on_state = on_state
        self._on_batch = on_batch
        self._connect_timeout_s = connect_timeout_s
        self._socket_poll_s = socket_poll_s
        self._lock = threading.Lock()
        self._generation = 0
        self._stop = threading.Event()
        self._socket: socket.socket | None = None
        self._thread: threading.Thread | None = None

    @property
    def generation(self) -> int:
        with self._lock:
            return self._generation

    @property
    def running(self) -> bool:
        with self._lock:
            return self._thread is not None and self._thread.is_alive()

    def start(self, host: str, port: int) -> int:
        host = host.strip()
        if not host:
            raise ValueError("host must not be empty")
        if not 1 <= port <= 65535:
            raise ValueError("port must be within 1..65535")
        self.stop()
        with self._lock:
            self._generation += 1
            generation = self._generation
            self._stop = threading.Event()
            thread = threading.Thread(
                target=self._run,
                args=(generation, host, port, self._stop),
                name=f"pc001-client-{generation}",
                daemon=False,
            )
            self._thread = thread
            thread.start()
        return generation

    def stop(self, *, join_timeout_s: float | None = None) -> None:
        with self._lock:
            thread = self._thread
            sock = self._socket
            self._stop.set()
        if sock is not None:
            with suppress(OSError):
                sock.shutdown(socket.SHUT_RDWR)
            with suppress(OSError):
                sock.close()
        if thread is not None and thread is not threading.current_thread():
            timeout = (
                self._connect_timeout_s + self._socket_poll_s + 1.0
                if join_timeout_s is None
                else join_timeout_s
            )
            thread.join(timeout=timeout)
            if thread.is_alive():
                raise RuntimeError("PC001 receiver worker did not stop before its deadline")
        with self._lock:
            if self._thread is thread and (thread is None or not thread.is_alive()):
                self._thread = None
            if self._socket is sock:
                self._socket = None

    def _emit_state(self, generation: int, state: ReceiverState, detail: str = "") -> None:
        self._on_state(ReceiverEvent(generation, state, detail))

    def _run(
        self,
        generation: int,
        host: str,
        port: int,
        stop: threading.Event,
    ) -> None:
        sock: socket.socket | None = None
        final_state = ReceiverState.DISCONNECTED
        final_detail = ""
        try:
            self._emit_state(generation, ReceiverState.CONNECTING, f"{host}:{port}")
            sock = socket.create_connection((host, port), timeout=self._connect_timeout_s)
            sock.settimeout(self._socket_poll_s)
            with self._lock:
                if generation != self._generation or stop.is_set():
                    return
                self._socket = sock
            self._emit_state(generation, ReceiverState.HANDSHAKING)
            perform_handshake(sock, cancelled=stop.is_set)
            self._emit_state(generation, ReceiverState.CONNECTED, f"{host}:{port}")
            while not stop.is_set():
                batch = recv_batch(sock, cancelled=stop.is_set)
                self._on_batch(generation, batch, time.monotonic())
        except Pc001ReceiveCancelled:
            pass
        except Pc001ConnectionClosed as exc:
            if not stop.is_set():
                final_detail = str(exc)
        except (Pc001Error, OSError) as exc:
            if not stop.is_set():
                final_state = ReceiverState.ERROR
                final_detail = str(exc)
        finally:
            if sock is not None:
                with suppress(OSError):
                    sock.close()
            with self._lock:
                if self._socket is sock:
                    self._socket = None
                if self._thread is threading.current_thread():
                    self._thread = None
            self._emit_state(generation, final_state, final_detail)
