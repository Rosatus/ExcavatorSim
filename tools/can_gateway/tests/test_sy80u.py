"""Model switching and independent GuideSystem decode/render parity."""

from __future__ import annotations

import itertools
import json
import math
import os
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conventions import BODY_ORDER, PACKET_STRUCT, BodyPose, TelemetrySample, parse_packet
from gateway import FrameScheduler, emit_frames, model_console, protocol_codec
from qml_compat import QmlCanMapper, quat_inverse, quat_multiply
from qml_profile import load_qml_profile
from test_gateway_process import free_port, recv_exact, request_json
from test_qml_compat import qx, qy


def sample(model="sy80u", tick=1000, joints=(35.0, -90.0, -50.0), side=0.0, body=(0.0, 0.0, 0.0)):
    pitch, roll, yaw = body
    half = math.radians(roll) / 2
    upper = quat_multiply(qy(yaw), quat_multiply(qx(pitch), (0, 0, math.sin(half), math.cos(half))))
    boom = quat_multiply(upper, quat_multiply(qy(side), qx(joints[0])))
    arm = quat_multiply(boom, qx(joints[1]))
    bucket = quat_multiply(arm, qx(joints[2]))
    bodies = {
        name: BodyPose(q, (1, 2, 3))
        for name, q in zip(BODY_ORDER, (upper, upper, boom, arm, bucket), strict=True)
    }
    return TelemetrySample(tick, bodies, math.radians(28), 0.5, -0.2, model)


def packet(s):
    data = [0x314E5443, 2, 0, 1 if s.model_id == "sy135" else 2, s.tick_ms]
    for name in BODY_ORDER:
        data.extend((*s.bodies[name].quat_xyzw, *s.bodies[name].origin_m))
    return PACKET_STRUCT.pack(*data, s.swing_rad, s.track_left_mps, s.track_right_mps, 0, 0)


class Capture:
    def __init__(self):
        self.frames = {}

    def append(self, can_id, payload, channel):
        self.frames[can_id] = (payload, channel)


