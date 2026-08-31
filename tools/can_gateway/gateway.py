"""CAN telemetry gateway: sim UDP packets -> SY135C CAN frames -> CSV / SocketCAN.

Reverse of GuideSystem/services/can ProtocolParser decode logic.
See .trellis/tasks/08-25-can-telemetry-gateway/design.md for the byte layouts.
"""

from __future__ import annotations

import argparse
import contextlib
import ipaddress
import math
import select
import socket
import struct
import sys
import time
import webbrowser
from collections.abc import Callable
from pathlib import Path

from can0_setup import CAN_INTERFACE, Can0SetupError, prepare_can0, restart_can0
from can_console import CanConsoleRuntime, canonical_can_key
from control_protocol import (
    CMD_ICT_START,
    CMD_ICT_STOP,
    CMD_RECORD_START,
    CMD_RECORD_STOP,
    CMD_SHUTDOWN,
    CMD_TIMED_CAN_START,
    ICT_ERR_INTERFACE_MISSING,
    ICT_ERR_INTERFACE_NOT_READY,
    ICT_ERR_INTERNAL,
    ICT_ERR_SEND,
    ICT_ERR_SETUP_FAILED,
    ICT_ERR_SETUP_PRIVILEGE,
    ICT_ERR_SOCKET_BIND,
    ICT_ERR_SOCKET_OPEN,
    ICT_ERR_UNSUPPORTED_TRANSPORT,
    ICT_OK,
    build_heartbeat,
    build_ict_result,
    build_session_done,
    parse_control_packet,
)
from conventions import (
    DEFAULT_MODEL,
    IMU_MOUNT_COMPENSATION_DEG,
    MachineState,
    TelemetrySample,
    parse_packet,
)
from csv_writer import CanapeCsvWriter
from dbc_engine import (
    DbcCodec,
    OperatorDbcRuntime,
    encode_godot_imu,
    encode_godot_rtk,
    load_protocol_codec,
)
from encoders.dxg_slew import encode_slew_frame
from encoders.ruifen_imu import RUFINEN_IDS
from encoders.travel_pilot import encode_travel_frame
from gateway_runtime import (
    RUNTIME_MODES,
    GatewayCommand,
    GatewayConfigStore,
    GatewayRuntimeCore,
    GatewayRuntimeError,
)
from gateway_web import DEFAULT_WEB_PORT, GatewayWebServer
from pc001_sink import TcpPc001Sink
from qml_compat import QmlCanMapper, QmlMappingError, QmlRtkState
from qml_profile import QmlProfileError, load_qml_profile, resource_root
from sinks import CsvFrameSink, FrameSink, SocketCanDelta, SocketCanSink
from vcan_setup import VcanSetupError, ensure_vcan_interface

PACKET_MAGIC = 0x314E5443
HEARTBEAT_INTERVAL_S = 0.5
RECEIVE_POLL_LIMIT_S = 0.05
TIMED_CAN_ID = 0x18FFF100
TIMED_CAN_PAYLOAD = bytes.fromhex("01 00 00 00 00 00 00 00")
TIMED_CAN_PERIOD_S = 1.0 / 50.0
TIMED_CAN_DURATION_S = 10.0
TIMED_CAN_FRAME_COUNT = 500
_PROTOCOL_CODEC: DbcCodec | None = None


def protocol_codec() -> DbcCodec:
    global _PROTOCOL_CODEC
    if _PROTOCOL_CODEC is None:
        _PROTOCOL_CODEC = load_protocol_codec(resource_root() / "dbc")
    return _PROTOCOL_CODEC


def append_frame(
    sink: FrameSink,
    can_id: int,
    payload: bytes,
    *,
    source: str,
    family: str,
    generation: int | None = None,
    is_extended: bool | None = None,
) -> None:
    if isinstance(sink, SocketCanSink):
        sink.submit(
            can_id,
            payload,
            source=source,
            family=family,
            generation=generation,
            is_extended=is_extended,
        )
    elif isinstance(sink, TcpPc001Sink):
        sink.submit(
            can_id,
            payload,
            source=source,
            family=family,
            is_extended=is_extended,
        )
    else:
        sink.append(can_id, payload)


class FrameScheduler:
    """Rate-limited emission groups keyed by frame family."""

    def __init__(self, rates_hz: dict[str, float]) -> None:
        self._periods_ms = {name: 1000.0 / hz for name, hz in rates_hz.items()}
        self._next_due_ms = {name: 0.0 for name in rates_hz}

    def due(self, name: str, tick_ms: float) -> bool:
        return tick_ms + 1e-6 >= self._next_due_ms[name]

    def advance(self, name: str, tick_ms: float) -> None:
        period = self._periods_ms[name]
        due = self._next_due_ms[name]
        self._next_due_ms[name] = max(tick_ms, due) + period if due > 0 else tick_ms + period


class TimedCanBurst:
    """One restartable fixed-rate CAN burst driven by monotonic seconds."""

    def __init__(self) -> None:
        self._next_due_s: float | None = None
        self._end_s: float | None = None
        self._emitted = 0
        self._generation = 0

    @property
    def active(self) -> bool:
        return self._next_due_s is not None

    @property
    def emitted_count(self) -> int:
        return self._emitted

    @property
    def active_generation(self) -> int | None:
        return self._generation if self.active else None

    def trigger(self, now_s: float) -> None:
        self._generation += 1
        self._next_due_s = now_s
        self._end_s = now_s + TIMED_CAN_DURATION_S
        self._emitted = 0

    def disarm(self) -> None:
        """Stop the active burst without preserving a resumable due time."""
        self._next_due_s = None
        self._end_s = None

    def timeout_s(self, now_s: float, maximum_s: float = RECEIVE_POLL_LIMIT_S) -> float:
        if self._next_due_s is None:
            return maximum_s
        return max(0.0, min(maximum_s, self._next_due_s - now_s))

    def service(
        self,
        now_s: float,
        sinks: list[FrameSink],
        observer: Callable[[int, bytes], None] | None = None,
    ) -> bool:
        due_s = self._next_due_s
        end_s = self._end_s
        if end_s is not None and now_s >= end_s:
            self._next_due_s = None
            self._end_s = None
            return False
        if due_s is None or now_s + 1e-9 < due_s:
            return False
        for sink in sinks:
            append_frame(
                sink,
                TIMED_CAN_ID,
                TIMED_CAN_PAYLOAD,
                source="timed",
                family="timed",
                generation=self._generation,
            )
        if observer is not None:
            observer(TIMED_CAN_ID, TIMED_CAN_PAYLOAD)
        self._emitted += 1
        if self._emitted >= TIMED_CAN_FRAME_COUNT:
            self._next_due_s = None
            self._end_s = None
        else:
            # Do not burst missed wall-time slots. The next real emission stays
            # at 50 Hz from whichever slot the gateway was able to service.
            self._next_due_s = max(due_s + TIMED_CAN_PERIOD_S, now_s + TIMED_CAN_PERIOD_S)
        return True


