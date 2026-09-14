"""Generate SY205's shared joint settings from the unchanged SY135 baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from datetime import date
from pathlib import Path
from typing import Any

from sync_equipment_command_profile import hash_script

ROOT = Path(__file__).resolve().parents[2]


def _read(root: Path, path: str) -> Any:
    return json.loads((root / path).read_text(encoding="utf-8"))


def _json_bytes(value: Any) -> bytes:
    return (json.dumps(value, indent=2, ensure_ascii=False) + "\n").encode("utf-8")


def _provenance_bytes(source: str, entries: list[dict[str, Any]]) -> bytes:
    """Replace only the two owned records, preserving other asset evidence."""
    replacements = {entry["destination_path"]: entry for entry in entries}
    decoder = json.JSONDecoder()
    cursor = source.index("[", source.index('"generated_assets"')) + 1
    patches: list[tuple[int, int, str]] = []
    while True:
        while source[cursor].isspace() or source[cursor] == ",":
            cursor += 1
        if source[cursor] == "]":
            break
        item, end = decoder.raw_decode(source, cursor)
        path = item["destination_path"]
        if path in replacements:
            rendered = json.dumps(replacements[path], indent=2, ensure_ascii=False)
            patches.append((cursor, end, rendered.replace("\n", "\n    ")))
        cursor = end
    for start, end, rendered in reversed(patches):
        source = source[:start] + rendered + source[end:]
    return source.encode("utf-8")


def generated_files(root: Path = ROOT) -> dict[str, bytes]:
    rig_path = "godot/client/resources/physics/sy205_physics_rig.json"
    rig = _read(root, rig_path)
    baseline = _read(root, "godot/client/resources/physics/sy135_physics_rig.json")
    shared = {joint["name"]: joint for joint in baseline["joints"]}
    for joint in rig["joints"]:
        source = shared[joint["name"]]
        joint["limit_rad"] = source["limit_rad"]
        if joint["name"] == "bucket_joint":
            # Imported teeth approach the stick at -45 degrees. Keep curl
            # clearance and restore the asset's wider dumping stroke.
            joint["limit_rad"] = [math.radians(-20.0), math.radians(95.0)]
        joint["actuator"] = source["actuator"]
        # SY205's baked geometry faces +Z. Keep its rest/anchors intact while
        # converting the three imported +X hinges to the common logical q.
        joint["axis"] = [0.0, 1.0, 0.0] if joint["name"] == "swing_joint" else [-1.0, 0.0, 0.0]
    rig_bytes = _json_bytes(rig)
    catalog_path = "godot/client/resources/models/model_catalog.json"
    catalog = _read(root, catalog_path)
    for model in catalog["models"]:
        if model["model_id"] == "sy205":
            model["physics_rig_sha256"] = hashlib.sha256(rig_bytes).hexdigest()
            # Compatibility locomotion consumes the catalog, Jolt the rig.
            model["tracked_locomotion"]["local_forward_axis"] = rig["tracks"][
                "local_forward_axis"
            ]

    profile_path = "protocol/equipment-command-profile-v1.json"
    profile = _read(root, profile_path)
    profile["models"]["sy205"]["semantic_to_joint_signs"] = profile["models"]["sy135"][
        "semantic_to_joint_signs"
    ]
    profile_bytes = _json_bytes(profile)
    outputs = {
        rig_path: rig_bytes,
        catalog_path: _json_bytes(catalog),
        profile_path: profile_bytes,
        "godot/client/resources/protocol/equipment-command-profile-v1.json": profile_bytes,
        "godot/client/scripts/equipment_command_profile_hash.gd": hash_script(profile_bytes),
    }
    provenance_path = "assets/provenance.json"
    provenance = _read(root, provenance_path)
    owned_entries = []
    generator_path = "backend/scripts/sync_sy205_joint_contract.py"
    generator = {
        "path": generator_path,
        "sha256": hashlib.sha256(
            (root / generator_path).read_bytes().replace(b"\r\n", b"\n")
        ).hexdigest(),
    }
    for entry in provenance["generated_assets"]:
        destination = entry["destination_path"]
        if destination not in (
            "godot/client/resources/protocol/equipment-command-profile-v1.json",
            "godot/client/scripts/equipment_command_profile_hash.gd",
        ):
            continue
        digest = hashlib.sha256(outputs[destination]).hexdigest()
        if entry["destination_sha256"] != digest or entry["generator"] != generator:
            entry["generated_at"] = date.today().isoformat()
        entry["destination_sha256"] = digest
        entry["generator"] = generator
        owned_entries.append(entry)
        helper_path = "backend/scripts/sync_equipment_command_profile.py"
        if not any(item["path"] == helper_path for item in entry["inputs"]):
            entry["inputs"].append({"path": helper_path})
        for item in entry["inputs"]:
            if item["path"] == profile_path:
                item["sha256"] = hashlib.sha256(profile_bytes).hexdigest()
            elif item["path"] == helper_path:
                item["sha256"] = hashlib.sha256(
                    (root / helper_path).read_bytes().replace(b"\r\n", b"\n")
                ).hexdigest()
    outputs[provenance_path] = _provenance_bytes(
        (root / provenance_path).read_text(encoding="utf-8"), owned_entries
    )
    return outputs


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    outputs = generated_files()
    stale = [path for path, data in outputs.items() if (ROOT / path).read_bytes() != data]
    if args.check:
        if stale:
            raise SystemExit("SY205 joint contract is stale: " + ", ".join(stale))
        print("SY205 joint contract is synchronized with SY135.")
        return 0
    for path in stale:
        (ROOT / path).write_bytes(outputs[path])
    print(f"Synchronized SY205 joint contract ({len(stale)} files updated).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