class Sy80PoseTest(unittest.TestCase):
    def test_model_catalogs_keep_operator_storage_separate(self):
        args = SimpleNamespace(
            imu_hz=50, rtk_hz=10, slew_hz=50, travel_hz=10, mode="godot-managed", dbc_dir=[]
        )
        operator135, console135 = model_console(args, "sy135")
        operator80, console80 = model_console(args, "sy80u")
        self.assertNotEqual(operator135.store.path, operator80.store.path)
        self.assertNotEqual(console135.store.path, console80.store.path)
        # SY80's CANopen selector has only branch4112; all generated defaults
        # must be encodable even when the selector's numerical minimum is0.
        for key in operator80.codec.messages:
            values = operator80.codec.generated_defaults(key)
            payload = operator80.codec.encode(key, values)
            operator80.codec.decode(key, payload)

    @unittest.skipUnless(os.environ.get("CAN_POSE_CAPTURE"), "requires actual Godot pose capture")
    def test_actual_godot_packets_render_same_local_joint_rotations(self):
        from calibration import sensor2ang_from_reported
        from test_qml_compat import _qml_render_local_joints

        captures = json.loads(Path(os.environ["CAN_POSE_CAPTURE"]).read_text())
        self.assertEqual(len(captures), 7)
        for entry in captures:
            s = parse_packet(bytes.fromhex(entry["packet_hex"]))
            self.assertEqual(s.model_id, "sy80u")
            profile = load_qml_profile("builtin:qml-sy80u-ground-truth")
            capture = Capture()
            emit_frames(
                [capture],
                FrameScheduler(dict.fromkeys(("imu", "slew", "travel", "rtk"), 50)),
                s,
                model="sy80u",
                qml_mapper=QmlCanMapper(profile),
            )
            decoded = [
                tuple(v * 0.01 for v in struct.unpack("<hhh", capture.frames[i][0][:6]))
                for i in (0x18FF3A00, 0x18FF3B00, 0x18FF3C00, 0x18FF3D00)
            ]
            joints = _qml_render_local_joints(
                sensor2ang_from_reported(
                    decoded[0][1] + profile.calibration.roll_error_IMU_Car,
                    *(-row[0] for row in decoded[1:]),
                    profile.calibration,
                )
            )
            side = struct.unpack("<h", capture.frames[0x18FF3E00][0][:2])[0] * 0.01 - 180
            self.assertAlmostEqual(side, entry["side_deg"], delta=0.01)
            for index, (parent, child) in enumerate(
                (("upper", "boom"), ("boom", "arm"), ("arm", "bucket"))
            ):
                actual = quat_multiply(
                    quat_inverse(s.bodies[parent].quat_xyzw), s.bodies[child].quat_xyzw
                )
                expected = qx(joints[index])
                if index == 0:
                    expected = quat_multiply(qy(side), expected)
                dot = abs(sum(a * b for a, b in zip(actual, expected, strict=True)))
                angle_error = math.degrees(2 * math.acos(min(1, dot)))
                self.assertLess(angle_error, 0.04, (entry["label"], child, angle_error))

    def test_packet_identity_and_legacy(self):
        for model in ("sy135", "sy80u"):
            self.assertEqual(parse_packet(packet(sample(model))).model_id, model)
        raw = bytearray(packet(sample()))
        raw[6:8] = b"\xff\xff"
        self.assertIsNone(parse_packet(raw))
        raw[4] = 1
        self.assertIsNone(parse_packet(raw).model_id)

    def test_signed_wire_neutral_joint_extremes_and_swing_under_body_tilt(self):
        profile = load_qml_profile("builtin:qml-sy80u-ground-truth")
        mapper = QmlCanMapper(profile)
        c = profile.calibration
        # Decode raw bytes independently, then reproduce the C++ parser/VAL,
        # Sensor2Ang and QML local rotations. Cover isolated +/- motion and
        # simultaneous side swing, heading, pitch and roll.
        poses = [(35.0, -90.0, -50.0)]
        for joint, values in enumerate(((-20, 80), (-150, -45), (-140, -5))):
            for value in values:
                pose = list(poses[0])
                pose[joint] = value
                poses.append(tuple(pose))
        poses.extend(itertools.product((-20, 80), (-150, -45), (-140, -5)))
        tick = 1000
        for side in (-51, 0, 65):
            for joints in poses:
                for attitude in ((0, 0, 0), (12, -8, 170), (-9, 7, -160)):
                    s = sample(tick=tick, joints=joints, side=side, body=attitude)
                    tick += 20
                    capture = Capture()
                    emit_frames(
                        [capture],
                        FrameScheduler(dict.fromkeys(("imu", "slew", "travel", "rtk"), 50)),
                        s,
                        model="sy80u",
                        qml_mapper=mapper,
                    )
                    frames = capture.frames
                    decoded = [
                        tuple(v * 0.01 for v in struct.unpack("<hhh", frames[i][0][:6]))
                        for i in (0x18FF3A00, 0x18FF3B00, 0x18FF3C00, 0x18FF3D00)
                    ]
                    p0, r0, _ = decoded[0]
                    body_pitch = r0 + c.roll_error_IMU_Car
                    body_roll = p0 - c.pitch_error_IMU_Car
                    pb, pa, pk = (row[0] for row in decoded[1:])
                    boom = pb + c.pitch_error_IMU_Boom - body_pitch
                    arm = 180 - pb - c.pitch_error_IMU_Boom + pa + c.pitch_error_IMU_Arm
                    alpha = math.radians(pk + c.pitch_error_IMU_Bkt - pa - c.pitch_error_IMU_Arm)
                    mn, nq, qk, mk = c.m_lMN, c.m_lNQ, c.m_lQK, c.m_lMK
                    mq = math.sqrt(mn * mn + nq * nq - 2 * mn * nq * math.cos(alpha))

                    def acos(x):
                        return math.acos(max(-1, min(1, x)))

                    bucket = (
                        360
                        - c.m_angNQF
                        - c.m_angKQV
                        - math.degrees(
                            acos((mq * mq + nq * nq - mn * mn) / (2 * mq * nq))
                            + acos((qk * qk + mq * mq - mk * mk) / (2 * qk * mq))
                        )
                    )
                    actual = (boom, arm - 180, bucket - 180)
                    for a, b in zip(actual, joints, strict=True):
                        self.assertAlmostEqual(a, b, delta=0.035)
                    # QML body matrix is Ry(roll) Rx(pitch) in canonical Z-up;
                    # compare to its extraction rather than assuming Euler order.
                    from qml_compat import extract_qml_body_angles, qml_exca_from_godot_quaternion

                    target = extract_qml_body_angles(
                        qml_exca_from_godot_quaternion(s.bodies["upper"].quat_xyzw), 1e-6
                    )
                    self.assertAlmostEqual(body_pitch, target[0], delta=0.011)
                    self.assertAlmostEqual(body_roll, target[1], delta=0.011)
                    decoded_side = struct.unpack("<h", frames[0x18FF3E00][0][:2])[0] * 0.01 - 180
                    self.assertAlmostEqual(decoded_side, side, delta=0.01)
                    self.assertEqual(len(frames[0x18FFF000][0]), 2)
                    self.assertEqual(frames[0x18FF3E00][1], "ch3")
                    self.assertEqual(frames[0x0CFDA000][1], "ch2")
                    self.assertEqual(frames[0x256][1], "ch0")

    def test_zero_sentinel_and_wrong_model_fail_closed(self):
        from dbc_engine import encode_sy80u_imu

        codec = protocol_codec("sy80u")
        self.assertEqual(encode_sy80u_imu(codec, 0x18FF3A00, (0, 0, 0))[:6], b"\0\0\0\0\1\0")
        capture = Capture()
        with self.assertRaises(ValueError):
            emit_frames(
                [capture],
                FrameScheduler(dict.fromkeys(("imu", "slew", "travel", "rtk"), 50)),
                sample(),
                model="sy135",
            )
        self.assertFalse(capture.frames)


