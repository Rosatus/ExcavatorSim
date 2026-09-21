"""Audit SY155W GLB geometry: global nearest-neighbor gaps + pivot group membership."""

import json
import struct
import sys
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation

GLB = Path("godot/client/assets/visual/SY155W_excavator_godot.glb")


def load(path):
    raw = path.read_bytes()
    size = struct.unpack_from("<I", raw, 12)[0]
    doc = json.loads(raw[20 : 20 + size])
    binary = raw[28 + size :]
    return doc, binary


def trs(n):
    if "matrix" in n:
        return np.array(n["matrix"]).reshape(4, 4).T
    m = np.eye(4)
    m[:3, :3] = Rotation.from_quat(n.get("rotation", [0, 0, 0, 1])).as_matrix() @ np.diag(
        n.get("scale", [1, 1, 1])
    )
    m[:3, 3] = n.get("translation", [0, 0, 0])
    return m


def main():
    doc, _binary = load(GLB)
    nodes = doc["nodes"]
    parents = {}
    for i, n in enumerate(nodes):
        for c in n.get("children", []):
            parents[c] = i
    world = [None] * len(nodes)

    def compute(i):
        if world[i] is None:
            p = parents.get(i)
            world[i] = trs(nodes[i]) if p is None else compute(p) @ trs(nodes[i])
        return world[i]

    for i in range(len(nodes)):
        compute(i)

    def mesh_aabb(mi):
        mn = np.array([np.inf] * 3)
        mx = -mn.copy()
        for prim in doc["meshes"][mi]["primitives"]:
            a = doc["accessors"][prim["attributes"]["POSITION"]]
            mn = np.minimum(mn, a["min"])
            mx = np.maximum(mx, a["max"])
        return mn, mx

    pivots = {
        "CHASSIS", "SLEW", "BOOM_BASE", "BOOM_OUTER", "STICK",
        "BUCKET_JOINT", "BUCKET_ROCKER", "BUCKET_COUPLER", "BLADE_PIVOT",
        "STEERING_TIE_ROD",
    }

    def group_of(i):
        j = i
        while j is not None:
            name = nodes[j]["name"]
            if name in pivots or name.endswith(("_BARREL", "_ROD", "_STEER", "_ROLL")):
                return name
            j = parents.get(j)
        return "ROOT"

    entries = []
    for i, n in enumerate(nodes):
        if "mesh" not in n:
            continue
        mn, mx = mesh_aabb(n["mesh"])
        w = world[i]
        corners = np.array(
            [[x, y, z, 1.0] for x in (mn[0], mx[0]) for y in (mn[1], mx[1]) for z in (mn[2], mx[2])]
        )
        wc = (w @ corners.T).T[:, :3]
        entries.append(
            {"i": i, "name": n["name"], "group": group_of(i),
             "lo": wc.min(0), "hi": wc.max(0)}
        )

    def gap(a, b):
        d2 = 0.0
        for k in range(3):
            lo = max(a["lo"][k], b["lo"][k])
            hi = min(a["hi"][k], b["hi"][k])
            if lo > hi:
                d2 += (lo - hi) ** 2
        return d2**0.5

    print("=== global nearest-neighbor gap > 0.03 m ===")
    rows = []
    for e in entries:
        best, other = 1e9, None
        for o in entries:
            if o is e:
                continue
            g = gap(e, o)
            if g < best:
                best, other = g, o
        if best > 0.03:
            c = (e["lo"] + e["hi"]) / 2
            s = e["hi"] - e["lo"]
            rows.append((best, e["group"], e["name"], other["name"], c, s))
    rows.sort(key=lambda r: -r[0])
    for g_, grp, name, near, c, s in rows:
        print(
            f"gap={g_:5.3f} [{grp:22s}] {name:46s} near={near:38s} "
            f"ctr=({c[0]:6.2f},{c[1]:6.2f},{c[2]:6.2f}) size=({s[0]:.2f},{s[1]:.2f},{s[2]:.2f})"
        )
    print(f"\ntotal mesh nodes: {len(entries)}; floating candidates: {len(rows)}")


if __name__ == "__main__":
    sys.exit(main())
