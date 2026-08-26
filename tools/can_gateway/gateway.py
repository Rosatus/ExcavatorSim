"""CAN telemetry gateway: sim UDP packets -> SY135C CAN frames -> CSV / SocketCAN.

Reverse of GuideSystem/services/can ProtocolParser decode logic.
See .trellis/tasks/08-25-can-telemetry-gateway/design.md for the byte layouts.
"""

from __future__ import annotations

import argparse
import socket
import struct
import sys
import time
from pathlib import Path

from conventions import MachineState, TelemetrySample, parse_packet
from control_protocol import (
    CMD_ICT_START,
    CMD_ICT_STOP,
    CMD_RECORD_START,
    CMD_RECORD_STOP,
    CMD_SHUTDOWN,
    HEARTBEAT_FLAG_PLATFORM_LINUX,
    HEARTBEAT_FLAG_RECORDING,
    build_heartbeat,
    build_session_done,
    parse_control,
)
from csv_writer import CanapeCsvWriter
from encoders.dxg_slew import encode_slew_frame
from encoders.ruifen_imu import RUFINEN_IDS, encode_ruifen_frame
from encoders.sinan_rtk import (
    RTK_IDS_ORDERED,
    build_rtk_frames,
)
from encoders.travel_pilot import encode_travel_frame
from pc001_sink import TcpPc001Sink
from sinks import CsvFrameSink, FrameSink, SocketCanSink
from vcan_setup import VcanSetupError, ensure_vcan_interface

PACKET_MAGIC = 0x314E5443
HEARTBEAT_INTERVAL_S = 0.5


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


def run(args: argparse.Namespace) -> int:
    rates = {
        "imu": args.imu_hz,
        "slew": args.slew_hz,
        "rtk": args.rtk_hz,
        "travel": args.travel_hz,
    }
    scheduler = FrameScheduler(rates)
    out_path = Path(args.out)
    out_path.mkdir(parents=True, exist_ok=True)

    ict_sink: FrameSink | None = None
    if args.sink == "vcan":
        ict_sink = _open_vcan(args.interface)
        if ict_sink is None:
            return 1
    elif args.sink == "tcp":
        try:
            ict_sink = TcpPc001Sink(args.tcp_host, args.tcp_port)
        except RuntimeError as exc:
            print(str(exc), file=sys.stderr)
            return 1

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.host, args.port))
    sock.settimeout(0.05)
    # Windows: ICMP port-unreachable (e.g. heartbeat before Godot binds the
    # ack port) surfaces as ConnectionResetError on the next recvfrom.
    try:
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)
    except (AttributeError, OSError):
        pass
    ack_addr = (args.host if args.host != "0.0.0.0" else "127.0.0.1", args.ack_port)

    writer: CanapeCsvWriter | None = None
    recording = False
    last_heartbeat_s = 0.0
    ctrl_seq = 0
    platform_linux = hasattr(socket, "AF_CAN")
    print(f"gateway listening on {args.host}:{args.port} (out={out_path}, sink={args.sink})")

    def active_sinks() -> list[FrameSink]:
        sinks: list[FrameSink] = []
        if recording and writer is not None:
            sinks.append(CsvFrameSink(writer))
        if ict_sink is not None:
            sinks.append(ict_sink)
        return sinks

    try:
        while True:
            now_s = time.time()
            if now_s - last_heartbeat_s >= HEARTBEAT_INTERVAL_S:
                sock.sendto(
                    build_heartbeat(
                        int(now_s * 1000) & 0xFFFFFFFFFFFFFFFF,
                        recording,
                        platform_linux,
                    ),
                    ack_addr,
                )
                last_heartbeat_s = now_s
            try:
                data, _addr = sock.recvfrom(4096)
            except (socket.timeout, ConnectionResetError):
                continue

            cmd = parse_control(data)
            if cmd is not None:
                ctrl_seq += 1
                if cmd == CMD_RECORD_START:
                    if writer is None:
                        stamp = time.strftime("%Y%m%d_%H%M%S")
                        csv_path = out_path / f"can_telemetry_{stamp}.csv"
                        writer = CanapeCsvWriter(csv_path)
                        print(f"recording -> {csv_path}")
                    recording = True
                elif cmd == CMD_RECORD_STOP:
                    recording = False
                    if writer is not None:
                        writer.close()
                        sock.sendto(build_session_done(str(writer.path)), ack_addr)
                        print(f"segment saved: {writer.path}")
                        writer = None
                    print("recording stopped")
                elif cmd == CMD_ICT_START:
                    if ict_sink is None:
                        if args.sink == "vcan":
                            ict_sink = _open_vcan(args.interface)
                        elif args.sink == "csv":
                            # csv-only mode: ICT was never configured
                            print("ICT unavailable: gateway started without --sink tcp/vcan", file=sys.stderr)
                    if ict_sink is not None:
                        print(f"ICT connected: {ict_sink.peer_name()}")
                elif cmd == CMD_ICT_STOP:
                    if ict_sink is not None and args.sink == "vcan":
                        # tcp sink stays listening across ICT stop; only vcan closes
                        ict_sink.close()
                        ict_sink = None
                    print("ICT disconnected")
                elif cmd == CMD_SHUTDOWN:
                    print("shutdown requested")
                    break
                continue

            sample = parse_packet(data)
            if sample is None:
                print("bad packet (magic/version/size), dropped", file=sys.stderr)
                continue
            sinks = active_sinks()
            if sinks:
                emit_frames(sinks, scheduler, sample, args.rtk_byteorder)
                csv_rows = writer.row_count if writer is not None else 0
                if args.max_rows and csv_rows >= args.max_rows:
                    break
    except KeyboardInterrupt:
        pass
    finally:
        rows = writer.row_count if writer is not None else 0
        path = writer._path if writer is not None else "(no session)"
        if writer is not None:
            writer.close()
        if ict_sink is not None:
            ict_sink.close()
        print(f"closed {path} ({rows} frames)")
        sock.close()
    return 0


