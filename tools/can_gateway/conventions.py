"""Packet parsing and attitude conventions.

Godot sends a fixed-layout little-endian packet; see can_telemetry_bridge.gd.
All angle semantics converge here so mounting/calibration changes stay local.

Reference decode formulas mirror GuideSystem/services/can/protocolparser.cpp:
- Ruifen IMU extended frames report roll=s1, pitch=-s0, yaw=s2 where each slot
  s = count*0.01 - 180 deg. Encoding therefore inverts that mapping.
"""

from __future__ import annotations

import math
import struct
from dataclasses import dataclass, field

PACKET_MAGIC = 0x314E5443  # "CTN1"
PACKET_VERSION = 1
BODY_COUNT = 5
BODY_ORDER = ("chassis", "upper", "boom", "arm", "bucket")
LINK_BY_BODY = {"chassis": "body", "upper": "body", "boom": "boom", "arm": "arm", "bucket": "bucket"}
PACKET_STRUCT = struct.Struct("<IBBHQ" + "4f3f" * BODY_COUNT + "5f")
TRAVEL_PRESSURE_MOVING = 9
SPEED_EPSILON_MPS = 0.05

# IMU zero-mount compensation per model (degrees, added to the link-frame
# pitch before slot encoding). Contract: the parser-reported pitch must equal
# -(absolute SEGMENT elevation in world), i.e. a steel-mounted real-machine
# IMU whose "raised" reads negative. Since sensor_slots() passes the caller's
# pitch through verbatim,
#
#   pitch_arg = -(frame_world_elevation) + comp
#
# comp MUST be derived from WORLD-accumulated rest elevations (parent chain
# cascades!), not per-link local differences:
#
#   comp[link] = frame_world_rest_elevation - segment_world_rest_elevation
#
# sy205: rest_transforms are identity (frame world rest elevation 0);
#   segment geometry baked into meshes. Values use the downstream polar-angle
#   convention verified against Sensor2Ang + calibration.toml: boom -47.65
#   (segment +47.65 up), arm +101.79 (elbow 30.58 off straight; locks
#   armPhi~30.6). Hinges C=(-0.119,1.623,-0.075) F=(-0.053,5.918,3.840)
#   Q=(-0.061,2.892,3.210).
# sy135: segments horizontal at rest (world seg elevation 0); frame world
#   rest elevations accumulate down the chain (+35-55-75):
#   boom +35 / arm -20 / bucket -95.
IMU_MOUNT_COMPENSATION_DEG: dict[str, dict[str, float]] = {
    "sy205": {"boom": -47.65, "arm": 101.79, "bucket": 0.0},
    "sy135": {"boom": 35.00, "arm": -20.00, "bucket": -95.00},
}
DEFAULT_MODEL = "sy135"

# Synthetic geodetic origin (equirectangular ENU approximation).
ORIGIN_LAT_DEG = 30.8675
ORIGIN_LON_DEG = 120.0933
ORIGIN_ALT_M = 3.0
METERS_PER_DEG_LAT = 111320.0


@dataclass(frozen=True)
class BodyPose:
    quat_xyzw: tuple[float, float, float, float]
    origin_m: tuple[float, float, float]


@dataclass(frozen=True)
class TelemetrySample:
    tick_ms: int
    bodies: dict[str, BodyPose]
    swing_rad: float
    track_left_mps: float
    track_right_mps: float


def parse_packet(data: bytes) -> TelemetrySample | None:
    if len(data) != PACKET_STRUCT.size:
        return None
    values = PACKET_STRUCT.unpack(data)
    magic, version, _flags = values[0], values[1], values[2]
    if magic != PACKET_MAGIC or version != PACKET_VERSION:
        return None
    tick_ms = values[4]
    bodies: dict[str, BodyPose] = {}
    offset = 5
    for name in BODY_ORDER:
        quat = values[offset:offset + 4]
        origin = values[offset + 4:offset + 7]
        bodies[name] = BodyPose(quat_xyzw=quat, origin_m=origin)
        offset += 7
    tail = values[offset:offset + 5]
    return TelemetrySample(
        tick_ms=tick_ms,
        bodies=bodies,
        swing_rad=tail[0],
        track_left_mps=tail[1],
        track_right_mps=tail[2],
    )