def _retire_failed_socketcan_sink(
    sink: FrameSink | None,
    *,
    active_ict_seq: int | None,
    stop_timed: Callable[[str], None],
    operator_dbc: OperatorDbcRuntime,
    publish_operator_dbc: Callable[[], None],
    preserve_totals: Callable[[FrameSink | None], None],
    send_ict_result: Callable[[int, int, str], None],
    core: GatewayRuntimeCore,
) -> bool:
    if not isinstance(sink, SocketCanSink) or sink.last_send_error is None:
        return False
    detail = f"SocketCAN send failed on {sink.interface}: {sink.last_send_error}"
    print(detail, file=sys.stderr)
    stop_timed("terminal_error")
    sink.purge(reason="terminal_error")
    preserve_totals(sink)
    sink.close()
    operator_dbc.stop()
    publish_operator_dbc()
    core.publish(
        transport_state="error",
        transport_detail=detail,
        ict_active=False,
        periodic_armed=False,
    )
    core.emit_event(
        "transport_error",
        "socketcan",
        code="socketcan_send_failed",
        detail=detail,
    )
    if active_ict_seq is not None:
        send_ict_result(active_ict_seq, ICT_ERR_SEND, detail)
    return True


def run(args: argparse.Namespace, qml_mapper: QmlCanMapper | None = None) -> int:
    rates = {
        "imu": args.imu_hz,
        "slew": args.slew_hz,
        "rtk": args.rtk_hz,
        "travel": args.travel_hz,
    }
    scheduler = FrameScheduler(rates)
    timed_can = TimedCanBurst()
    out_path = Path(args.out)
    out_path.mkdir(parents=True, exist_ok=True)

    try:
        protocol = protocol_codec()
        adjacent_root = (
            Path(sys.executable).resolve().parent / "dbc"
            if getattr(sys, "frozen", False)
            else Path(__file__).resolve().parent / "dbc"
        )
        operator_roots = [resource_root() / "dbc"]
        if getattr(sys, "frozen", False) or adjacent_root.is_dir():
            operator_roots.append(adjacent_root)
        operator_roots.extend(Path(path) for path in getattr(args, "dbc_dir", []))
        operator_dbc = OperatorDbcRuntime(operator_roots)
        simulation_rates = {
            **{can_id: float(args.imu_hz) for can_id in RUFINEN_IDS.values()},
            **{can_id: float(args.rtk_hz) for can_id in range(0x0CFDA000, 0x0CFDAA00, 0x100)},
            0x18FFF000: float(args.slew_hz),
            0x256: float(args.travel_hz),
        }
        can_console = CanConsoleRuntime(
            operator_dbc,
            mode=args.mode,
            simulation_rates=simulation_rates,
        )
    except GatewayRuntimeError as exc:
        print(f"Gateway DBC startup failed ({exc.code}): {exc}", file=sys.stderr)
        return 1

    platform_name = "windows" if sys.platform == "win32" else "linux"
    core = GatewayRuntimeCore(
        mode=args.mode,
        platform=platform_name,
        transport_kind=args.sink,
        tcp_host=args.tcp_host,
        tcp_port=args.tcp_port,
        can_interface=args.interface,
    )
    core.publish_dbc_snapshot(operator_dbc.snapshot())
    core.publish_console_snapshot(can_console.snapshot())
    ict_sink: FrameSink | None = None
    if args.sink == "vcan":
        ict_sink = _open_vcan(args.interface)
        if ict_sink is None:
            core.close()
            return 1
    elif args.sink == "tcp":
        try:
            ict_sink = TcpPc001Sink(args.tcp_host, args.tcp_port)
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            core.close()
            return 1
    elif args.sink == "socketcan" and args.mode == "standalone":
        ict_sink, result_code, detail = _open_can0(args.interface)
        if ict_sink is None:
            print(f"standalone can0 startup failed ({result_code}): {detail}", file=sys.stderr)
            core.close()
            return 1

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.bind((args.host, args.port))
    except OSError as exc:
        print(f"cannot bind Gateway UDP {args.host}:{args.port}: {exc}", file=sys.stderr)
        if ict_sink is not None:
            ict_sink.close()
        core.close()
        return 1
    sock.setblocking(False)
    # Windows: ICMP port-unreachable (e.g. heartbeat before Godot binds the
    # ack port) surfaces as ConnectionResetError on the next recvfrom.
    with contextlib.suppress(AttributeError, OSError):
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)
    ack_addr = (args.host if args.host != "0.0.0.0" else "127.0.0.1", args.ack_port)

    writer: CanapeCsvWriter | None = None
    recording = False
    last_heartbeat_s = 0.0
    active_ict_seq: int | None = None
    last_ict_result: tuple[int, bytes] | None = None
    socketcan_guard_until_s = 0.0
    socketcan_totals = {
        "submitted": 0,
        "sent": 0,
        "congestion_dropped": 0,
        "coalesced": 0,
        "terminal_error": 0,
    }
    last_pc001_handshake = False
    platform_linux = platform_name == "linux"
    initial_transport_state = "ready" if ict_sink is not None else "stopped"
    core.publish(
        transport_state=initial_transport_state,
        transport_detail=ict_sink.peer_name() if ict_sink is not None else "",
        ict_active=args.mode == "standalone" and ict_sink is not None,
    )
    core.emit_event(
        "gateway_started",
        "runtime",
        mode=args.mode,
        platform=platform_name,
        transport=args.sink,
    )

    web_server = GatewayWebServer(
        core,
        port=args.web_port,
        static_root=resource_root() / "web",
    )
    try:
        web_server.start()
    except RuntimeError as exc:
        print(str(exc), file=sys.stderr)
        if ict_sink is not None:
            ict_sink.close()
        sock.close()
        core.close()
        return 1
    print(f"Gateway Web console: {web_server.url}")
    if args.open_browser and args.mode == "standalone":
        webbrowser.open(web_server.url)
    print(f"gateway listening on {args.host}:{args.port} (out={out_path}, sink={args.sink})")

    def active_sinks() -> list[FrameSink]:
        sinks: list[FrameSink] = []
        if recording and writer is not None:
            sinks.append(CsvFrameSink(writer))
        if ict_sink is not None and (
            not isinstance(ict_sink, SocketCanSink) or time.monotonic() >= socketcan_guard_until_s
        ):
            sinks.append(ict_sink)
        return sinks

    def observe_transmission(source: str) -> Callable[[int, bytes], None]:
        def observe(can_id: int, payload: bytes) -> None:
            recording_ready = recording and writer is not None
            transport_ready = ict_sink is not None
            error = ""
            if isinstance(ict_sink, TcpPc001Sink):
                transport_ready = ict_sink.is_handshake_connected()
                if not transport_ready:
                    error = "PC001 handshake is not connected"
            elif isinstance(ict_sink, SocketCanSink):
                # Physical SocketCAN outcomes are recorded only by the
                # non-blocking service boundary, never inferred from submit or CSV.
                return
            success = recording_ready or transport_ready
            if not success and not error:
                error = "no active frame sink"
            core.record_transmission(
                source=source,
                can_id=can_id,
                payload=payload,
                success=success,
                error=error,
            )

        return observe

    observe_godot = observe_transmission("godot")
    observe_timed = observe_transmission("timed")
    observe_web = observe_transmission("web")

    def record_egress(
        source: str,
        family: str,
        can_id: int,
        is_extended: bool,
        payload: bytes,
        monotonic_s: float | None = None,
    ) -> None:
        authority = "simulation" if source == "godot" else "custom" if source == "web" else source
        core.record_egress(
            key=canonical_can_key(can_id, is_extended),
            source=source,
            authority=authority,
            payload=payload,
            values=can_console.decode_egress(can_id, payload, is_extended=is_extended),
            monotonic_s=monotonic_s,
        )

    def attach_tcp_observer(candidate: FrameSink | None) -> None:
        if isinstance(candidate, TcpPc001Sink):
            candidate.set_egress_observer(record_egress)

    def record_socketcan_delta(delta: SocketCanDelta) -> None:
        core.record_socketcan_outcome(
            source=delta.source,
            family=delta.family,
            can_id=delta.can_id,
            payload=delta.payload,
            outcome=delta.outcome,
            reason=delta.reason,
        )
        if delta.outcome == "sent":
            record_egress(
                delta.source,
                delta.family,
                delta.can_id,
                delta.is_extended,
                delta.payload,
            )

    def attach_socketcan_observer(candidate: FrameSink | None) -> None:
        if isinstance(candidate, SocketCanSink):
            candidate.set_outcome_observer(record_socketcan_delta)

    def preserve_socketcan_totals(candidate: FrameSink | None) -> None:
        if not isinstance(candidate, SocketCanSink):
            return
        snapshot = candidate.stats
        for name in socketcan_totals:
            socketcan_totals[name] += getattr(snapshot, name)

    attach_socketcan_observer(ict_sink)
    attach_tcp_observer(ict_sink)

    def transport_ready() -> bool:
        if isinstance(ict_sink, TcpPc001Sink):
            return ict_sink.is_handshake_connected()
        return isinstance(ict_sink, SocketCanSink) and ict_sink.last_send_error is None

    def publish_operator_dbc(*, mutate_revision: bool = False) -> None:
        core.publish_dbc_snapshot(
            operator_dbc.snapshot(),
            periodic_armed=operator_dbc.armed,
            mutate_revision=mutate_revision,
        )

    def publish_can_console(*, mutate_revision: bool = False) -> None:
        core.publish_console_snapshot(can_console.snapshot(), mutate_revision=mutate_revision)

    def send_operator_frame(_key: str, can_id: int, payload: bytes) -> None:
        if not transport_ready():
            operator_dbc.stop()
            publish_operator_dbc()
            if args.mode == "godot-managed":
                can_console.reset_managed_overrides()
            else:
                can_console.stop()
            publish_can_console()
            return
        assert ict_sink is not None
        console_entry = can_console.entries.get(_key)
        is_extended = (
            console_entry.is_extended
            if console_entry is not None
            else operator_dbc.codec.messages[_key].is_extended
        )
        append_frame(
            ict_sink,
            can_id,
            payload,
            source="web",
            family="dbc",
            is_extended=is_extended,
        )
        observe_web(can_id, payload)

    def send_ict_result(request_seq: int, result_code: int, detail: str = "") -> None:
        nonlocal last_ict_result
        bounded_detail = detail.encode("utf-8")[:160].decode("utf-8", errors="ignore")
        packet = build_ict_result(request_seq, result_code, bounded_detail)
        sock.sendto(packet, ack_addr)
        last_ict_result = (request_seq, packet)

    def purge_socketcan_timed(generation: int | None, reason: str) -> None:
        if generation is not None and isinstance(ict_sink, SocketCanSink):
            ict_sink.purge(generation=generation, family="timed", reason=reason)

    def stop_timed(reason: str) -> None:
        generation = timed_can.active_generation
        timed_can.disarm()
        purge_socketcan_timed(generation, reason)

    def retire_failed_socketcan() -> None:
        nonlocal ict_sink, active_ict_seq
        retired = _retire_failed_socketcan_sink(
            ict_sink,
            active_ict_seq=active_ict_seq,
            stop_timed=stop_timed,
            operator_dbc=operator_dbc,
            publish_operator_dbc=publish_operator_dbc,
            preserve_totals=preserve_socketcan_totals,
            send_ict_result=send_ict_result,
            core=core,
        )
        if retired:
            if args.mode == "godot-managed":
                can_console.reset_managed_overrides()
            else:
                can_console.stop()
            publish_can_console()
            ict_sink = None
            active_ict_seq = None

    def refresh_runtime_status() -> None:
        nonlocal last_pc001_handshake
        pc001 = ict_sink.status_snapshot() if isinstance(ict_sink, TcpPc001Sink) else None
        socketcan = ict_sink.stats if isinstance(ict_sink, SocketCanSink) else None

        def socketcan_value(name: str) -> int:
            return socketcan_totals[name] + (
                getattr(socketcan, name) if socketcan is not None else 0
            )

        handshake_connected = pc001.handshake_connected if pc001 is not None else False
        if handshake_connected != last_pc001_handshake:
            core.emit_event(
                "pc001_connected" if handshake_connected else "pc001_disconnected",
                "transport",
            )
            last_pc001_handshake = handshake_connected
            if not handshake_connected and can_console.armed:
                operator_dbc.stop()
                publish_operator_dbc()
                if args.mode == "godot-managed":
                    can_console.reset_managed_overrides()
                else:
                    can_console.stop()
                publish_can_console()
        core.publish(
            recording=recording,
            timed_can_active=timed_can.active,
            ict_active=active_ict_seq is not None
            or (args.mode == "standalone" and ict_sink is not None),
            pc001_handshake=handshake_connected,
            pc001_queued_frames=pc001.queued_frames if pc001 is not None else 0,
            pc001_sent_frames=pc001.sent_frames if pc001 is not None else 0,
            pc001_dropped_frames=pc001.dropped_frames if pc001 is not None else 0,
            socketcan_submitted=socketcan_value("submitted"),
            socketcan_sent=socketcan_value("sent"),
            socketcan_congestion_dropped=socketcan_value("congestion_dropped"),
            socketcan_coalesced=socketcan_value("coalesced"),
            socketcan_terminal_errors=socketcan_value("terminal_error"),
            socketcan_pending=socketcan.pending if socketcan is not None else 0,
        )

    def validate_tcp_host(value: object) -> str:
        if not isinstance(value, str):
            raise GatewayRuntimeError("tcp_host_invalid", "TCP host must be a string")
        normalized = value.strip() or "0.0.0.0"
        if normalized != "localhost":
            try:
                ipaddress.IPv4Address(normalized)
            except ipaddress.AddressValueError as exc:
                raise GatewayRuntimeError(
                    "tcp_host_invalid", "TCP host must be IPv4 or localhost"
                ) from exc
        return normalized

    def handle_runtime_command(command: GatewayCommand) -> None:
        nonlocal can_console, ict_sink, active_ict_seq, socketcan_guard_until_s
        try:
            if command.kind not in {
                "dbc_message_preview",
                "console_message_preview",
                "console_export",
            }:
                core.require_revision(command)
            if command.kind == "tcp_rebind":
                host = validate_tcp_host(command.payload.get("host"))
                port = command.payload.get("port")
                if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65_535:
                    raise GatewayRuntimeError(
                        "tcp_port_invalid", "TCP port must be an integer in 1..65535"
                    )
                stop_timed("transport_reconfigure")
                operator_dbc.stop()
                publish_operator_dbc()
                can_console.stop()
                publish_can_console()
                core.publish(
                    transport_state="reconfiguring",
                    transport_detail=f"rebinding TCP {host}:{port}",
                    periodic_armed=False,
                    ict_active=False,
                )
                if ict_sink is not None:
                    if isinstance(ict_sink, SocketCanSink):
                        ict_sink.purge(reason="transport_reconfigure")
                        preserve_socketcan_totals(ict_sink)
                    ict_sink.close()
                    ict_sink = None
                active_ict_seq = None
                try:
                    replacement = TcpPc001Sink(host, port)
                except RuntimeError as exc:
                    core.publish(transport_state="error", transport_detail=str(exc))
                    core.emit_event(
                        "transport_error", "web", code="tcp_bind_failed", detail=str(exc)
                    )
                    raise GatewayRuntimeError("tcp_bind_failed", str(exc), status=409) from exc
                try:
                    core.config.save_tcp_endpoint(host, port)
                except OSError as exc:
                    replacement.close()
                    core.publish(
                        transport_state="error",
                        transport_detail=f"TCP endpoint persistence failed: {exc}",
                    )
                    raise GatewayRuntimeError(
                        "config_write_failed", "TCP endpoint could not be persisted", status=500
                    ) from exc
                ict_sink = replacement
                attach_tcp_observer(ict_sink)
                status = core.publish(
                    mutate_revision=True,
                    transport_kind="tcp",
                    transport_state="ready",
                    transport_detail=replacement.peer_name(),
                    tcp_host=host,
                    tcp_port=port,
                )
                core.emit_event(
                    "transport_reconfigured", "web", transport="tcp", host=host, port=port
                )
                core.complete(command, {"status": status.to_dict()})
                return
            if command.kind == "can0_restart":
                stop_timed("transport_reconfigure")
                operator_dbc.stop()
                publish_operator_dbc()
                can_console.stop()
                publish_can_console()
                core.publish(
                    transport_state="reconfiguring",
                    transport_detail="restarting fixed can0 contract",
                    periodic_armed=False,
                    ict_active=False,
                )
                if ict_sink is not None:
                    if isinstance(ict_sink, SocketCanSink):
                        ict_sink.purge(reason="transport_reconfigure")
                        preserve_socketcan_totals(ict_sink)
                    ict_sink.close()
                    ict_sink = None
                active_ict_seq = None
                try:
                    restart_can0()
                    replacement = SocketCanSink(CAN_INTERFACE)
                except (Can0SetupError, RuntimeError) as exc:
                    code = (
                        exc.code.lower() if isinstance(exc, Can0SetupError) else "can0_bind_failed"
                    )
                    detail = f"{exc.code}: {exc}" if isinstance(exc, Can0SetupError) else str(exc)
                    core.publish(transport_state="error", transport_detail=detail)
                    core.emit_event("transport_error", "web", code=code, detail=detail)
                    raise GatewayRuntimeError(code, detail, status=409) from exc
                ict_sink = replacement
                attach_socketcan_observer(ict_sink)
                socketcan_guard_until_s = time.monotonic() + RECEIVE_POLL_LIMIT_S
                status = core.publish(
                    mutate_revision=True,
                    transport_kind="socketcan",
                    transport_state="ready",
                    transport_detail=replacement.peer_name(),
                )
                core.emit_event(
                    "transport_reconfigured", "web", transport="socketcan", interface=CAN_INTERFACE
                )
                core.complete(command, {"status": status.to_dict()})
                return
            if command.kind == "dbc_message_update":
                updated = operator_dbc.update_message(
                    str(command.payload.get("message_key", "")),
                    values=command.payload.get("values"),
                    payload_hex=command.payload.get("payload_hex"),
                    enabled=command.payload.get("enabled"),
                    frequency_hz=command.payload.get("frequency_hz"),
                )
                publish_operator_dbc(mutate_revision=True)
                core.emit_event(
                    "dbc_message_updated",
                    "web",
                    message_key=command.payload.get("message_key", ""),
                )
                core.complete(command, {"message": updated, "status": core.snapshot().to_dict()})
                return
            if command.kind == "dbc_message_preview":
                preview = operator_dbc.preview_message(
                    str(command.payload.get("message_key", "")),
                    values=command.payload.get("values"),
                    payload_hex=command.payload.get("payload_hex"),
                )
                core.complete(command, {"preview": preview})
                return
            if command.kind == "console_authority_update":
                operator_dbc.stop()
                publish_operator_dbc()
                key = str(command.payload.get("key", ""))
                previous = (
                    can_console.entries.get(key).authority if key in can_console.entries else None
                )
                updated = can_console.set_authority(key, command.payload.get("authority"))
                if isinstance(ict_sink, SocketCanSink):
                    ict_sink.purge(
                        can_id=updated["message"]["frame_id"],
                        is_extended=updated["message"]["is_extended"],
                        reason="authority_change",
                    )
                core.reset_egress_rate(key)
                publish_can_console(mutate_revision=True)
                core.emit_event(
                    "can_console_authority_updated",
                    "web",
                    key=key,
                    previous=previous,
                    authority=updated["authority"],
                )
                core.complete(command, {"message": updated, "status": core.snapshot().to_dict()})
                return
            if command.kind == "console_message_update":
                operator_dbc.stop()
                publish_operator_dbc()
                updated = can_console.update(
                    str(command.payload.get("key", "")),
                    values=command.payload.get("values"),
                    payload_hex=command.payload.get("payload_hex"),
                    frequency_hz=command.payload.get("frequency_hz"),
                )
                publish_can_console(mutate_revision=True)
                core.emit_event("can_console_message_updated", "web", key=updated["key"])
                core.complete(command, {"message": updated, "status": core.snapshot().to_dict()})
                return
            if command.kind == "console_message_preview":
                preview = can_console.preview(
                    str(command.payload.get("key", "")),
                    values=command.payload.get("values"),
                    payload_hex=command.payload.get("payload_hex"),
                )
                core.complete(command, {"preview": preview})
                return
            if command.kind == "console_start":
                operator_dbc.stop()
                publish_operator_dbc()
                can_console.start(transport_ready=transport_ready())
                publish_can_console(mutate_revision=True)
                core.emit_event("can_console_started", "web")
                core.complete(command, {"status": core.snapshot().to_dict()})
                return
            if command.kind == "console_stop":
                can_console.stop()
                publish_can_console(mutate_revision=True)
                core.emit_event("can_console_stopped", "web")
                core.complete(command, {"status": core.snapshot().to_dict()})
                return
            if command.kind == "console_export":
                core.complete(command, {"profile": can_console.export_profile()})
                return
            if command.kind == "console_import":
                profile = command.payload.get("profile")
                if not isinstance(profile, dict):
                    raise GatewayRuntimeError(
                        "console_profile_invalid", "profile must be an object"
                    )
                can_console.import_profile(profile)
                publish_can_console(mutate_revision=True)
                core.emit_event("can_console_profile_imported", "web")
                core.complete(command, {"status": core.snapshot().to_dict()})
                return
            if command.kind == "dbc_start":
                can_console.stop()
                publish_can_console()
                operator_dbc.start(transport_ready=transport_ready())
                publish_operator_dbc(mutate_revision=True)
                core.emit_event("dbc_started", "web")
                core.complete(command, {"status": core.snapshot().to_dict()})
                return
            if command.kind == "dbc_stop":
                operator_dbc.stop()
                publish_operator_dbc(mutate_revision=True)
                core.emit_event("dbc_stopped", "web")
                core.complete(command, {"status": core.snapshot().to_dict()})
                return
            if command.kind == "dbc_reload":
                operator_dbc.stop()
                operator_dbc.reload()
                can_console = CanConsoleRuntime(
                    operator_dbc,
                    mode=args.mode,
                    simulation_rates=simulation_rates,
                )
                publish_operator_dbc(mutate_revision=True)
                publish_can_console()
                core.emit_event("dbc_reloaded", "web")
                core.complete(
                    command,
                    {"dbc": core.dbc_snapshot(), "status": core.snapshot().to_dict()},
                )
                return
            raise GatewayRuntimeError(
                "command_unknown", f"unknown Gateway command {command.kind!r}"
            )
        except GatewayRuntimeError as exc:
            core.fail(command, exc)

    def drain_runtime_commands() -> None:
        core.consume_wakeup()
        for command in core.take_commands():
            handle_runtime_command(command)

    try:
        while True:
            drain_runtime_commands()
            monotonic_s = time.monotonic()
            timed_generation = timed_can.active_generation
            timed_emitted = timed_can.service(monotonic_s, active_sinks(), observe_timed)
            if timed_generation is not None and not timed_can.active and not timed_emitted:
                purge_socketcan_timed(timed_generation, "deadline")
            can_console.service(send_operator_frame, monotonic_s)
            operator_dbc.scheduler.service(send_operator_frame, monotonic_s)
            if isinstance(ict_sink, SocketCanSink) and monotonic_s >= socketcan_guard_until_s:
                ict_sink.service()
            if timed_generation is not None and not timed_can.active and timed_emitted:
                purge_socketcan_timed(timed_generation, "completed")
            retire_failed_socketcan()
            core.flush_transmission_aggregates(monotonic_s)
            core.flush_console_runtime(monotonic_s)
            refresh_runtime_status()
            now_s = time.time()
            if now_s - last_heartbeat_s >= HEARTBEAT_INTERVAL_S:
                ict_handshake = (
                    isinstance(ict_sink, TcpPc001Sink) and ict_sink.is_handshake_connected()
                )
                sock.sendto(
                    build_heartbeat(
                        int(now_s * 1000) & 0xFFFFFFFFFFFFFFFF,
                        recording,
                        platform_linux,
                        ict_handshake,
                    ),
                    ack_addr,
                )
                last_heartbeat_s = now_s
            timeout_s = min(
                timed_can.timeout_s(time.monotonic()),
                can_console.timeout_s(),
                operator_dbc.scheduler.timeout_s(),
            )
            try:
                readable, _writable, _exceptional = select.select(
                    [sock, core.wakeup_reader], [], [], timeout_s
                )
            except (OSError, ValueError):
                if core.wakeup_reader.fileno() < 0:
                    break
                raise
            if core.wakeup_reader in readable:
                drain_runtime_commands()
            if sock not in readable:
                continue
            try:
                data, _addr = sock.recvfrom(4096)
            except (BlockingIOError, TimeoutError, ConnectionResetError):
                continue

            control = parse_control_packet(data)
            if control is not None:
                cmd, request_seq = control
                if cmd == CMD_RECORD_START:
                    if writer is None:
                        stamp = time.strftime("%Y%m%d_%H%M%S")
                        csv_path = out_path / f"can_telemetry_{stamp}.csv"
                        writer = CanapeCsvWriter(csv_path)
                        print(f"recording -> {csv_path}")
                    recording = True
                    core.publish(recording=True)
                    core.emit_event("recording_started", "godot", path=str(writer.path))
                elif cmd == CMD_RECORD_STOP:
                    recording = False
                    if writer is not None:
                        writer.close()
                        sock.sendto(build_session_done(str(writer.path)), ack_addr)
                        print(f"segment saved: {writer.path}")
                        writer = None
                    print("recording stopped")
                    core.publish(recording=False)
                    core.emit_event("recording_stopped", "godot")
                elif cmd == CMD_ICT_START:
                    if last_ict_result is not None and last_ict_result[0] == request_seq:
                        sock.sendto(last_ict_result[1], ack_addr)
                        continue
                    result_code = ICT_OK
                    result_detail = ""
                    if ict_sink is None:
                        if args.sink == "socketcan":
                            ict_sink, result_code, result_detail = _open_can0(args.interface)
                            if ict_sink is not None:
                                attach_socketcan_observer(ict_sink)
                                # Give a timeout-triggered STOP, queued while the
                                # privileged helper was running, one receive turn
                                # before the first physical CAN frame can escape.
                                socketcan_guard_until_s = time.monotonic() + RECEIVE_POLL_LIMIT_S
                        elif args.sink == "vcan":
                            ict_sink = _open_vcan(args.interface)
                            attach_socketcan_observer(ict_sink)
                        elif args.sink == "csv":
                            result_code = ICT_ERR_UNSUPPORTED_TRANSPORT
                            result_detail = "gateway was started without an ICT transport"
                    if ict_sink is not None:
                        active_ict_seq = request_seq
                        print(f"ICT connected: {ict_sink.peer_name()}")
                    elif result_code == ICT_OK:
                        result_code = ICT_ERR_INTERNAL
                        result_detail = "ICT transport did not open"
                    send_ict_result(request_seq, result_code, result_detail)
                    core.publish(
                        transport_state="ready" if ict_sink is not None else "error",
                        transport_detail=ict_sink.peer_name()
                        if ict_sink is not None
                        else result_detail,
                        ict_active=ict_sink is not None,
                    )
                    core.emit_event(
                        "ict_result",
                        "godot",
                        request_seq=request_seq,
                        result_code=result_code,
                        detail=result_detail,
                    )
                elif cmd == CMD_ICT_STOP:
                    stop_timed("ict_stop")
                    operator_dbc.stop()
                    publish_operator_dbc()
                    if args.mode == "godot-managed":
                        can_console.reset_managed_overrides()
                    else:
                        can_console.stop()
                    publish_can_console()
                    if ict_sink is not None and args.sink in ("vcan", "socketcan"):
                        # TCP stays listening across ICT stop; SocketCAN closes.
                        if isinstance(ict_sink, SocketCanSink):
                            ict_sink.purge(reason="ict_stop")
                            preserve_socketcan_totals(ict_sink)
                        ict_sink.close()
                        ict_sink = None
                    active_ict_seq = None
                    print("ICT disconnected")
                    core.publish(ict_active=False, periodic_armed=False)
                    core.emit_event("ict_stopped", "godot")
                elif cmd == CMD_SHUTDOWN:
                    stop_timed("shutdown")
                    operator_dbc.stop()
                    publish_operator_dbc()
                    can_console.stop()
                    publish_can_console()
                    print("shutdown requested")
                    break
                elif cmd == CMD_TIMED_CAN_START:
                    stop_timed("retrigger")
                    timed_can.trigger(time.monotonic())
                    timed_can.service(time.monotonic(), active_sinks(), observe_timed)
                    print("timed CAN burst started: 0x18FFF100 at 50 Hz for 10 s")
                    core.publish(timed_can_active=True)
                    core.emit_event("timed_can_started", "godot", can_id="0x18FFF100")
                continue

            sample = parse_packet(data)
            if sample is None:
                print("bad packet (magic/version/size), dropped", file=sys.stderr)
                continue
            sinks = active_sinks()
            if sinks:
                try:
                    emit_frames(
                        sinks,
                        scheduler,
                        sample,
                        args.rtk_byteorder,
                        args.model,
                        qml_mapper,
                        observe_godot,
                        protocol,
                        can_console.allows,
                    )
                    retire_failed_socketcan()
                except QmlMappingError as exc:
                    print(f"QML mapping rejected telemetry sample: {exc}", file=sys.stderr)
                    continue
                csv_rows = writer.row_count if writer is not None else 0
                if args.max_rows and csv_rows >= args.max_rows:
                    break
    except KeyboardInterrupt:
        pass
    finally:
        rows = writer.row_count if writer is not None else 0
        path = writer._path if writer is not None else "(no session)"
        stop_timed("shutdown")
        web_server.close()
        if writer is not None:
            writer.close()
        if ict_sink is not None:
            if isinstance(ict_sink, SocketCanSink):
                ict_sink.purge(reason="shutdown")
                preserve_socketcan_totals(ict_sink)
            ict_sink.close()
        print(f"closed {path} ({rows} frames)")
        sock.close()
        core.emit_event("gateway_stopped", "runtime", rows=rows)
        core.close()
    return 0


