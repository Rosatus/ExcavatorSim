"""Thread-safe control, status, event, and persistence primitives for Gateway."""

from __future__ import annotations

import json
import os
import queue
import socket
import threading
import time
import uuid
from collections import OrderedDict, deque
from concurrent.futures import Future
from contextlib import suppress
from dataclasses import asdict, dataclass, field, replace
from pathlib import Path
from typing import Any, Literal

from platformdirs import user_config_path, user_log_path

RUNTIME_MODES = ("standalone", "godot-managed")
RuntimeMode = Literal["standalone", "godot-managed"]
COMMAND_QUEUE_CAPACITY = 64
COMMAND_CACHE_CAPACITY = 128
EVENT_RING_CAPACITY = 4_096
EVENT_WRITER_CAPACITY = 4_096
LOG_FILE_BYTES = 20 * 1024 * 1024
LOG_FILE_COUNT = 5


class GatewayRuntimeError(RuntimeError):
    """Stable error returned through the local Web boundary."""

    def __init__(self, code: str, message: str, *, status: int = 400) -> None:
        super().__init__(message)
        self.code = code
        self.status = status


@dataclass(frozen=True)
class GatewayCommand:
    request_id: str
    kind: str
    expected_revision: int
    payload: dict[str, Any]
    future: Future[dict[str, Any]] = field(compare=False, repr=False)


@dataclass(frozen=True)
class GatewayStatus:
    revision: int
    mode: RuntimeMode
    platform: str
    web_url: str
    transport_kind: str
    transport_state: str
    transport_detail: str
    recording: bool
    timed_can_active: bool
    ict_active: bool
    periodic_armed: bool
    tcp_host: str
    tcp_port: int
    can_interface: str
    pc001_handshake: bool
    pc001_queued_frames: int
    pc001_sent_frames: int
    pc001_dropped_frames: int
    event_sequence: int
    event_earliest_sequence: int
    log_dropped_records: int

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class GatewayEvent:
    sequence: int
    timestamp: str
    monotonic_s: float
    kind: str
    source: str
    detail: dict[str, Any]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