@dataclass
class MachineState:
    sample: TelemetrySample
    heading_baseline_deg: float = field(default=0.0)
    model: str = DEFAULT_MODEL

    def link_rpy(self, link: str) -> tuple[float, float, float]:
        """Y-up attitude (deg) for a logical sensor link, with IMU zero-mount
        compensation so the parser-reported pitch equals -(absolute segment
        elevation): raised reads negative, matching real-machine goldens."""
        body = self._body_for_link(link)
        roll, pitch, yaw = quat_to_yup_euler_deg(body.quat_xyzw)
        comp = IMU_MOUNT_COMPENSATION_DEG.get(self.model, {}).get(link, 0.0)
        return roll, -pitch + comp, yaw

    def _body_for_link(self, link: str):
        if link == "body":
            return self.sample.bodies["chassis"]
        return self.sample.bodies[link]

    @staticmethod
    def sensor_slots(roll_deg: float, pitch_deg: float, yaw_deg: float) -> tuple[int, int, int]:
        """Inverse of parser remap: reported=(s1,-s0,s2) -> slots=(-p,r,y)."""
        slots = (-pitch_deg, roll_deg, yaw_deg)
        encoded = []
        for slot in slots:
            count = int(round((slot + 180.0) / 0.01))
            count = max(1, min(count, 65535))  # never zero: zero triple == invalid marker
            encoded.append(count)
        return encoded[0], encoded[1], encoded[2]

    def slew_degrees(self) -> float:
        deg = math.degrees(self.sample.swing_rad) % 360.0
        return deg

    def travel_pressures(self) -> tuple[int, int]:
        # Pilot pressure frame (0x256) carries magnitude only: unsigned kg,
        # valid domain 0..50. Direction is not representable on this protocol,
        # so any track speed above epsilon emits +TRAVEL_PRESSURE_MOVING.
        def pressure(speed: float) -> int:
            if abs(speed) < SPEED_EPSILON_MPS:
                return 0
            return TRAVEL_PRESSURE_MOVING
        return pressure(self.sample.track_left_mps), pressure(self.sample.track_right_mps)

    def geodetic(self) -> tuple[float, float, float]:
        east, north = self.sample.bodies["chassis"].origin_m[0], -self.sample.bodies["chassis"].origin_m[2]
        up = self.sample.bodies["chassis"].origin_m[1]
        lat = ORIGIN_LAT_DEG + north / METERS_PER_DEG_LAT
        lon = ORIGIN_LON_DEG + east / (METERS_PER_DEG_LAT * math.cos(math.radians(ORIGIN_LAT_DEG)))
        return lat, lon, ORIGIN_ALT_M + up

    def heading_degrees(self) -> float:
        fwd = basis_forward_from_quat(self.sample.bodies["chassis"].quat_xyzw)
        # Sim convention: north = -Z, east = +X.
        east, north = fwd[0], -fwd[2]
        return (math.degrees(math.atan2(east, north)) + 360.0) % 360.0

    def velocity_enu(self) -> tuple[float, float, float, float]:
        """ve, vn, vu, ground speed from chassis forward direction."""
        fwd = basis_forward_from_quat(self.sample.bodies["chassis"].quat_xyzw)
        speed = (self.sample.track_left_mps + self.sample.track_right_mps) * 0.5
        ve = speed * fwd[0]
        vn = speed * -fwd[2]
        return ve, vn, 0.0, math.hypot(ve, vn)

    def vice_antenna_geodetic(self, baseline_m: float = 1.0) -> tuple[float, float, float]:
        """Secondary antenna placed opposite the heading from the primary."""
        fwd = basis_forward_from_quat(self.sample.bodies["chassis"].quat_xyzw)
        lat, lon, alt = self.geodetic()
        d_north = -fwd[2] * baseline_m
        d_east = fwd[0] * baseline_m
        lat2 = lat - d_north / METERS_PER_DEG_LAT
        lon2 = lon - d_east / (METERS_PER_DEG_LAT * math.cos(math.radians(ORIGIN_LAT_DEG)))
        return lat2, lon2, alt


