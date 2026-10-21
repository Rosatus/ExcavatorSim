"""Parse a gateway CSV telemetry dump and reconstruct BOTH sides of the
attitude pipeline:

  Godot intent   - link_rpy(link) values the gateway encoded (encode side).
  QML view       - reported_rpy from the parser remap + downstream Sensor2Ang.

For every ruifen frame we can invert the encode chain exactly:

  slot s0 = -pitch_arg + offset  (sensor_slots maps pitch_arg -> s0 = -pitch_arg)
  reported pitch (parser) = -s0 = pitch_arg
  Godot link_rpy pitch = pitch_arg was  -(elevation) + comp
  => elevation = comp - reported_pitch

So the offline reconstruction needs the model's compensation table.

Run:  python analyze_csv.py <csv> [--model sy135|sy205] [--sample N]
"""

from __future__ import annotations

import argparse
import csv
import math
import sys
from collections import defaultdict
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[4] / "tools" / "can_gateway"
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from conventions import IMU_MOUNT_COMPENSATION_DEG, quat_to_yup_euler_deg  # noqa: E402

LINK_BY_ID = {0x18FF3A00: "body", 0x18FF3B00: "boom", 0x18FF3C00: "arm", 0x18FF3D00: "bucket"}
# body uses chassis IMU: mount comp is zero for body link.
RPY_PREFIX = "x| "

RTK_HEADING_ID = 0x0CFDA900
SLEW_ID = 0x18FFF000
SLEW_COUNTS_PER_REV = 65536

# downstream lib_kin calibration (calibration.toml)
CAL = {
    "boom": 0.4713, "arm": -0.1928, "bkt": 4.9748,
    "car_pitch": -0.55, "car_roll": 1.0475, "car_yaw": -0.2699,
    "lCF": 4.5736, "lFQ": 2.4926, "lMK": 0.422, "lMN": 0.493,
    "lNQ": 0.29, "lQK": 0.375, "lQV": 1.2291,
    "angNQF": 4.882, "angKQV": 108.4, "angDMX": 0.0,
}


def sensor2ang(p_b, p_a, p_k, body_pitch=0.0):
    """Replicate ExcavatorKinematics::Sensor2Ang on parser-reported pitches.
    p_b/p_a/p_k are the parser-reported pitch values (-s0) for boom/arm/bucket;
    body_pitch is the parser-reported body pitch.  GuidancePeriodicService first
    passes ``-body_pitch`` as ``bodyIMUR``, so Sensor2Ang reconstructs
    ``bodyPhiPitch = body_pitch + roll_error_IMU_Car``.
    """
    import math
    boom_ang = -p_b
    arm_ang = -p_a
    bkt_ang = -p_k
    body_phi_pitch = body_pitch + CAL["car_roll"]
    boom_phi = boom_ang + CAL["boom"] - body_phi_pitch
    arm_phi = 180.0 - (boom_ang + CAL["boom"] - arm_ang - CAL["arm"])
    ang_mnq = bkt_ang + CAL["bkt"] - arm_ang - CAL["arm"]
    mq = math.sqrt(CAL["lMN"] ** 2 + CAL["lNQ"] ** 2 - 2 * CAL["lNQ"] * CAL["lMN"] * math.cos(math.radians(ang_mnq)))
    d_mqn = 2 * mq * CAL["lNQ"]
    d_kqm = 2 * CAL["lQK"] * mq
    if d_mqn == 0 or d_kqm == 0:
        bkt_phi = 0.0
    else:
        cos_mqn = (mq * mq + CAL["lNQ"] ** 2 - CAL["lMN"] ** 2) / d_mqn
        cos_kqm = (CAL["lQK"] ** 2 + mq * mq - CAL["lMK"] ** 2) / d_kqm
        ang_mqn = math.acos(max(-1.0, min(1.0, cos_mqn)))
        ang_kqm = math.acos(max(-1.0, min(1.0, cos_kqm)))
        bkt_phi = 360.0 - CAL["angNQF"] - math.degrees(ang_kqm + ang_mqn) - CAL["angKQV"]
    return boom_phi, arm_phi, bkt_phi