class RuntimeEventLog:
    """Bounded live ring plus non-blocking rotating JSONL persistence."""

    def __init__(
        self,
        *,
        directory: Path | None = None,
        ring_capacity: int = EVENT_RING_CAPACITY,
        writer_capacity: int = EVENT_WRITER_CAPACITY,
        max_file_bytes: int = LOG_FILE_BYTES,
        file_count: int = LOG_FILE_COUNT,
    ) -> None:
        self.directory = directory or (user_log_path("ExcavatorSim", "Rosatus") / "can_gateway")
        self.directory.mkdir(parents=True, exist_ok=True)
        self.current_path = self.directory / "gateway.jsonl"
        self._ring: deque[GatewayEvent] = deque(maxlen=ring_capacity)
        self._condition = threading.Condition()
        self._writer_queue: queue.Queue[GatewayEvent | None] = queue.Queue(writer_capacity)
        self._max_file_bytes = max_file_bytes
        self._file_count = file_count
        self._sequence = 0
        self._dropped_records = 0
        self._closed = False
        self._writer = threading.Thread(target=self._writer_loop, name="gateway-log-writer")
        self._writer.start()

    @property
    def dropped_records(self) -> int:
        with self._condition:
            return self._dropped_records

    @property
    def latest_sequence(self) -> int:
        with self._condition:
            return self._sequence

    @property
    def earliest_sequence(self) -> int:
        with self._condition:
            return self._ring[0].sequence if self._ring else self._sequence + 1

    def append(self, kind: str, source: str, detail: dict[str, Any]) -> GatewayEvent:
        with self._condition:
            if self._closed:
                raise GatewayRuntimeError(
                    "runtime_closed", "gateway event log is closed", status=503
                )
            self._sequence += 1
            event = GatewayEvent(
                sequence=self._sequence,
                timestamp=time.strftime("%Y-%m-%dT%H:%M:%S", time.localtime()),
                monotonic_s=time.monotonic(),
                kind=kind,
                source=source,
                detail=dict(detail),
            )
            self._ring.append(event)
            self._condition.notify_all()
        try:
            self._writer_queue.put_nowait(event)
        except queue.Full:
            with self._condition:
                self._dropped_records += 1
        return event

    def events_after(self, sequence: int) -> tuple[list[GatewayEvent], bool]:
        with self._condition:
            earliest = self._ring[0].sequence if self._ring else self._sequence + 1
            gap = sequence < earliest - 1
            return [event for event in self._ring if event.sequence > sequence], gap

    def wait_after(self, sequence: int, timeout_s: float) -> tuple[list[GatewayEvent], bool]:
        with self._condition:
            if self._sequence <= sequence and not self._closed:
                self._condition.wait(timeout=timeout_s)
        return self.events_after(sequence)

    def retained_paths(self) -> list[Path]:
        paths = [self.current_path]
        paths.extend(Path(f"{self.current_path}.{index}") for index in range(1, self._file_count))
        return [path for path in paths if path.is_file()]

    def close(self) -> None:
        with self._condition:
            if self._closed:
                return
            self._closed = True
            self._condition.notify_all()
        try:
            self._writer_queue.put_nowait(None)
        except queue.Full:
            # Make shutdown progress without blocking the CAN owner.
            with suppress(queue.Empty):
                self._writer_queue.get_nowait()
            self._writer_queue.put_nowait(None)
        self._writer.join(timeout=3.0)

    def _writer_loop(self) -> None:
        handle = None
        try:
            handle = self.current_path.open("a", encoding="utf-8", newline="\n")
            while True:
                event = self._writer_queue.get()
                if event is None:
                    break
                encoded = json.dumps(
                    event.to_dict(), ensure_ascii=False, separators=(",", ":"), allow_nan=False
                )
                if self._should_rotate(handle, len(encoded.encode("utf-8")) + 1):
                    handle.close()
                    self._rotate_files()
                    handle = self.current_path.open("a", encoding="utf-8", newline="\n")
                handle.write(encoded + "\n")
                handle.flush()
        except OSError:
            with self._condition:
                self._dropped_records += 1
        finally:
            if handle is not None:
                handle.close()

    def _should_rotate(self, handle, incoming_bytes: int) -> bool:
        try:
            return handle.tell() + incoming_bytes > self._max_file_bytes
        except OSError:
            return False

    def _rotate_files(self) -> None:
        oldest = Path(f"{self.current_path}.{self._file_count - 1}")
        if oldest.exists():
            oldest.unlink()
        for index in range(self._file_count - 2, 0, -1):
            source = Path(f"{self.current_path}.{index}")
            if source.exists():
                source.replace(Path(f"{self.current_path}.{index + 1}"))
        if self.current_path.exists():
            self.current_path.replace(Path(f"{self.current_path}.1"))