def _open_vcan(interface: str) -> SocketCanSink | None:
    try:
        ensure_vcan_interface(interface)
        return SocketCanSink(interface, setup_check=False)
    except (RuntimeError, VcanSetupError) as exc:
        detail = str(exc).strip()
        hint = ""
        if isinstance(exc, OSError) or "AF_CAN" in detail or "No such device" in detail:
            hint = (
                " (WSL2 default kernels lack CONFIG_CAN/VCAN; run on real Linux "
                "or a CAN-enabled kernel)"
            )
        print(f"vcan open failed for '{interface}': {detail}{hint}", file=sys.stderr)
        return None


def _open_can0(interface: str) -> tuple[SocketCanSink | None, int, str]:
    if interface != CAN_INTERFACE:
        return None, ICT_ERR_SETUP_FAILED, f"physical ICT interface must be {CAN_INTERFACE}"
    try:
        prepare_can0()
    except Can0SetupError as exc:
        code_map = {
            "CAN0_MISSING": ICT_ERR_INTERFACE_MISSING,
            "CAN0_HELPER_MISSING": ICT_ERR_SETUP_PRIVILEGE,
            "CAN0_PRIVILEGE": ICT_ERR_SETUP_PRIVILEGE,
            "CAN0_NOT_READY": ICT_ERR_INTERFACE_NOT_READY,
        }
        result_code = code_map.get(exc.code, ICT_ERR_SETUP_FAILED)
        detail = f"{exc.code}: {exc}"
        print(detail, file=sys.stderr)
        return None, result_code, detail
    try:
        return SocketCanSink(interface), ICT_OK, ""
    except RuntimeError as exc:
        detail = str(exc).strip()
        result_code = ICT_ERR_SOCKET_OPEN if "AF_CAN" in detail else ICT_ERR_SOCKET_BIND
        print(detail, file=sys.stderr)
        return None, result_code, detail