# (full lib_kin CAL defined above with four-bar lengths)


def parse_time(s: str) -> float:
    """'08:29:41.149' -> seconds since midnight."""
    try:
        h, m, rest = s.split(":")
        sec, _, milli = rest.partition(".")
        return int(h) * 3600 + int(m) * 60 + int(sec) + int(milli or 0) / 1000.0
    except ValueError:
        return float(s)


def decode_slots(data: str) -> tuple[float, float, float]:
    """Payload string like 'x| 50 46 50 46 50 46 00 00' -> raw slot values (deg)."""
    raw = data[len(RPY_PREFIX):].split()
    vals = [int(b, 16) for b in raw]
    s0 = (vals[0] | (vals[1] << 8)) * 0.01 - 180.0
    s1 = (vals[2] | (vals[3] << 8)) * 0.01 - 180.0
    s2 = (vals[4] | (vals[5] << 8)) * 0.01 - 180.0
    return s0, s1, s2


def parser_reported(payload: str) -> tuple[float, float, float]:
    """Parser remap: roll=s1, pitch=-s0, yaw=s2 (what QML receives)."""
    s0, s1, s2 = decode_slots(payload)
    return s1, -s0, s2


def decode_rtk_heading(data: str) -> float:
    raw = data[len(RPY_PREFIX):].split()
    vals = [int(b, 16) for b in raw]
    counts = vals[0] | (vals[1] << 8)
    return counts * 0.01


