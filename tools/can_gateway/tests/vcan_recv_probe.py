import socket, struct, sys

s = socket.socket(socket.AF_CAN, socket.SOCK_RAW, socket.CAN_RAW)
s.bind(("vcan0",))
s.settimeout(3)
seen = {}
try:
    while len(seen) < 5:
        frame = s.recv(16)
        can_id, dlc = struct.unpack("<IB", frame[:5])
        key = hex(can_id)
        if key not in seen:
            seen[key] = frame[8:8 + dlc].hex()
except socket.timeout:
    pass
print("received distinct frames:", seen)
sys.exit(0 if len(seen) >= 4 else 1)