def emit_frames(
    sinks: list[FrameSink],
    scheduler: FrameScheduler,
    sample: TelemetrySample,
    rtk_byteorder: str = "little",
    model: str = DEFAULT_MODEL,
    qml_mapper: QmlCanMapper | None = None,
    observer: Callable[[int, bytes], None] | None = None,
    dbc_codec: DbcCodec | None = None,
    authority_allows: Callable[[str, int, bool], bool] | None = None,
) -> None:
    codec = dbc_codec or protocol_codec()
    state = MachineState(sample, model=model)
    projection = qml_mapper.project(sample) if qml_mapper is not None else None
    tick = float(sample.tick_ms)
    pending: list[tuple[str, int, bool, bytes]] = []

    if scheduler.due("imu", tick):
        for link in ("body", "boom", "arm", "bucket"):
            if projection is None:
                roll, pitch, yaw = state.link_rpy(link)
            else:
                roll, pitch, yaw = projection.imu_rpy_deg[link]
            slots = state.sensor_slots(roll, pitch, yaw)
            can_id = RUFINEN_IDS[link]
            pending.append(("imu", can_id, True, encode_godot_imu(codec, can_id, slots)))

    if scheduler.due("slew", tick):
        pending.append(("slew", 0x18FFF000, True, encode_slew_frame(state.slew_degrees())))

    if scheduler.due("travel", tick):
        left, right = state.travel_pressures()
        pending.append(("travel", 0x256, False, encode_travel_frame(left, right)))

    if scheduler.due("rtk", tick):
        rtk_state = state if projection is None else QmlRtkState(projection)
        satellite_status = 0 if projection is None else projection.satellite_status
        for can_id, payload in encode_godot_rtk(
            codec,
            rtk_state,
            satellite_status=satellite_status,
        ).items():
            pending.append(("rtk", can_id, True, payload))

    # Finish all profile math and encoding before exposing any frame. A bad
    # telemetry sample must never produce a partial CAN family.
    for family, can_id, is_extended, payload in pending:
        if authority_allows is not None and not authority_allows("godot", can_id, is_extended):
            continue
        for sink in sinks:
            append_frame(
                sink,
                can_id,
                payload,
                source="godot",
                family=family,
                is_extended=is_extended,
            )
        if observer is not None:
            observer(can_id, payload)

    if scheduler.due("imu", tick):
        scheduler.advance("imu", tick)
    if scheduler.due("slew", tick):
        scheduler.advance("slew", tick)
    if scheduler.due("travel", tick):
        scheduler.advance("travel", tick)
    if scheduler.due("rtk", tick):
        scheduler.advance("rtk", tick)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=29764)
    parser.add_argument("--mode", choices=RUNTIME_MODES, default="standalone")
    parser.add_argument("--web-port", type=int, default=DEFAULT_WEB_PORT)
    parser.add_argument(
        "--open-browser",
        action="store_true",
        help="open the loopback Web console after standalone startup",
    )
    parser.add_argument("--out", default="output/can_gateway")
    parser.add_argument("--imu-hz", type=float, default=100.0)
    parser.add_argument("--slew-hz", type=float, default=100.0)
    parser.add_argument("--rtk-hz", type=float, default=10.0)
    parser.add_argument("--travel-hz", type=float, default=10.0)
    parser.add_argument("--max-rows", type=int, default=0, help="stop after N rows (smoke)")
    parser.add_argument(
        "--rtk-byteorder",
        choices=("little",),
        default="little",
        help="deprecated compatibility option; approved DBC byte order is fixed to little",
    )
    parser.add_argument(
        "--dbc-dir",
        action="append",
        default=[],
        help="additional direct-child DBC directory (repeatable; startup/reload scan only)",
    )
    parser.add_argument(
        "--model",
        choices=tuple(IMU_MOUNT_COMPENSATION_DEG),
        default=DEFAULT_MODEL,
        help="machine model selecting the IMU zero-mount compensation table",
    )
    parser.add_argument(
        "--compat-profile",
        default=None,
        help="strict CAN semantic profile (for example builtin:qml-sy135-ground-truth)",
    )
    parser.add_argument(
        "--qml-calibration",
        default=None,
        help="optional QML calibration TOML override; SHA-256 must match the selected profile",
    )
    parser.add_argument("--ack-port", type=int, default=29765, help="heartbeat destination port")
    parser.add_argument(
        "--sink",
        choices=("csv", "socketcan", "vcan", "tcp"),
        default=None,
        help="frame output override; standalone defaults to Windows TCP or Linux can0",
    )
    parser.add_argument(
        "--interface", default="can0", help="SocketCAN interface (physical ICT is fixed to can0)"
    )
    parser.add_argument(
        "--tcp-host", default="0.0.0.0", help="listen address for --sink tcp (PC001)"
    )
    parser.add_argument(
        "--tcp-port", type=int, default=5678, help="listen port for --sink tcp (PC001)"
    )
    parser.add_argument(
        "--setup-vcan",
        action="store_true",
        help="create/bring up the vcan interface, then exit",
    )
    parser.add_argument("--smoke", action="store_true", help="self-inject synthetic packets")
    args = parser.parse_args(argv)

    if not 1 <= args.web_port <= 65_535:
        parser.error("--web-port must be in 1..65535")
    if args.sink is None:
        args.sink = "tcp" if sys.platform == "win32" else "socketcan"
    if (
        args.mode == "standalone"
        and sys.platform == "win32"
        and args.sink == "tcp"
        and args.tcp_host == "0.0.0.0"
        and args.tcp_port == 5678
    ):
        args.tcp_host, args.tcp_port = GatewayConfigStore().load_tcp_endpoint(
            args.tcp_host, args.tcp_port
        )

    if args.setup_vcan:
        try:
            ensure_vcan_interface(args.interface)
        except VcanSetupError as exc:
            print(f"vcan setup failed: {exc}", file=sys.stderr)
            return 1
        print(f"SocketCAN interface ready: {args.interface}")
        return 0

    if args.qml_calibration and not args.compat_profile:
        print("--qml-calibration requires --compat-profile", file=sys.stderr)
        return 1
    qml_mapper: QmlCanMapper | None = None
    if args.compat_profile:
        try:
            profile = load_qml_profile(args.compat_profile, args.qml_calibration)
        except QmlProfileError as exc:
            print(f"QML compatibility profile rejected: {exc}", file=sys.stderr)
            return 1
        if args.model != profile.model_id:
            print(
                "QML compatibility profile model "
                f"{profile.model_id!r} conflicts with --model {args.model!r}",
                file=sys.stderr,
            )
            return 1
        qml_mapper = QmlCanMapper(profile)
        print(
            "QML compatibility profile active: "
            f"version={profile.version} model={profile.model_id} "
            f"calibration_sha256={profile.calibration_sha256}"
        )

    if args.max_rows:
        # Smoke mode: synthesize packets locally instead of waiting on the game.
        return run_smoke(args, qml_mapper)
    return run(args, qml_mapper)