def _open_vcan(interface: str) -> SocketCanSink | None:
    try:
        sink = SocketCanSink(interface, setup_check=False)
        ensure_vcan_interface(interface)
        return sink
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


def emit_frames(
    sinks: list[FrameSink],
    scheduler: FrameScheduler,
    sample: TelemetrySample,
    rtk_byteorder: str = "little",
) -> None:
    state = MachineState(sample)
    tick = float(sample.tick_ms)

    if scheduler.due("imu", tick):
        for link in ("body", "boom", "arm", "bucket"):
            roll, pitch, yaw = state.link_rpy(link)
            slots = state.sensor_slots(roll, pitch, yaw)
            frame = encode_ruifen_frame(slots)
            for sink in sinks:
                sink.append(RUFINEN_IDS[link], frame)
        scheduler.advance("imu", tick)

    if scheduler.due("slew", tick):
        frame = encode_slew_frame(state.slew_degrees())
        for sink in sinks:
            sink.append(0x18FFF000, frame)
        scheduler.advance("slew", tick)

    if scheduler.due("travel", tick):
        left, right = state.travel_pressures()
        frame = encode_travel_frame(left, right)
        for sink in sinks:
            sink.append(0x256, frame)
        scheduler.advance("travel", tick)

    if scheduler.due("rtk", tick):
        for can_id, payload in build_rtk_frames(state, rtk_byteorder).items():
            for sink in sinks:
                sink.append(can_id, payload)
        scheduler.advance("rtk", tick)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=29764)
    parser.add_argument("--out", default="output/can_gateway")
    parser.add_argument("--imu-hz", type=float, default=100.0)
    parser.add_argument("--slew-hz", type=float, default=100.0)
    parser.add_argument("--rtk-hz", type=float, default=10.0)
    parser.add_argument("--travel-hz", type=float, default=10.0)
    parser.add_argument("--max-rows", type=int, default=0, help="stop after N rows (smoke)")
    parser.add_argument("--rtk-byteorder", choices=("big", "little"), default="little")
    parser.add_argument("--ack-port", type=int, default=29765, help="heartbeat destination port")
    parser.add_argument(
        "--sink",
        choices=("csv", "vcan", "tcp"),
        default="csv",
        help="frame output: csv segments (default), SocketCAN vcan, or PC001 TCP server",
    )
    parser.add_argument("--interface", default="vcan0", help="SocketCAN interface for --sink vcan / --setup-vcan")
    parser.add_argument("--tcp-host", default="0.0.0.0", help="listen address for --sink tcp (PC001)")
    parser.add_argument("--tcp-port", type=int, default=5678, help="listen port for --sink tcp (PC001)")
    parser.add_argument(
        "--setup-vcan",
        action="store_true",
        help="create/bring up the vcan interface, then exit",
    )
    parser.add_argument("--smoke", action="store_true", help="self-inject synthetic packets")
    args = parser.parse_args(argv)

    if args.setup_vcan:
        try:
            ensure_vcan_interface(args.interface)
        except VcanSetupError as exc:
            print(f"vcan setup failed: {exc}", file=sys.stderr)
            return 1
        print(f"SocketCAN interface ready: {args.interface}")
        return 0

    if args.max_rows:
        # Smoke mode: synthesize packets locally instead of waiting on the game.
        return run_smoke(args)
    return run(args)


def run_smoke(args: argparse.Namespace) -> int:
    sender = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver_run = run_with_injection(args, sender)
    sender.close()
    return receiver_run


def run_with_injection(args: argparse.Namespace, sender: socket.socket) -> int:
    rates = {"imu": 200.0, "slew": 200.0, "rtk": 100.0, "travel": 100.0}
    scheduler = FrameScheduler(rates)
    out_path = Path(args.out)
    out_path.mkdir(parents=True, exist_ok=True)

    ict_sink: FrameSink | None = None
    if args.sink == "vcan":
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
            sender.sendto(make_synthetic_packet(tick_ms), (args.host, args.port))
            try:
                data, _ = sock.recvfrom(4096)
            except socket.timeout:
                continue
            sample = parse_packet(data)
            if sample is None:
                continue
            emit_frames(sinks, scheduler, sample)
            time.sleep(0.006)
    finally:
        writer.close()
        if ict_sink is not None:
            ict_sink.close()
        sock.close()
        print(f"smoke wrote {writer.row_count} frames -> {csv_path}")
    return 0 if writer.row_count >= args.max_rows else 1


def make_synthetic_packet(tick_ms: int) -> bytes:
    quat_identity = (0.0, 0.0, 0.0, 1.0)
    parts = [struct.pack("<IBBHQ", PACKET_MAGIC, 1, 0, 0, tick_ms)]
    for index in range(5):
        origin = (float(index), 0.0, 0.0)
        parts.append(struct.pack("<4f3f", *quat_identity, *origin))
    swing = 0.35
    parts.append(struct.pack("<5f", swing, 0.6, 0.4, 0.0, 0.0))
    return b"".join(parts)


if __name__ == "__main__":
    raise SystemExit(main())