class ModelSwitchProcessTest(unittest.TestCase):
    def test_managed_135_80_135_reconnects_and_changes_wire_and_console(self):
        self._check_switch(True)

    def test_switch_back_restores_legacy_135_mapping(self):
        self._check_switch(False)

    def _check_switch(self, compatibility):
        ports = [free_port(udp=True), free_port(udp=True), free_port(), free_port()]
        udp_port, ack_port, tcp_port, web_port = ports
        with tempfile.TemporaryDirectory() as directory:
            env = dict(
                os.environ,
                LOCALAPPDATA=directory,
                XDG_CONFIG_HOME=directory,
                XDG_STATE_HOME=directory,
            )
            command = [os.environ.get("CAN_GATEWAY_TEST_EXE", sys.executable)]
            if "CAN_GATEWAY_TEST_EXE" not in os.environ:
                command.append(str(Path(__file__).resolve().parents[1] / "gateway.py"))
            command += [
                "--mode",
                "godot-managed",
                "--sink",
                "tcp",
                "--host",
                "127.0.0.1",
                "--port",
                str(udp_port),
                "--ack-port",
                str(ack_port),
                "--tcp-host",
                "127.0.0.1",
                "--tcp-port",
                str(tcp_port),
                "--web-port",
                str(web_port),
                "--out",
                directory,
                "--compat-profile",
                "builtin:qml-sy135-ground-truth",
            ]
            if not compatibility:
                command = command[:-2]
            with open(Path(directory) / "gateway.log", "w+") as log:
                process = subprocess.Popen(command, env=env, stdout=log, stderr=log)
                try:
                    base = f"http://127.0.0.1:{web_port}"
                    deadline = time.monotonic() + 25
                    while True:
                        try:
                            request_json(base + "/api/v1/status")["status"]
                            break
                        except OSError:
                            if process.poll() is not None or time.monotonic() > deadline:
                                log.seek(0)
                                self.fail(log.read())
                            time.sleep(0.05)
                    with (
                        socket.create_connection(("127.0.0.1", tcp_port), timeout=3) as peer,
                        socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp,
                    ):
                        self.assertEqual(recv_exact(peer, 3), b"who")
                        peer.sendall(b"PC001")
                        deadline = time.monotonic() + 3
                        while not request_json(base + "/api/v1/status")["status"][
                            "pc001_handshake"
                        ]:
                            self.assertLess(time.monotonic(), deadline)
                            time.sleep(0.02)
                        initial_135_imu = None
                        for index, model in enumerate(("sy135", "sy80u", "sy135")):
                            udp.sendto(
                                packet(sample(model, 1000 + index * 1000)), ("127.0.0.1", udp_port)
                            )
                            if index > 0:
                                # Switching retires the old socket before any
                                # new-model frame can be sent on it.
                                self.assertEqual(peer.recv(1), b"")
                                peer.close()
                                deadline = time.monotonic() + 5
                                while True:
                                    try:
                                        peer = socket.create_connection(
                                            ("127.0.0.1", tcp_port), timeout=3
                                        )
                                        break
                                    except OSError:
                                        self.assertLess(time.monotonic(), deadline)
                                        time.sleep(0.02)
                                self.assertEqual(recv_exact(peer, 3), b"who")
                                peer.sendall(b"PC001")
                                deadline = time.monotonic() + 3
                                while not request_json(base + "/api/v1/status")["status"][
                                    "pc001_handshake"
                                ]:
                                    self.assertLess(time.monotonic(), deadline)
                                    time.sleep(0.02)
                                udp.sendto(
                                    packet(sample(model, 1100 + index * 1000)),
                                    ("127.0.0.1", udp_port),
                                )
                            frames = {}
                            while len(frames) < (17 if model == "sy80u" else 16):
                                count = struct.unpack("<H", recv_exact(peer, 2))[0]
                                raw = recv_exact(peer, count * 20)
                                for offset in range(0, len(raw), 20):
                                    can_id, length = struct.unpack_from("<IB", raw, offset)
                                    self.assertEqual(
                                        bool(can_id & 0x80000000), (can_id & 0x1FFFFFFF) != 0x256
                                    )
                                    frames[can_id & 0x1FFFFFFF] = raw[
                                        offset + 8 : offset + 8 + length
                                    ]
                            self.assertEqual(len(frames[0x18FFF000]), 2 if model == "sy80u" else 8)
                            self.assertEqual(0x18FF3E00 in frames, model == "sy80u")
                            if index == 0:
                                initial_135_imu = frames[0x18FF3B00]
                            elif index == 2:
                                self.assertEqual(frames[0x18FF3B00], initial_135_imu)
                            snapshot = request_json(base + "/api/v1/can-console")["console"]
                            row = next(
                                row
                                for row in snapshot["messages"]
                                if row["message"]["frame_id"] == 0x18FF3A00
                            )
                            pitch = next(
                                signal
                                for signal in row["message"]["signals"]
                                if signal["name"] == "Pitch_Angle"
                            )
                            self.assertEqual(pitch["offset"], 0 if model == "sy80u" else -180)
                            self.assertTrue(
                                request_json(base + "/api/v1/status")["status"]["pc001_handshake"]
                            )
                except Exception:
                    log.flush()
                    log.seek(0)
                    print(log.read())
                    raise
                finally:
                    if "peer" in locals():
                        peer.close()
                    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as udp:
                        udp.sendto(
                            struct.pack("<IBBHI", 0x43544E43, 1, 3, 0, 1), ("127.0.0.1", udp_port)
                        )
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait()


if __name__ == "__main__":
    unittest.main()
