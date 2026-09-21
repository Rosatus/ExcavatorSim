"""Reproducible SY155W GLB adaptation. Never writes into the supplied source folder.

Run with repository Python: tools/import_sy155w.py --source <SY155W directory>.
Mesh/accessor bytes and materials are preserved. Animated transforms are sampled,
semantic pivot bases are changed by rigid coordinate changes, and the bucket tree
is removed. The four authority joints have a source-specific neutral; their fifth
folding joint stays local, as in SY80U. Limits are demonstrated animation ranges.
"""

import argparse
import copy
import hashlib
import json
import math
import struct
from pathlib import Path

import numpy as np
from scipy.spatial.transform import Rotation

REPO = Path(__file__).resolve().parents[1]
CLIENT = REPO / "godot/client"
ID = "sy155w"
VERSION = "sy155w-source-urdf-v1"
FRAMES = ["base_link", "upper_structure_link", "boom_link", "arm_link", "bucket_link"]
NAMES = ["CHASSIS", "SLEW", "BOOM_BASE", "STICK", "BUCKET_JOINT"]
IDENTITY = np.eye(4)
# Blender -> glTF and source forward +X -> runtime forward -Z.
C = np.array([[1, 0, 0, 0], [0, 0, 1, 0], [0, -1, 0, 0], [0, 0, 0, 1.0]])
H = np.array([[0, 0, 1, 0], [0, 1, 0, 0], [-1, 0, 0, 0], [0, 0, 0, 1.0]])


def sha(p):
    return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def dump(p, value):
    p = Path(p)
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")


def read(p):
    return json.loads(Path(p).read_text(encoding="utf-8"))


def rx(degrees):
    result = IDENTITY.copy()
    result[:3, :3] = Rotation.from_euler("x", degrees, degrees=True).as_matrix()
    return result


def trans(v):
    result = IDENTITY.copy()
    result[:3, 3] = v
    return result


def rows(m):
    return np.round(m, 9).tolist()


def trs(n):
    if "matrix" in n:
        return np.array(n["matrix"]).reshape(4, 4).T
    result = IDENTITY.copy()
    result[:3, :3] = Rotation.from_quat(n.get("rotation", [0, 0, 0, 1])).as_matrix() @ np.diag(
        n.get("scale", [1, 1, 1])
    )
    result[:3, 3] = n.get("translation", [0, 0, 0])
    return result


def set_trs(n, m):
    for key in ["matrix", "translation", "rotation", "scale"]:
        n.pop(key, None)
    scale = np.linalg.norm(m[:3, :3], axis=0)
    n["translation"] = m[:3, 3].tolist()
    n["rotation"] = Rotation.from_matrix(m[:3, :3] / scale).as_quat().tolist()
    n["scale"] = scale.tolist()


