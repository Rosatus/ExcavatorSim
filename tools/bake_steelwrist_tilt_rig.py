#!/usr/bin/env python3
"""Bake the Steelwrist XTR13 passive-mechanism rig table from the authored GLB.

The GLB ships animation clips (Tilt_45, Rotate_360, Tilt_Rotate) whose tracks
already encode the authored pose of every passive node: cylinder pivot aim,
chrome piston extension/aim, and hose morph weights.  The runtime rig drives
TILT_Y/ROTATE_Z directly and replays the baked table for the passive nodes so
the mechanism follows without shipping an AnimationPlayer contract.

Output: godot/client/resources/attachments/xtr13_tilt_rig.json
"""

import json
import math
import struct
import sys
import hashlib
from pathlib import Path

GLB_PATH = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(
    "godot/client/assets/visual/XTR13_Tiltrotator_Animated.glb"
)
OUT_PATH = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(
    "godot/client/resources/attachments/xtr13_tilt_rig.json"
)

TILT_NODE = "TILT_Y"
ROTATE_NODE = "ROTATE_Z"
PASSIVE_ROT_NODES = {"CYLINDER_L_PIVOT", "CYLINDER_R_PIVOT"}
PASSIVE_TRS_NODES = {"Tilt cylinder | chrome piston", "Tilt cylinder | chrome piston.001"}


def read_glb(path: Path):
    raw = path.read_bytes()
    assert raw[:4] == b"glTF", "not a GLB"
    jlen = struct.unpack("<I", raw[12:16])[0]
    gltf = json.loads(raw[20 : 20 + jlen])
    # BIN chunk
    off = 20 + jlen
    blen, btype = struct.unpack("<I4s", raw[off : off + 8])
    assert btype == b"BIN\x00"
    return gltf, raw[off + 8 : off + 8 + blen]


def accessor_data(gltf, bin_chunk, index):
    acc = gltf["accessors"][index]
    bv = gltf["bufferViews"][acc["bufferView"]]
    comp = {5126: ("f", 4), 5123: ("H", 2), 5125: ("I", 4), 5121: ("B", 1)}[acc["componentType"]]
    ncomp = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4, "MAT4": 16}[acc["type"]]
    start = bv.get("byteOffset", 0) + acc.get("byteOffset", 0)
    stride = bv.get("byteStride", comp[1] * ncomp)
    out = []
    for i in range(acc["count"]):
        o = start + i * stride
        out.append(struct.unpack("<" + comp[0] * ncomp, bin_chunk[o : o + comp[1] * ncomp]))
    return out, ncomp


def qnorm(q):
    l = math.sqrt(sum(c * c for c in q)) or 1.0
    return tuple(c / l for c in q)


def twist_deg(q, axis_index):
    """Signed twist angle of quaternion q about basis axis (0=x,1=y,2=z)."""
    q = qnorm(q)
    comp = q[axis_index]
    w = max(-1.0, min(1.0, q[3]))
    ang = math.degrees(2.0 * math.atan2(comp, w))
    while ang > 180.0:
        ang -= 360.0
    while ang < -180.0:
        ang += 360.0
    return ang


def build_paths(gltf):
    """node index -> '/'-joined name path below XTR13_ROOT."""
    parent = {}
    for i, n in enumerate(gltf["nodes"]):
        for c in n.get("children", []):
            parent[c] = i
    paths = {}
    for i, n in enumerate(gltf["nodes"]):
        chain = [n.get("name", "node%d" % i)]
        p = parent.get(i)
        while p is not None:
            chain.append(gltf["nodes"][p].get("name", "node%d" % p))
            p = parent.get(p)
        paths[i] = "/".join(reversed(chain))
    return paths