def quat_to_zyx_euler_deg(q: tuple[float, float, float, float]) -> tuple[float, float, float]:
    """Deprecated Z-up aerospace ZYX decomposition. Kept only for reference;
    CAN encoding must use quat_to_yup_euler_deg (Godot world is Y-up)."""
    x, y, z, w = q
    sinr_cosp = 2.0 * (w * x + y * z)
    cosr_cosp = 1.0 - 2.0 * (x * x + y * y)
    roll = math.atan2(sinr_cosp, cosr_cosp)

    sinp = 2.0 * (w * y - z * x)
    pitch = math.copysign(math.pi / 2.0, sinp) if abs(sinp) >= 1.0 else math.asin(sinp)

    siny_cosp = 2.0 * (w * z + x * y)
    cosy_cosp = 1.0 - 2.0 * (y * y + z * z)
    yaw = math.atan2(siny_cosp, cosy_cosp)
    return math.degrees(roll), math.degrees(pitch), math.degrees(yaw)


def _quat_to_matrix_rows(q: tuple[float, float, float, float]) -> list[list[float]]:
    """Rotation matrix (row-major) for a Godot quaternion (x,y,z,w)."""
    x, y, z, w = q
    return [
        [1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y)],
        [2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x)],
        [2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y)],
    ]


def quat_to_yup_euler_deg(q: tuple[float, float, float, float]) -> tuple[float, float, float]:
    """Y-up (Godot) attitude decomposition: R = Ry(yaw) * Rx(pitch) * Rz(roll).

    Extracts in order: heading about the vertical Y axis, then elevation of the
    link forward axis (-Z) above the horizontal plane, then roll about the
    forward longitudinal axis. Sign contract with the downstream parser:
    lifting a link raises its forward-axis elevation, and the parser reports
    pitch = -(elevation) so that "raised" reads as negative pitch.
    """
    m = _quat_to_matrix_rows(q)
    # Godot forward is the third column negated.
    fwd_x, fwd_y, fwd_z = -m[0][2], -m[1][2], -m[2][2]
    # azimuth measured from the -Z reference axis; Godot Y-rotation is
    # clockwise viewed from +Y, so heading = -atan2(fwd_x, -fwd_z)
    yaw = math.degrees(math.atan2(-fwd_x, -fwd_z))
    horiz = math.hypot(fwd_x, fwd_z)
    pitch = math.degrees(math.atan2(fwd_y, horiz))
    # roll tilts the up axis within the plane containing forward and up:
    # project up onto the vertical plane spanned by forward-horizontal and Y
    up_x, up_y, up_z = m[0][1], m[1][1], m[2][1]
    fwd_horiz_x, fwd_horiz_z = (fwd_x / horiz, fwd_z / horiz) if horiz > 1e-9 else (0.0, -1.0)
    lateral = up_x * (-fwd_horiz_z) + up_z * fwd_horiz_x
    roll = math.degrees(math.atan2(lateral, max(up_y, 1e-12)) if abs(up_y) > 1e-12 else math.copysign(90.0, lateral))
    # Continuous-pitch unwrap: a real IMU reports pitch through +/-90 without
    # flipping yaw (e.g. an arm curling past vertical keeps pitch growing to
    # +/-180). The elevation-only decomposition instead folds at +/-90 with a
    # 180 deg yaw jump; undo that fold so joint-angle reconstruction
    # (downstream uses bkt-arm differences) stays monotonic across travel.
    # Fold signature: the link up axis points downward (up_y < 0) - true
    # attitude has |pitch| > 90. Genuine heading rotations keep up_y >= 0.
    if up_y < 0.0:
        sign = 1.0 if pitch >= 0.0 else -1.0
        pitch = sign * (180.0 - abs(pitch))
        yaw -= math.copysign(180.0, yaw)
        roll = -roll
    return roll, pitch, yaw


def basis_forward_from_quat(q: tuple[float, float, float, float]) -> tuple[float, float, float]:
    """Godot local -Z axis expressed in world coordinates."""
    matrix = _quat_to_matrix_rows(q)
    return -matrix[0][2], -matrix[1][2], -matrix[2][2]
