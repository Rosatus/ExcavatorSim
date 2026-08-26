"""Bind the gateway port, summarize live packets from a running game."""

from __future__ import annotations

import json
import socket
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from conventions import parse_packet  # noqa: E402


def main() -> int:
    duration_s = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("127.0.0.1", 29764))
    sock.settimeout(1.0)
    deadline = time.time() + duration_s
    count = 0
    first = None
    last = None
    while time.time() < deadline:
        try:
            data, _ = sock.recvfrom(4096)
        except socket.timeout:
            continue
        sample = parse_packet(data)
        if sample is None:
            print("BAD PACKET", data[:16].hex())
            continue
        if first is None:
            first = sample
        last = sample
        count += 1
    sock.close()
    if count == 0 or first is None or last is None:
        print(json.dumps({"packets": 0}))
        return 1
    def brief(s):
        return {
            "tick_ms": s.tick_ms,
            "chassis_origin": [round(v, 3) for v in s.bodies["chassis"].origin_m],
            "bucket_origin": [round(v, 3) for v in s.bodies["bucket"].origin_m],
            "swing_rad": round(s.swing_rad, 4),
            "tracks": [round(s.track_left_mps, 3), round(s.track_right_mps, 3)],
        }
    print(json.dumps({"packets": count, "first": brief(first), "last": brief(last)}))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