def bake_clip(gltf, bin_chunk, clip_name, drive_node, axis_index, paths):
    clip = next(a for a in gltf["animations"] if a["name"] == clip_name)
    # gather channels
    rot_tracks = {}   # node name -> sampler index
    trs_tracks = {}
    weight_tracks = {}
    drive_sampler = None
    for ch in clip["channels"]:
        ni = ch["target"].get("node")
        if ni is None:
            continue
        name = gltf["nodes"][ni].get("name", "?")
        path, sidx = ch["target"]["path"], ch["sampler"]
        if name == drive_node and path == "rotation":
            drive_sampler = sidx
        elif path == "rotation":
            rot_tracks[name] = sidx
        elif path == "translation":
            trs_tracks[name] = sidx
        elif path == "weights":
            weight_tracks[name] = sidx
    times, _ = accessor_data(gltf, bin_chunk, clip["samplers"][drive_sampler]["input"])
    drive_quats, _ = accessor_data(gltf, bin_chunk, clip["samplers"][drive_sampler]["output"])
    # preload all outputs (uniform shared input across tracks in this asset)
    def samples(sidx):
        s = clip["samplers"][sidx]
        vals, ncomp = accessor_data(gltf, bin_chunk, s["output"])
        tvals, _ = accessor_data(gltf, bin_chunk, s["input"])
        return [tv[0] for tv in tvals], vals, ncomp

    track_data = {}
    for name, sidx in list(rot_tracks.items()) + list(trs_tracks.items()) + list(weight_tracks.items()):
        track_data[(name, sidx)] = samples(sidx)

    def value_at(name, sidx, t, is_quat=False):
        tvals, vals, _ = track_data[(name, sidx)]
        if t <= tvals[0]:
            return vals[0]
        if t >= tvals[-1]:
            return vals[-1]
        lo = 0
        while tvals[lo + 1] < t:
            lo += 1
        t0, t1 = tvals[lo], tvals[lo + 1]
        f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
        a, b = vals[lo], vals[lo + 1]
        if is_quat:  # nlerp is fine for dense keys
            dot = sum(x * y for x, y in zip(a, b))
            if dot < 0.0:
                b = tuple(-x for x in b)
            return qnorm(tuple(x + (y - x) * f for x, y in zip(a, b)))
        return tuple(x + (y - x) * f for x, y in zip(a, b))

    def weights_at(name, sidx, t):
        # glTF stores morph-weight channels as a flat scalar array of
        # n_keys * n_targets — a key's weight vector starts at index*width.
        tvals, vals, _ = track_data[(name, sidx)]
        flat = [v[0] for v in vals]
        width = len(flat) // len(tvals)

        def vec(k):
            return flat[k * width : (k + 1) * width]

        if t <= tvals[0]:
            return tuple(vec(0))
        if t >= tvals[-1]:
            return tuple(vec(len(tvals) - 1))
        lo = 0
        while tvals[lo + 1] < t:
            lo += 1
        t0, t1 = tvals[lo], tvals[lo + 1]
        f = 0.0 if t1 == t0 else (t - t0) / (t1 - t0)
        a, b = vec(lo), vec(lo + 1)
        return tuple(x + (y - x) * f for x, y in zip(a, b))

    samples_out = []
    for i, t in enumerate(times):
        t = t[0]
        ang = twist_deg(drive_quats[i], axis_index)
        entry = {"angle_deg": round(ang, 3), "nodes": {}, "weights": {}}
        for name, sidx in rot_tracks.items():
            if name not in PASSIVE_ROT_NODES and name not in PASSIVE_TRS_NODES:
                continue
            entry["nodes"][paths_idx(gltf, paths, clip, name, sidx, rot_tracks)] = {
                "r": [round(v, 6) for v in value_at(name, sidx, t, is_quat=True)]
            }
        for name, sidx in trs_tracks.items():
            key = paths_idx(gltf, paths, clip, name, sidx, trs_tracks)
            entry["nodes"].setdefault(key, {})["t"] = [round(v, 6) for v in value_at(name, sidx, t)]
        for name, sidx in weight_tracks.items():
            key = paths_idx(gltf, paths, clip, name, sidx, weight_tracks)
            entry["weights"][key] = [round(v, 5) for v in weights_at(name, sidx, t)]
        samples_out.append(entry)
    return samples_out


def paths_idx(gltf, paths, clip, name, sidx, track_map):
    """Resolve a track's node name to its '/'-path below the glTF scene root."""
    for ch in clip["channels"]:
        if ch["sampler"] == sidx and gltf["nodes"][ch["target"]["node"]].get("name") == name:
            return paths[ch["target"]["node"]]
    return name


def main():
    gltf, bin_chunk = read_glb(GLB_PATH)
    paths = build_paths(gltf)
    sha = hashlib.sha256(GLB_PATH.read_bytes()).hexdigest()
    tilt = bake_clip(gltf, bin_chunk, "Tilt_45", TILT_NODE, 2, paths)
    rotate = bake_clip(gltf, bin_chunk, "Rotate_360", ROTATE_NODE, 1, paths)
    # Verify rotation leaves the passive mechanism untouched so the runtime
    # only needs the tilt table.
    ref_nodes = rotate[0]["nodes"]
    for s in rotate[1:]:
        for path, node_state in s["nodes"].items():
            for key, vals in node_state.items():
                ref_vals = ref_nodes.get(path, {}).get(key, [])
                assert all(
                    abs(v - r) < 1e-3 for v, r in zip(vals, ref_vals)
                ), "Rotate_360 unexpectedly drives passive node %s" % path
    ref_weights = rotate[0]["weights"]
    for s in rotate[1:]:
        for path, weights in s["weights"].items():
            assert all(
                abs(w - r) < 1e-3 for w, r in zip(weights, ref_weights.get(path, []))
            ), "Rotate_360 unexpectedly drives hose weights %s" % path
    rig = {
        "schema_version": "steelwrist-tilt-rig-v1",
        "source_glb": GLB_PATH.name,
        "source_sha256": sha,
        "drive": {
            "tilt_node": TILT_NODE,
            "tilt_local_axis": "z",
            "tilt_range_deg": [-45.0, 45.0],
            "rotate_node": ROTATE_NODE,
            "rotate_local_axis": "y",
        },
        "tilt_samples": tilt,
    }
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(rig, indent=1), encoding="utf-8")
    angles = [s["angle_deg"] for s in tilt]
    print("tilt range:", min(angles), max(angles), "samples:", len(tilt))
    rangles = [s["angle_deg"] for s in rotate]
    print("rotate range:", min(rangles), max(rangles), "samples:", len(rotate))
    # quick sanity: passive nodes present
    print("sample node keys:", sorted(tilt[0]["nodes"].keys())[:5])
    print("sample weight keys:", sorted(tilt[0]["weights"].keys())[:3])
    print("wrote", OUT_PATH)


if __name__ == "__main__":
    main()
