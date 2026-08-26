"""Minimal fake ICT client: connects to the gateway PC001 TCP server,
completes the who/PC001 handshake, and prints received CAN frame batches.

Usage:
    python tools/can_gateway/tests/fake_ict_client.py [--host 127.0.0.1] [--port 5678]
"""

from __future__ import annotations

import argparse
import socket
import struct

CAN_FRAME_SIZE = 16
SINGLE_FRAME_SIZE = 20  # can_frame(16) + channel(4)


def recv_exact(sock: socket.socket, n: int) -> bytes:
    data = b""
    while len(data) < n:
        chunk = sock.recv(n - len(data))
        if not chunk:
            raise ConnectionError("server closed connection")
        data += chunk
    return data


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=5678)
    args = parser.parse_args()

    sock = socket.create_connection((args.host, args.port), timeout=5)
    sock.settimeout(5)
    print(f"connected to {args.host}:{args.port}")

    who = recv_exact(sock, 3)
    if who != b"who":
        print(f"unexpected greeting: {who!r}")
        return 1
    print("handshake: got 'who', replying 'PC001'")
    sock.sendall(b"PC001")

    batches = 0
    frames = 0
    try:
        while True:
            (count,) = struct.unpack("<H", recv_exact(sock, 2))
            if count == 0:
                continue
            body = recv_exact(sock, count * SINGLE_FRAME_SIZE)
            batches += 1
            for i in range(count):
                off = i * SINGLE_FRAME_SIZE
                can_id, dlc = struct.unpack("<IB", body[off:off + 5])
                payload = body[off + 8:off + 8 + dlc].hex(" ").upper()
                frames += 1
                if frames <= 12 or frames % 100 == 0:
                    print(f"[{batches:>3}-{i + 1:>3}] ID=0x{can_id:03X} len={dlc} data={payload}")
    except socket.timeout:
        print(f"\nidle timeout — totals: {batches} batches, {frames} frames")
    except ConnectionError as exc:
        print(f"\nconnection ended: {exc} — totals: {batches} batches, {frames} frames")
    finally:
        sock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