class GatewayConfigStore:
    """Schema-versioned atomic mutable configuration outside the distribution."""

    def __init__(self, path: Path | None = None) -> None:
        self.path = path or (
            user_config_path("ExcavatorSim", "Rosatus") / "can_gateway" / "config.json"
        )

    def load_tcp_endpoint(self, default_host: str, default_port: int) -> tuple[str, int]:
        try:
            decoded = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return default_host, default_port
        if not isinstance(decoded, dict) or decoded.get("schema_version") != 1:
            return default_host, default_port
        tcp = decoded.get("tcp")
        if not isinstance(tcp, dict):
            return default_host, default_port
        host, port = tcp.get("host"), tcp.get("port")
        if not isinstance(host, str) or not isinstance(port, int) or isinstance(port, bool):
            return default_host, default_port
        return host, port

    def save_tcp_endpoint(self, host: str, port: int) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        payload = json.dumps(
            {"schema_version": 1, "tcp": {"host": host, "port": port}},
            ensure_ascii=False,
            indent=2,
            allow_nan=False,
        )
        temporary = self.path.with_name(f".{self.path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
        try:
            with temporary.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write(payload + "\n")
                handle.flush()
                os.fsync(handle.fileno())
            temporary.replace(self.path)
        finally:
            if temporary.exists():
                temporary.unlink()


class GatewayRuntimeCore:
    """Cross-thread boundary; owner-loop code alone executes submitted commands."""

    def __init__(
        self,
        *,
        mode: RuntimeMode,
        platform: str,
        transport_kind: str,
        tcp_host: str,
        tcp_port: int,
        can_interface: str,
        event_log: RuntimeEventLog | None = None,
        config_store: GatewayConfigStore | None = None,
    ) -> None:
        if mode not in RUNTIME_MODES:
            raise ValueError(f"unsupported gateway mode: {mode}")
        self.mode = mode
        self.platform = platform
        self.events = event_log or RuntimeEventLog()
        self.config = config_store or GatewayConfigStore()
        self._commands: queue.Queue[GatewayCommand] = queue.Queue(COMMAND_QUEUE_CAPACITY)
        self._cache_lock = threading.Lock()
        self._command_cache: OrderedDict[str, tuple[str, Future[dict[str, Any]]]] = OrderedDict()
        self._status_lock = threading.Lock()
        self._status = GatewayStatus(
            revision=0,
            mode=mode,
            platform=platform,
            web_url="",
            transport_kind=transport_kind,
            transport_state="stopped",
            transport_detail="",
            recording=False,
            timed_can_active=False,
            ict_active=False,
            periodic_armed=False,
            tcp_host=tcp_host,
            tcp_port=tcp_port,
            can_interface=can_interface,
            pc001_handshake=False,
            pc001_queued_frames=0,
            pc001_sent_frames=0,
            pc001_dropped_frames=0,
            event_sequence=0,
            event_earliest_sequence=1,
            log_dropped_records=0,
        )
        self._aggregate_lock = threading.Lock()
        self._aggregates: dict[tuple[str, int], dict[str, Any]] = {}
        self._aggregate_window_s = time.monotonic()
        self._closed = False
        self._dbc_snapshot_lock = threading.Lock()
        self._dbc_snapshot: dict[str, Any] = {
            "armed": False,
            "catalog": {"files": [], "notices": [], "message_count": 0},
            "messages": [],
            "notices": [],
            "load": {},
        }
        self._wakeup_read, self._wakeup_write = socket.socketpair()
        self._wakeup_read.setblocking(False)
        self._wakeup_write.setblocking(False)

    @property
    def wakeup_reader(self) -> socket.socket:
        return self._wakeup_read

    def consume_wakeup(self) -> None:
        while True:
            try:
                if not self._wakeup_read.recv(256):
                    return
            except BlockingIOError:
                return

    def snapshot(self) -> GatewayStatus:
        with self._status_lock:
            return replace(
                self._status,
                event_sequence=self.events.latest_sequence,
                event_earliest_sequence=self.events.earliest_sequence,
                log_dropped_records=self.events.dropped_records,
            )

    def publish(self, *, mutate_revision: bool = False, **changes: Any) -> GatewayStatus:
        with self._status_lock:
            revision = self._status.revision + 1 if mutate_revision else self._status.revision
            self._status = replace(self._status, revision=revision, **changes)
            return self._status

    def publish_dbc_snapshot(self, snapshot: dict[str, Any]) -> None:
        """Publish a detached JSON value without exposing owner-loop objects."""
        detached = json.loads(json.dumps(snapshot, allow_nan=False))
        with self._dbc_snapshot_lock:
            self._dbc_snapshot = detached

    def dbc_snapshot(self) -> dict[str, Any]:
        with self._dbc_snapshot_lock:
            return json.loads(json.dumps(self._dbc_snapshot, allow_nan=False))

    def emit_event(self, kind: str, source: str, **detail: Any) -> GatewayEvent:
        return self.events.append(kind, source, detail)

    def record_transmission(
        self,
        *,
        source: str,
        can_id: int,
        payload: bytes,
        success: bool,
        error: str = "",
    ) -> None:
        key = (source, can_id)
        with self._aggregate_lock:
            aggregate = self._aggregates.setdefault(
                key,
                {
                    "attempted": 0,
                    "succeeded": 0,
                    "failed": 0,
                    "last_can_id": f"0x{can_id:X}",
                    "last_dlc": len(payload),
                    "last_payload": payload.hex().upper(),
                    "latest_error": "",
                },
            )
            aggregate["attempted"] += 1
            aggregate["succeeded" if success else "failed"] += 1
            aggregate["last_dlc"] = len(payload)
            aggregate["last_payload"] = payload.hex().upper()
            if error:
                aggregate["latest_error"] = error

    def flush_transmission_aggregates(self, now_s: float | None = None) -> None:
        current = time.monotonic() if now_s is None else now_s
        with self._aggregate_lock:
            if current - self._aggregate_window_s < 1.0:
                return
            aggregates = self._aggregates
            self._aggregates = {}
            window_start = self._aggregate_window_s
            self._aggregate_window_s = current
        for (source, _can_id), detail in sorted(aggregates.items()):
            self.emit_event(
                "transmission_aggregate",
                source,
                window_start_monotonic_s=window_start,
                window_end_monotonic_s=current,
                **detail,
            )

    def submit(
        self,
        *,
        kind: str,
        payload: dict[str, Any],
        expected_revision: int,
        request_id: str,
    ) -> Future[dict[str, Any]]:
        if self._closed:
            raise GatewayRuntimeError("runtime_closed", "gateway is shutting down", status=503)
        fingerprint = json.dumps(
            {"kind": kind, "expected_revision": expected_revision, "payload": payload},
            sort_keys=True,
            separators=(",", ":"),
            allow_nan=False,
        )
        with self._cache_lock:
            cached = self._command_cache.get(request_id)
            if cached is not None:
                if cached[0] != fingerprint:
                    raise GatewayRuntimeError(
                        "request_id_conflict",
                        "request ID was reused with different content",
                        status=409,
                    )
                self._command_cache.move_to_end(request_id)
                return cached[1]
            future: Future[dict[str, Any]] = Future()
            command = GatewayCommand(request_id, kind, expected_revision, dict(payload), future)
            self._command_cache[request_id] = (fingerprint, future)
            while len(self._command_cache) > COMMAND_CACHE_CAPACITY:
                self._command_cache.popitem(last=False)
            try:
                self._commands.put_nowait(command)
            except queue.Full as exc:
                self._command_cache.pop(request_id, None)
                raise GatewayRuntimeError(
                    "command_queue_full", "gateway command queue is full", status=503
                ) from exc
        with suppress(BlockingIOError, OSError):
            self._wakeup_write.send(b"\x01")
        return future

    def take_commands(self, maximum: int = 8) -> list[GatewayCommand]:
        commands: list[GatewayCommand] = []
        for _ in range(maximum):
            try:
                commands.append(self._commands.get_nowait())
            except queue.Empty:
                break
        return commands

    def complete(self, command: GatewayCommand, result: dict[str, Any]) -> None:
        if not command.future.done():
            command.future.set_result(dict(result))

    def fail(self, command: GatewayCommand, error: GatewayRuntimeError) -> None:
        if not command.future.done():
            command.future.set_exception(error)

    def require_revision(self, command: GatewayCommand) -> None:
        current = self.snapshot().revision
        if command.expected_revision != current:
            raise GatewayRuntimeError(
                "stale_revision",
                f"expected revision {command.expected_revision}, current revision is {current}",
                status=409,
            )

    def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        error = GatewayRuntimeError("runtime_closed", "gateway is shutting down", status=503)
        for command in self.take_commands(COMMAND_QUEUE_CAPACITY):
            self.fail(command, error)
        self.flush_transmission_aggregates(max(time.monotonic(), self._aggregate_window_s + 1.0))
        self._wakeup_read.close()
        self._wakeup_write.close()
        self.events.close()