def decode_slew(data: str) -> float:
    raw = data[len(RPY_PREFIX):].split()
    vals = [int(b, 16) for b in raw]
    counts = vals[0] | (vals[1] << 8)
    return counts / SLEW_COUNTS_PER_REV * 360.0


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--model", default="sy135")
    ap.add_argument("--sample", type=int, default=25, help="print every Nth frame trace")
    args = ap.parse_args()

    comp = IMU_MOUNT_COMPENSATION_DEG[args.model]
    link_order = ["body", "boom", "arm", "bucket"]

    traces = defaultdict(list)  # link -> [(ticktext, roll, pitch, yaw, elev)]
    heading_trace = []  # (time, rtk_heading_deg) - what QML uses
    slew_trace = []  # (time, slew_deg)
    times = []

    with open(args.csv, encoding="utf-8-sig", newline="") as f:
        r = csv.reader(f)
        next(r)
        for row in r:
            if len(row) < 10:
                continue
            _idx, systime, _ts, _ch, _dir, idtxt, _ft, _ff, _len, data = row[:10]
            try:
                frame_id = int(idtxt, 16)
            except ValueError:
                continue
            if not data.startswith(RPY_PREFIX):
                continue
            time_sec = parse_time(systime.strip('="'))
            times.append(time_sec)
            if frame_id == RTK_HEADING_ID:
                heading_trace.append((time_sec, decode_rtk_heading(data)))
                continue
            if frame_id == SLEW_ID:
                slew_trace.append((time_sec, decode_slew(data)))
                continue
            link = LINK_BY_ID.get(frame_id)
            if link is None:
                continue
            roll, pitch, yaw = parser_reported(data)
            maxrate = max(abs(roll), abs(pitch), abs(yaw))
            if maxrate > 359.9:
                continue  # invalid all-zero-ish frame
            elev = comp.get(link, 0.0) - pitch  # godot elevation = comp - reported pitch
            traces[link].append((systime.strip('="'), roll, pitch, yaw, elev))

    if not traces:
        print("no ruifen frames found")
        return

    t0 = min(times)
    t1 = max(times)
    print(f"model={args.model}  duration={t1 - t0:.3f}s  ({t0:.3f} -> {t1:.3f})")

    if heading_trace:
        h = [row[1] for row in heading_trace]
        huw = [h[0]]
        for a, b in zip(h, h[1:]):
            d = b - a
            while d > 180.0:
                d -= 360.0
            while d < -180.0:
                d += 360.0
            huw.append(huw[-1] + d)
        print(f"\n=== RTK heading (0x0CFDA900, what QML uses for 航向角) ===")
        print(f"  first={h[0]:8.2f}  last={h[-1]:8.2f}")
        print(f"  cumulative unwrapped change (first->last) = {huw[-1] - h[0]:+8.2f} deg")
        print(f"  |delta| = {abs(huw[-1] - h[0]):.2f} deg   raw range [{min(h):.2f}, {max(h):.2f}]")
        print(f"  samples: " + " ".join(f"{v:+.1f}" for v in h[:: max(1, len(h) // 12)]))

    if slew_trace:
        s = [row[1] for row in slew_trace]
        print(f"\n=== slew 0x18FFF000 ===")
        print(f"  first={s[0]:8.2f}  last={s[-1]:8.2f}  raw range [{min(s):.2f}, {max(s):.2f}]")
        print(f"  samples: " + " ".join(f"{v:+.1f}" for v in s[:: max(1, len(s) // 12)]))

    for link in link_order:
        tr = traces[link]
        print(f"\n=== {link} ({len(tr)} frames) ===")

        # start / end (from the first & last frame) for heading question
        t, r0, p0, y0, e0 = tr[0]
        t, r1, p1, y1, e1 = tr[-1]

        print(f"  first @{tr[0][0][:12]}  roll={r0:7.2f} pitch={p0:7.2f} yaw={y0:7.2f} (elev={e0:7.2f})")
        print(f"  last  @{tr[-1][0][:12]}  roll={r1:7.2f} pitch={p1:7.2f} yaw={y1:7.2f} (elev={e1:7.2f})")

        # heading (yaw) unwrapped cumulative change for the body
        if link == "body":
            yaws = [row[3] for row in tr]
            # unwrap
            unw = [yaws[0]]
            for a, b in zip(yaws, yaws[1:]):
                d = b - a
                while d > 180.0:
                    d -= 360.0
                while d < -180.0:
                    d += 360.0
                unw.append(unw[-1] + d)
            print(f"  yaw range   : [{min(yaws):7.2f}, {max(yaws):7.2f}] deg")
            print(f"  unwrapped cumulative yaw change: first->last = {unw[-1] - unw[0]:+9.2f} deg")
            print(f"  abs cumulative heading change (|\u0394|) = {abs(unw[-1] - unw[0]):7.2f} deg")
            monotonic = all(b - a >= 0 for a, b in zip(unw, unw[1:])) or all(
                b - a <= 0 for a, b in zip(unw, unw[1:]))
            print(f"  monotonic   : {monotonic}")

        # range of reported pitch/elevation
        pmin = min(row[2] for row in tr)
        pmax = max(row[2] for row in tr)
        emin = min(row[4] for row in tr)
        emax = max(row[4] for row in tr)
        print(f"  pitch range : [{pmin:7.2f}, {pmax:7.2f}] deg  (QML-received)")
        print(f"  elev range  : [{emin:7.2f}, {emax:7.2f}] deg  (godot-intended abs segment elevation)")

        # sample trace
        print(f"  sample every {args.sample}:  time   roll   pitch  yaw   (elev)")
        step = max(1, args.sample)
        for i, (t, r, p, y, e) in enumerate(tr):
            if i % step == 0:
                print(f"    {t[:12]}  {r:6.2f} {p:6.2f} {y:6.2f}  ({e:6.2f})")

    # downstream QML posture from a near-rest frame
    if "boom" in traces and "arm" in traces and "bucket" in traces:
        print("\n=== QML Sensor2Ang posture (wire -> boomPhi/armPhi/bktPhi), 4-bar replicated ===")
        for i in (0, 50, 150, 250, len(traces["boom"]) - 1):
            p_b = traces["boom"][i][2]
            p_a = traces["arm"][i][2]
            p_k = traces["bucket"][i][2]
            body_pitch = traces["body"][i][2] if "body" in traces else 0.0
            boom_phi, arm_phi, bkt_phi = sensor2ang(p_b, p_a, p_k, body_pitch)
            print(f"  t={traces['boom'][i][0][:12]}  p_b={p_b:7.2f} p_a={p_a:7.2f} p_k={p_k:7.2f}"
                  f"  boomPhi={boom_phi:7.2f} armPhi={arm_phi:7.2f} bktPhi={bkt_phi:7.2f}")


if __name__ == "__main__":
    main()