def run_smoke(args: argparse.Namespace, qml_mapper: QmlCanMapper | None = None) -> int:
    sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver_run = run_with_injection(args, sender, qml_mapper)
    sender.close()
    return receiver_run


def run_with_injection(
    args: argparse.Namespace,
    sender: socket.socket,
    qml_mapper: QmlCanMapper | None = None,
) -> int:
    rates = {"imu": 200.0, "slew": 200.0, "rtk": 100.0, "travel": 100.0}
    scheduler = FrameScheduler(rates)
    out_path = Path(args.out)
    out_path.mkdir(parents=True, exist_ok=True)

    ict_sink: FrameSink | None = None
    if args.sink == "socketcan":
        ict_sink, result_code, detail = _open_can0(args.interface)
        if ict_sink is None:
            print(f"SocketCAN smoke unavailable ({result_code}): {detail}", file=sys.stderr)
            return 1
    elif args.sink == "vcan":
        ict_sink = _open_vcan(args.interface)
        if ict_sink is None:
            return 1
    elif args.sink == "tcp":
        try:
            ict_sink = TcpPc001Sink(args.tcp_host, args.tcp_port)
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1

    csv_path = out_path / "can_telemetry_smoke.csv"
    writer = CanapeCsvWriter(csv_path)
    sinks: list[FrameSink] = [CsvFrameSink(writer)]
    if ict_sink is not None:
        sinks.append(ict_sink)
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.host, args.port))
    sock.settimeout(0.5)

    start_ms = time.time() * 1000.0
    try:
        while writer.row_count < args.max_rows:
            tick_ms = int(time.time() * 1000.0 - start_ms) + 1000
            sender.sendto(
                make_synthetic_packet(tick_ms, qml_compatible=qml_mapper is not None),
                (args.host, args.port),
            )
            try:
                data, _ = sock.recvfrom(4096)
            except TimeoutError:
                continue
            sample = parse_packet(data)
            if sample is None:
                continue
            try:
                emit_frames(
                    sinks,
                    scheduler,
                    sample,
                    args.rtk_byteorder,
                    args.model,
                    qml_mapper,
                )
                if isinstance(ict_sink, SocketCanSink):
                    ict_sink.service()
            except QmlMappingError as exc:
                print(f"QML mapping rejected smoke sample: {exc}", file=sys.stderr)
                continue
            time.sleep(0.006)
    finally:
        writer.close()
        if ict_sink is not None:
            if isinstance(ict_sink, SocketCanSink):
                ict_sink.purge(reason="shutdown")
            ict_sink.close()
        sock.close()
        print(f"smoke wrote {writer.row_count} frames -> {csv_path}")
    return 0 if writer.row_count >= args.max_rows else 1


def make_synthetic_packet(tick_ms: int, qml_compatible: bool = False) -> bytes:
    quat_identity = (0.0, 0.0, 0.0, 1.0)
    parts = [struct.pack("<IBBHQ", PACKET_MAGIC, 1, 0, 0, tick_ms)]
    neutral_x_deg = (0.0, 0.0, 35.0, -55.0, -105.0)
    for index in range(5):
        origin = (float(index), 0.0, 0.0)
        quaternion = quat_identity
        if qml_compatible:
            half_angle = math.radians(neutral_x_deg[index]) * 0.5
            quaternion = (math.sin(half_angle), 0.0, 0.0, math.cos(half_angle))
        parts.append(struct.pack("<4f3f", *quaternion, *origin))
    swing = 0.35
    parts.append(struct.pack("<5f", swing, 0.6, 0.4, 0.0, 0.0))
    return b"".join(parts)


if __name__ == "__main__":
    raise SystemExit(main())