def point(v):
    return (H @ C @ np.array([*v, 1.0]))[:3].tolist()


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--source", type=Path, default=Path("C:/code/blender/Excavator/SY155W"))
    args = ap.parse_args()
    source = args.source / "SANY_SY155W_Animated.glb"
    raw = source.read_bytes()
    size = struct.unpack_from("<I", raw, 12)[0]
    doc = json.loads(raw[20 : 20 + size])
    binary = raw[28 + size :]

    def accessor(index):
        a = doc["accessors"][index]
        view = doc["bufferViews"][a["bufferView"]]
        width = {"SCALAR": 1, "VEC2": 2, "VEC3": 3, "VEC4": 4}[a["type"]]
        dtype = {5126: "<f4", 5125: "<u4", 5123: "<u2", 5121: "u1"}[a["componentType"]]
        stride = view.get("byteStride", np.dtype(dtype).itemsize * width)
        return np.ndarray(
            (a["count"], width),
            dtype=dtype,
            buffer=binary,
            offset=view.get("byteOffset", 0) + a.get("byteOffset", 0),
            strides=(stride, np.dtype(dtype).itemsize),
        ).copy()

    # Source frame 91 (3 s into Work_Cycle) is the midpoint of every demonstrated
    # work joint range. Default node TRS is absent for animated source nodes.
    clip = next(a for a in doc["animations"] if a["name"] == "Work_Cycle")
    for channel in clip["channels"]:
        s = clip["samplers"][channel["sampler"]]
        times = accessor(s["input"]).reshape(-1)
        index = int(np.argmin(abs(times - 3.0)))
        assert abs(times[index] - 3.0) < 0.002
        path = channel["target"]["path"]
        data = accessor(s["output"])
        node = doc["nodes"][channel["target"]["node"]]
        node[path] = (
            data.reshape(len(times), -1)[index] if path == "weights" else data[index]
        ).tolist()

    nodes = doc["nodes"]
    by_name = {n["name"]: i for i, n in enumerate(nodes)}
    parents = {child: i for i, n in enumerate(nodes) for child in n.get("children", [])}
    old_locals = [trs(n) for n in nodes]

    pivot_names = set([*NAMES, "SY155W_ROOT", "BOOM_OUTER"])
    for index, n in enumerate(nodes):
        parent = parents.get(index)
        # W_new = H W_source A; only semantic frames change their local basis.
        a = H.T if n["name"] in pivot_names else IDENTITY
        pa = H.T if parent is not None and nodes[parent]["name"] in pivot_names else IDENTITY
        local = np.linalg.inv(pa) @ old_locals[index] @ a
        if parent is None:
            local = H @ local
        set_trs(n, local)

    remove = set()

    def descendants(index):
        remove.add(index)
        for child in nodes[index].get("children", []):
            descendants(child)

    descendants(by_name["BUCKET_ROOT"])
    for n in nodes:
        if "children" in n:
            n["children"] = [i for i in n["children"] if i not in remove]
    # Preserve a wrapper so Godot's imported scene root renaming does not change paths.
    wrapper = len(nodes)
    nodes.append({"name": "SY155W_Runtime", "children": doc["scenes"][0]["nodes"]})
    doc["scenes"] = [{"name": "SY155W_Runtime", "nodes": [wrapper]}]
    doc["scene"] = 0
    kept = [i for i in range(len(nodes)) if i not in remove]
    remap = {old: new for new, old in enumerate(kept)}
    nodes = [nodes[i] for i in kept]
    for n in nodes:
        if "children" in n:
            n["children"] = [remap[i] for i in n["children"]]
    doc["nodes"] = nodes
    doc["scenes"][0]["nodes"] = [remap[wrapper]]
    used_meshes = sorted({n["mesh"] for n in nodes if "mesh" in n})
    meshes = {old: new for new, old in enumerate(used_meshes)}
    doc["meshes"] = [doc["meshes"][i] for i in used_meshes]
    for n in nodes:
        if "mesh" in n:
            n["mesh"] = meshes[n["mesh"]]
    doc.pop("animations", None)
    doc["asset"]["extras"] = {
        "source_sha256": sha(source),
        "adapter": "tools/import_sy155w.py",
        "native_tool": "none",
        "neutral_source_frame": 91,
    }
    # BIN geometry is unchanged; orphaned accessors are not imported as scene nodes.
    encoded = json.dumps(doc, separators=(",", ":")).encode()
    encoded += b" " * (-len(encoded) % 4)
    glb = CLIENT / "assets/visual/SY155W_excavator_godot.glb"
    glb.write_bytes(
        struct.pack("<III", 0x46546C67, 2, 28 + len(encoded) + len(binary))
        + struct.pack("<II", len(encoded), 0x4E4F534A)
        + encoded
        + struct.pack("<II", len(binary), 0x004E4942)
        + binary
    )
    by_name = {n["name"]: i for i, n in enumerate(nodes)}
    parents = {child: i for i, n in enumerate(nodes) for child in n.get("children", [])}

    def path(name):
        i = by_name[name]
        parts = [name]
        while i in parents:
            i = parents[i]
            parts.append(nodes[i]["name"])
        return "/".join(reversed(parts)).replace(".", "_")

    def world(name):
        i = by_name[name]
        result = trs(nodes[i])
        while i in parents:
            i = parents[i]
            result = trs(nodes[i]) @ result
        return result

    fw = {frame: world(name) for frame, name in zip(FRAMES, NAMES, strict=True)}
    # Independent source design equations, NOT frames generated from this GLB.
    source_fw = {"base_link": IDENTITY, "upper_structure_link": trans([0, 1.2, 0])}
    source_fw["boom_link"] = source_fw["upper_structure_link"] @ trans([0.23, 0.39, -0.65]) @ rx(58)
    outer = source_fw["boom_link"] @ trans([0, 0, -1.93]) @ rx(-47)
    source_fw["arm_link"] = outer @ trans([0, 0, -3.10]) @ rx(-99)
    source_fw["bucket_link"] = source_fw["arm_link"] @ trans([0, 0, -2.5]) @ rx(97)
    for f in FRAMES:
        assert np.max(abs(fw[f] - source_fw[f])) < 2e-5, (f, fw[f], source_fw[f])

    mani = read(CLIENT / "resources/visual/sy135_visual_manifest.json")
    mani.update(
        schema_version="sy155w-visual-v1",
        asset_id="sy155w-excavator",
        asset_path="res://assets/visual/" + glb.name,
    )
    mani["source"] = {
        "path": str(source),
        "sha256": sha(source),
        "runtime_sha256": sha(glb),
        "byte_size": len(raw),
        "adaptation": (
            "repaired source blend; sample frame 91; rigid pivot coordinate changes; "
            "omit bucket subtree and animation players"
        ),
        "semantic_zero_provenance": (
            "Independent build_sy155w.py params(Work_Cycle, .25): "
            "[58,-47,-99,97] degrees; own two-piece-boom authority neutral"
        ),
    }
    mani["inspection"] = {
        "scene_count": 1,
        "gltf_node_count": len(nodes),
        "mesh_count": len(doc["meshes"]),
        "material_count": len(doc["materials"]),
        "embedded_image_count": len(doc["images"]),
        "animation_count": 0,
        "removed_bucket_nodes": len(remove),
    }
    contracts, frame_map, pivots = {}, {}, {}
    for idx, (f, name) in enumerate(zip(FRAMES, NAMES, strict=True)):
        parent_frame = "" if idx == 0 else FRAMES[idx - 1]
        axis = "none" if idx == 0 else "Y" if idx == 1 else "X"
        local = trs(nodes[by_name[name]])
        contracts[f] = {
            "parent_frame": parent_frame,
            "runtime_axis": axis,
            "parent_local_position": local[:3, 3].tolist(),
            "scale": [1, 1, 1],
        }
        if f == "arm_link":
            contracts[f]["via_local_axis"] = "boom_fold"
        visuals = [
            path(nodes[c]["name"])
            for c in nodes[by_name[name]].get("children", [])
            if "mesh" in nodes[c]
        ]
        frame_map[f] = {"node_path": path(name), "pivot_axis": axis, "visual_nodes": visuals}
        pivots[name] = {
            "node_path": path(name),
            "parent_path": path(nodes[parents[by_name[name]]]["name"]),
            "local_position": local[:3, 3].tolist(),
            "scale": [1, 1, 1],
            "runtime_axis": axis,
        }
    mani["frame_map"] = frame_map
    mani["local_kinematics"]["frame_contracts"] = contracts
    mani["pivot_contract"]["nodes"] = pivots
    mani["passive_linkage"] = {"mode": "none"}
    mani["excavation_contact"] = {
        "mode": "node",
        "frame": "bucket_link",
        "node_path": path("TOOL_SOCKET"),
    }
    mani["local_articulation"] = {
        "mode": "godot_presentation_axes",
        "axes": [
            {
                "axis_id": "boom_fold",
                "node_path": path("BOOM_OUTER"),
                "parent_frame": "boom_link",
                "runtime_axis": "X",
                "local_position": [0, 0, -1.93],
                "scale": [1, 1, 1],
                "min_degrees": -10.0,
                "max_degrees": 10.0,
                "max_rate_degrees_per_second": 12.0,
                "positive_semantic": "unfold",
                "negative_semantic": "fold",
                "input": {
                    "positive_action": "operator_boom_swing_right",
                    "negative_action": "operator_boom_swing_left",
                },
                "evidence": (
                    "Source Work_Cycle -57..-37 deg; "
                    "conservative demonstrated range, not factory limits"
                ),
            }
        ],
    }

    cylinders = []
    cylinder_defs = [
        ("BOOM_LIFT_L", "SLEW", (1.02, 0.09, 0.30), "BOOM_BASE", (1.4, 0.32, -0.17)),
        ("BOOM_LIFT_R", "SLEW", (1.02, -0.55, 0.30), "BOOM_BASE", (1.4, -0.32, -0.17)),
        ("BOOM_ARTICULATION", "BOOM_BASE", (0.50, 0, -0.36), "BOOM_OUTER", (0.78, 0, -0.43)),
        ("STICK_CYLINDER", "BOOM_OUTER", (0.59, 0, 0.54), "STICK", (-0.60, 0, 0.18)),
        ("BUCKET_CYLINDER", "STICK", (0.26, 0, 0.40), "BUCKET_ROCKER", (0.32, 0, 0)),
        ("BLADE_CYLINDER", "CHASSIS", (-1.80, 0, 0.86), "BLADE_PIVOT", (-0.4235, 0, -0.02)),
    ]
    for name, a, pa, b, pb in cylinder_defs:

        def in_frame(n, p):
            return point(p) if n in pivot_names else (C @ np.array([*p, 1]))[:3].tolist()

        cylinders.append(
            {
                "id": name,
                "barrel": path(name + "_BARREL"),
                "rod": path(name + "_ROD"),
                "a_node": path(a),
                "a_point": in_frame(a, pa),
                "b_node": path(b),
                "b_point": in_frame(b, pb),
            }
        )
    hoses = []
    for j, drive, rest, lo, hi in [
        (0, "BOOM_BASE", 58, 45, 70),
        (1, "BOOM_OUTER", -47, -62, -32),
        (2, "STICK", -99, -112, -85),
    ]:
        for k in range(4):
            hoses.append(
                {
                    "mesh": path(f"HOSE_J{j}_{k}"),
                    "joint": path(drive),
                    "rest_degrees": rest,
                    "min_degrees": lo,
                    "max_degrees": hi,
                    "target_count": 41,
                }
            )
    mani["passive_hydraulics"] = {
        "cylinders": cylinders,
        "hoses": hoses,
        "four_bar": {
            "arm": path("STICK"),
            "bucket": path("BUCKET_JOINT"),
            "rocker": path("BUCKET_ROCKER"),
            "coupler": path("BUCKET_COUPLER"),
            "bucket_pin": point((0.22, 0, 0.26)),
            "rocker_tip": [0.32, 0, 0],
            "rocker_length_m": 0.32,
            "coupler_length_m": 0.48,
        },
        "policy": (
            "visual only; solve after active pivots; atomic retain on invalid or unreachable pins"
        ),
    }
    mani["calibration"] = {
        "status": "source_equations_cross_checked",
        "rest_transforms_godot": {f: rows(m) for f, m in fw.items()},
        "authority_fixture": "godot/client/tests/fixtures/sy155w_frame_parity_cases.json",
    }
    mani["runtime_policy"] = {
        "motion_authority": "selected_runtime_profile",
        "local_articulation": "godot_presentation_axes",
        "native_tool": "none",
        "locomotion": "existing_chassis_approximation",
        "blade": "parked_source_pose",
    }

    rig = read(CLIENT / "resources/physics/sy135_physics_rig.json")
    rig.update(
        rig_id="sy155w-jolt-rig",
        rig_version="sy155w-jolt-rig-v1",
        model_id=ID,
        model_version=VERSION,
    )
    rig["provenance"] = {
        "status": "provisional",
        "source_paths": [str(source), "tools/import_sy155w.py"],
        "notes": (
            "Source pin equations and demonstrated ranges; mass and wheeled chassis dynamics "
            "are provisional. Folding is presentation-local. "
            "Soil queries use neutral mounted XTR13/GB12 geometry."
        ),
    }
    centers = [[0, 0.78, 0], [0, 0.65, 0.3], [0, 0, -0.96], [0, 0, -1.25], [0, 0, 0]]
    sizes = [
        [2.55, 0.4, 3.4],
        [2.55, 1.8, 3.4],
        [0.65, 0.8, 1.93],
        [0.5, 0.55, 2.5],
        [0.1, 0.1, 0.1],
    ]
    for idx, body in enumerate(rig["bodies"]):
        body["rest_transform_godot"] = rows(source_fw[body["frame"]])
        body["center_of_mass_m"] = centers[idx]
        body["shape"] = {"kind": "box", "center_m": centers[idx], "size_m": sizes[idx]}
    limits = [[-180, 180], [-7, 7], [-9, 9], [-15, 15]]
    for idx, joint in enumerate(rig["joints"]):
        parent, child = FRAMES[idx : idx + 2]
        joint["parent_anchor_godot"] = rows(np.linalg.inv(source_fw[parent]) @ source_fw[child])
        joint["child_anchor_godot"] = rows(IDENTITY)
        joint["limit_rad"] = [math.radians(v) for v in limits[idx]]
    rig["chassis_dynamics"]["mass_kg"] = 15000.0
    rig["chassis_dynamics"]["compound_shapes"] = [
        {"kind": "box", "center_m": [0, 0.535, 0], "size_m": [2.55, 1.03, 3.55]},
        {"kind": "box", "center_m": [0, 1.65, 0.3], "size_m": [2.55, 1.15, 3.4]},
    ]
    rig["tracks"].update(gauge_m=1.944, contact_length_m=2.6, contact_width_m=2.55)
    rig["quality_flags"] = [
        "source_equations_validated",
        "demonstrated_joint_ranges",
        "unverified_mass_properties",
        "wheeled_visual_with_provisional_chassis_dynamics",
    ]
    rig_path = CLIENT / "resources/physics/sy155w_physics_rig.json"
    dump(rig_path, rig)
    soil_path = CLIENT / "resources/models/sy155w_soil_contract.json"
    soil = read(CLIENT / "resources/attachments/gb12_s50_soil_contract.json")
    soil["model_id"] = ID
    # The host physics contract queries in bucket_link, whereas the active
    # attachment contract is in GB12_ROOT. Translate by the measured neutral
    # XTR13 socket offset. Tilt/rotation continue using the existing attachment
    # presentation boundary; they do not become authority joints.
    attachment_raw = (CLIENT / "assets/visual/XTR13_Tiltrotator_Animated.glb").read_bytes()
    attachment_size = struct.unpack_from("<I", attachment_raw, 12)[0]
    attachment_doc = json.loads(attachment_raw[20 : 20 + attachment_size])
    attachment_nodes = {n["name"]: n for n in attachment_doc["nodes"]}
    socket_transform = IDENTITY.copy()
    for name in ["UPPER_FIXED", "TILT_Y", "ROTATE_Z", "S50_TOOL_SOCKET"]:
        socket_transform = socket_transform @ trs(attachment_nodes[name])
    assert np.max(abs(socket_transform[:3, :3] - np.eye(3))) < 1e-6
    offset = socket_transform[:3, 3]
    for proxy in soil["proxies"].values():
        if "center_godot" in proxy:
            proxy["center_godot"] = (np.array(proxy["center_godot"]) + offset).tolist()
    for region in soil["bucket_tool"]["regions"]:
        region["center_godot"] = (np.array(region["center_godot"]) + offset).tolist()
    # Geometry/fill profiles remain attached to GB12_ROOT at runtime, never to
    # the host's offset query frame. The regular host contract only needs proxies.
    soil.pop("soil_geometry", None)
    dump(soil_path, soil)

    # Model-specific URDF for compatibility mode. The outer boom is fixed at its
    # neutral only in the four-axis authority model, matching the local-axis seam.
    xml = ['<?xml version="1.0"?>', '<robot name="sy155w">', '<link name="base_link"/>']
    for idx, joint in enumerate(rig["joints"]):
        parent, child = FRAMES[idx : idx + 2]
        a = np.linalg.inv(C) @ np.array(joint["parent_anchor_godot"]) @ C
        xyz = " ".join(f"{v:.10f}" for v in a[:3, 3])
        rpy = " ".join(f"{v:.10f}" for v in Rotation.from_matrix(a[:3, :3]).as_euler("xyz"))
        axis = "0 0 1" if idx == 0 else "1 0 0"
        low, high = joint["limit_rad"]
        xml += [
            f'<link name="{child}"/>',
            f'<joint name="{joint["name"]}" type="revolute">',
            f'<parent link="{parent}"/><child link="{child}"/>',
            f'<origin xyz="{xyz}" rpy="{rpy}"/>',
            f'<axis xyz="{axis}"/>'
            f'<limit lower="{low}" upper="{high}" effort="1000000" velocity="1"/>',
            "</joint>",
        ]
    tooth = np.array(soil["proxies"]["cutting_edge"]["center_godot"])
    half_width = float(soil["proxies"]["cutting_edge"]["half_width_m"])
    refs = [
        ("tooth_center", "bucket_link", tooth),
        ("tooth_left", "bucket_link", tooth + np.array([-half_width, 0, 0])),
        ("tooth_right", "bucket_link", tooth + np.array([half_width, 0, 0])),
        ("gnss_link", "upper_structure_link", [-0.78, 1.8, 0.1]),
        ("swing_imu_link", "upper_structure_link", [0, 0.3, 0]),
        ("boom_imu_link", "boom_link", [0, 0, -0.965]),
        ("arm_imu_link", "arm_link", [0, 0, -1.25]),
        ("bucket_imu_link", "bucket_link", [0, 0, 0]),
    ]
    for name, parent, position in refs:
        py = np.linalg.inv(C) @ np.array([*position, 1.0])
        xyz = " ".join(f"{v:.10f}" for v in py[:3])
        xml += [
            f'<link name="{name}"/>',
            f'<joint name="{name}_fixed" type="fixed"><parent link="{parent}"/>',
            f'<child link="{name}"/><origin xyz="{xyz}" rpy="0 0 0"/></joint>',
        ]
    xml.append("</robot>")
    urdf_path = REPO / "assets/model/library/sy155w_reference.urdf"
    urdf_path.write_text("\n".join(xml) + "\n", encoding="utf-8")
    fixture = {
        "model_id": ID,
        "model_version": VERSION,
        "source_model_path": str(glb.relative_to(REPO)),
        "source_model_sha256": sha(glb),
        "source_urdf_path": str(urdf_path.relative_to(REPO)),
        "source_urdf_sha256": sha(urdf_path),
        "generator_path": "tools/import_sy155w.py",
        "poses": {},
    }
    import pinocchio

    fixture.update(
        generator_sha256=sha(__file__),
        source_pixi_lock_sha256=sha(REPO / "pixi.lock"),
        pinocchio_version=pinocchio.__version__,
        model_implementation="backend/src/babylon_sim/model.py",
        model_implementation_sha256=sha(REPO / "backend/src/babylon_sim/model.py"),
    )
    pose_defs = {
        "zero": [0, 0, 0, 0],
        "swing_positive_90": [math.pi / 2, 0, 0, 0],
        "boom_only": [0, 0.1, 0, 0],
        "arm_only": [0, 0, 0.1, 0],
        "bucket_only": [0, 0, 0, 0.2],
        "asymmetric": [0.4, -0.1, 0.12, -0.2],
    }
    for name, angles in pose_defs.items():
        frames = {"base_link": IDENTITY}
        for idx, joint in enumerate(rig["joints"]):
            parent, child = FRAMES[idx : idx + 2]
            rotation = IDENTITY.copy()
            rotation[:3, :3] = Rotation.from_rotvec(
                np.array(joint["axis"]) * angles[idx]
            ).as_matrix()
            frames[child] = frames[parent] @ np.array(joint["parent_anchor_godot"]) @ rotation
        fixture["poses"][name] = {
            "joint_angles": angles,
            "frame_transforms": {f: rows(np.linalg.inv(C) @ m @ C) for f, m in frames.items()},
        }
    fixture_path = CLIENT / "tests/fixtures/sy155w_frame_parity_cases.json"
    dump(fixture_path, fixture)
    mani["calibration"]["authority_fixture_sha256"] = sha(fixture_path)
    manifest_path = CLIENT / "resources/visual/sy155w_visual_manifest.json"
    dump(manifest_path, mani)
    catalog_path = CLIENT / "resources/models/model_catalog.json"
    catalog = read(catalog_path)
    entry = copy.deepcopy(next(m for m in catalog["models"] if m["model_id"] == "sy135"))
    entry.update(
        model_id=ID,
        display_name="SANY SY155W",
        model_version=VERSION,
        visual_model_version="sy155w-passive-hydraulics-v1",
        default_attachment={"coupler_id": "xtr13", "tool_id": "gb12"},
    )
    entry.pop("native_tool", None)
    entry["attachment_bucket_limit_offsets_deg"] = {"xtr13": 0.0}
    for prefix, artifact in [
        ("glb", glb),
        ("manifest", manifest_path),
        ("physics_rig", rig_path),
        ("parity_fixture", fixture_path),
        ("soil_contract", soil_path),
    ]:
        entry[prefix + "_path"] = "res://" + artifact.relative_to(CLIENT).as_posix()
        entry[prefix + "_sha256"] = sha(artifact)
    entry["tracked_locomotion"].update(
        track_gauge_m=1.944,
        contact_length_m=2.6,
        contact_width_m=2.55,
        support_front_offset_m=1.3,
        support_rear_offset_m=1.3,
        support_left_offset_m=0.972,
        support_right_offset_m=0.972,
    )
    catalog["models"] = [m for m in catalog["models"] if m["model_id"] != ID] + [entry]
    dump(catalog_path, catalog)
    for profile_name in ["digging_response_profiles.json", "assist_profiles.json"]:
        profile_path = CLIENT / "resources/physics" / profile_name
        profile = read(profile_path)
        profile["models"][ID] = copy.deepcopy(profile["models"]["sy135"])
        dump(profile_path, profile)
    registry_path = REPO / "assets/model/model-registry-v1.json"
    registry = read(registry_path)
    re = copy.deepcopy(next(m for m in registry["models"] if m["model_id"] == "sy80u"))
    re.update(
        model_id=ID,
        display_name="SANY SY155W",
        model_version=VERSION,
        visual_model_version=entry["visual_model_version"],
        urdf_path=urdf_path.relative_to(REPO).as_posix(),
        urdf_sha256=sha(urdf_path),
        passive_linkage_mode="none",
        excavation_contact=mani["excavation_contact"],
    )
    for prefix, artifact in [
        ("godot_glb", glb),
        ("visual_manifest", manifest_path),
        ("parity_fixture", fixture_path),
    ]:
        re[prefix + "_path"] = artifact.relative_to(REPO).as_posix()
        re[prefix + "_resource"] = "res://" + artifact.relative_to(CLIENT).as_posix()
        re[prefix + "_sha256"] = sha(artifact)
    registry["models"] = [m for m in registry["models"] if m["model_id"] != ID] + [re]
    dump(registry_path, registry)
    # Independent source samples survive without the external source tree and are
    # used to check cylinder transforms, four-bar and morph weights in Godot.
    samples = read(args.source / "reports/source_samples.json")["Work_Cycle"]
    oracle = []
    for index in [0, 45, 90, 135, 180, 270, 360]:
        sample = samples[index]
        phase = (1 - math.cos(2 * math.pi * index / 360)) / 2
        oracle.append(
            {
                "phase": phase,
                "angles_deg": [
                    65 - 14 * phase,
                    -57 + 20 * phase,
                    -108 + 18 * phase,
                    112 - 30 * phase,
                ],
                "nodes": {
                    k: v
                    for k, v in sample["nodes"].items()
                    if any(k == n + s for n, *_ in cylinder_defs for s in ["_BARREL", "_ROD"])
                    or k in ["BUCKET_ROCKER", "BUCKET_COUPLER"]
                },
                "weights": sample["weights"],
            }
        )
    oracle_path = CLIENT / "tests/fixtures/sy155w_source_poses.json"
    dump(oracle_path, {"source_sha256": sha(source), "poses": oracle})
    external = [
        source,
        args.source / "scripts/build_sy155w.py",
        args.source / "reports/source_samples.json",
    ]
    external_inputs = [
        {"path": str(p), "sha256": sha(p), "byte_size": p.stat().st_size, "hash_mode": "raw"}
        for p in external
    ]
    evidence_path = REPO / "assets/model/sy155w_source_evidence.json"
    dump(
        evidence_path,
        {
            "model_id": ID,
            "external_inputs": external_inputs,
            "regenerate": (
                "pixi run python tools/import_sy155w.py --source <original SY155W directory>"
            ),
            "neutral_source_frame": 91,
            "joint_degrees": [58, -47, -99, 97],
            "source_is_unmodified": True,
            "default_attachment": "xtr13+gb12",
            "native_bucket_removed_nodes": len(remove),
            "cylinders": cylinder_defs,
            "default_tool_transform_in_bucket_link": rows(socket_transform),
        },
    )

    def canonical_sha(p):
        return hashlib.sha256(Path(p).read_bytes().replace(b"\r\n", b"\n")).hexdigest()

    inputs = [
        evidence_path,
        CLIENT / "resources/visual/sy135_visual_manifest.json",
        CLIENT / "resources/physics/sy135_physics_rig.json",
        CLIENT / "resources/attachments/gb12_s50_soil_contract.json",
        REPO / "backend/src/babylon_sim/model.py",
        REPO / "pixi.lock",
    ]
    recorded_inputs = [
        {"path": p.relative_to(REPO).as_posix(), "sha256": canonical_sha(p)} for p in inputs
    ]
    attachment_path = CLIENT / "assets/visual/XTR13_Tiltrotator_Animated.glb"
    recorded_inputs.append(
        {
            "path": attachment_path.relative_to(REPO).as_posix(),
            "sha256": sha(attachment_path),
            "hash_mode": "raw",
        }
    )
    provenance_path = REPO / "assets/provenance.json"
    provenance = read(provenance_path)
    outputs = [glb, manifest_path, rig_path, soil_path, urdf_path, fixture_path, oracle_path]
    destinations = {p.relative_to(REPO).as_posix() for p in outputs}
    provenance["generated_assets"] = [
        a for a in provenance["generated_assets"] if a["destination_path"] not in destinations
    ]
    for p in outputs:
        # Legacy provenance verifies destination hashes using CRLF canonicalization
        # even for binary files. Keep that declared manifest convention and record
        # the exact binary SHA separately, also pinned in the runtime catalog.
        provenance["generated_assets"].append(
            {
                "destination_path": p.relative_to(REPO).as_posix(),
                "destination_sha256": canonical_sha(p),
                "raw_sha256": sha(p),
                "generator": {"path": "tools/import_sy155w.py", "sha256": canonical_sha(__file__)},
                "inputs": recorded_inputs,
                "external_inputs": external_inputs,
                "license": "user-supplied-source-assets",
                "generated_at": "2026-09-21",
                "relationship": "sy155w-runtime-adaptation",
            }
        )
    dump(provenance_path, provenance)
    print(
        f"Generated SY155W: {len(nodes)} nodes, {len(doc['meshes'])} meshes; "
        f"removed {len(remove)} bucket nodes; 6 passive cylinders, 12 hoses."
    )


if __name__ == "__main__":
    main()
