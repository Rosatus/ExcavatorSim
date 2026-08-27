"""CAN telemetry gateway: sim UDP packets -> SY135C CAN frames -> CSV / SocketCAN.

Reverse of GuideSystem/services/can ProtocolParser decode logic.
See .trellis/tasks/08-25-can-telemetry-gateway/design.md for the byte layouts.
"""

from __future__ import annotations

import argparse
import contextlib
import math
import socket
import struct
import sys
import time
from pathlib import Path

from control_protocol import (
    CMD_ICT_START,
    CMD_ICT_STOP,
    CMD_RECORD_START,
    CMD_RECORD_STOP,
    CMD_SHUTDOWN,
    CMD_TIMED_CAN_START,
    build_heartbeat,
    build_session_done,
    parse_control,
)
from conventions import (
    DEFAULT_MODEL,
    IMU_MOUNT_COMPENSATION_DEG,
    MachineState,
    TelemetrySample,
    parse_packet,
)
from csv_writer import CanapeCsvWriter
from encoders.dxg_slew import encode_slew_frame
from encoders.ruifen_imu import RUFINEN_IDS, encode_ruifen_frame
from encoders.sinan_rtk import build_rtk_frames
from encoders.travel_pilot import encode_travel_frame
from pc001_sink import TcpPc001Sink
from qml_compat import QmlCanMapper, QmlMappingError, QmlRtkState
from qml_profile import QmlProfileError, load_qml_profile
from sinks import CsvFrameSink, FrameSink, SocketCanSink
from vcan_setup import VcanSetupError, ensure_vcan_interface

PACKET_MAGIC = 0x314E5443
HEARTBEAT_INTERVAL_S = 0.5
RECEIVE_POLL_LIMIT_S = 0.05
TIMED_CAN_ID = 0x18FFF100
TIMED_CAN_PAYLOAD = bytes.fromhex("01 00 00 00 00 00 00 00")
TIMED_CAN_PERIOD_S = 1.0 / 50.0
TIMED_CAN_DURATION_S = 10.0
TIMED_CAN_FRAME_COUNT = 500


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

    @property
    def active(self) -> bool:
        return self._next_due_s is not None

    @property
    def emitted_count(self) -> int:
        return self._emitted

    def trigger(self, now_s: float) -> None:
        self._next_due_s = now_s
        self._end_s = now_s + TIMED_CAN_DURATION_S
        self._emitted = 0

    def timeout_s(self, now_s: float, maximum_s: float = RECEIVE_POLL_LIMIT_S) -> float:
        if self._next_due_s is None:
            return maximum_s
        return max(0.0, min(maximum_s, self._next_due_s - now_s))

    def service(self, now_s: float, sinks: list[FrameSink]) -> bool:
        due_s = self._next_due_s
        end_s = self._end_s
        if end_s is not None and now_s >= end_s:
            self._next_due_s = None
            self._end_s = None
            return False
        if due_s is None or now_s + 1e-9 < due_s:
            return False
        for sink in sinks:
            sink.append(TIMED_CAN_ID, TIMED_CAN_PAYLOAD)
        self._emitted += 1
        if self._emitted >= TIMED_CAN_FRAME_COUNT:
            self._next_due_s = None
            self._end_s = None
        else:
            # Do not burst missed wall-time slots. The next real emission stays
            # at 50 Hz from whichever slot the gateway was able to service.
            self._next_due_s = max(due_s + TIMED_CAN_PERIOD_S, now_s + TIMED_CAN_PERIOD_S)
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
    sock.settimeout(RECEIVE_POLL_LIMIT_S)
    # Windows: ICMP port-unreachable (e.g. heartbeat before Godot binds the
    # ack port) surfaces as ConnectionResetError on the next recvfrom.
    with contextlib.suppress(AttributeError, OSError):
        sock.ioctl(socket.SIO_UDP_CONNRESET, False)
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
            monotonic_s = time.monotonic()
            timed_can.service(monotonic_s, active_sinks())
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
            sock.settimeout(timed_can.timeout_s(time.monotonic()))
            try:
                data, _addr = sock.recvfrom(4096)
            except (BlockingIOError, TimeoutError, ConnectionResetError):
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
                            print(
                                "ICT unavailable: gateway started without --sink tcp/vcan",
                                file=sys.stderr,
                            )
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
                elif cmd == CMD_TIMED_CAN_START:
                    timed_can.trigger(time.monotonic())
                    timed_can.service(time.monotonic(), active_sinks())
                    print("timed CAN burst started: 0x18FFF100 at 50 Hz for 10 s")
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
                    )
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
    model: str = DEFAULT_MODEL,
    qml_mapper: QmlCanMapper | None = None,
) -> None:
    state = MachineState(sample, model=model)
    projection = qml_mapper.project(sample) if qml_mapper is not None else None
    tick = float(sample.tick_ms)
    pending: list[tuple[int, bytes]] = []

    if scheduler.due("imu", tick):
        for link in ("body", "boom", "arm", "bucket"):
            if projection is None:
                roll, pitch, yaw = state.link_rpy(link)
            else:
                roll, pitch, yaw = projection.imu_rpy_deg[link]
            slots = state.sensor_slots(roll, pitch, yaw)
            pending.append((RUFINEN_IDS[link], encode_ruifen_frame(slots)))

    if scheduler.due("slew", tick):
        pending.append((0x18FFF000, encode_slew_frame(state.slew_degrees())))

    if scheduler.due("travel", tick):
        left, right = state.travel_pressures()
        pending.append((0x256, encode_travel_frame(left, right)))

    if scheduler.due("rtk", tick):
        rtk_state = state if projection is None else QmlRtkState(projection)
        satellite_status = 0 if projection is None else projection.satellite_status
        for can_id, payload in build_rtk_frames(
            rtk_state,
            rtk_byteorder,
            satellite_status=satellite_status,
            # ProtocolParser::parseCgi610A800 reads each i16 as network order.
            # Keep legacy behavior unchanged; QML profile uses the real parser.
            velocity_byteorder="big" if projection is not None else None,
        ).items():
            pending.append((can_id, payload))

    # Finish all profile math and encoding before exposing any frame. A bad
    # telemetry sample must never produce a partial CAN family.
    for can_id, payload in pending:
        for sink in sinks:
            sink.append(can_id, payload)

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
    parser.add_argument("--out", default="output/can_gateway")
    parser.add_argument("--imu-hz", type=float, default=100.0)
    parser.add_argument("--slew-hz", type=float, default=100.0)
    parser.add_argument("--rtk-hz", type=float, default=10.0)
    parser.add_argument("--travel-hz", type=float, default=10.0)
    parser.add_argument("--max-rows", type=int, default=0, help="stop after N rows (smoke)")
    parser.add_argument("--rtk-byteorder", choices=("big", "little"), default="little")
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
        choices=("csv", "vcan", "tcp"),
        default="csv",
        help="frame output: csv segments (default), SocketCAN vcan, or PC001 TCP server",
    )
    parser.add_argument(
        "--interface", default="vcan0", help="SocketCAN interface for --sink vcan / --setup-vcan"
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
            except QmlMappingError as exc:
                print(f"QML mapping rejected smoke sample: {exc}", file=sys.stderr)
                continue
            time.sleep(0.006)
    finally:
        writer.close()
        if ict_sink is not None:
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
