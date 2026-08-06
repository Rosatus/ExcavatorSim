"""Reproducibly convert the approved original OBJ snapshot to runtime GLBs.

Run this script in an isolated environment containing exactly trimesh 4.11.2. The source checkout
is conversion input only; BabylonSim commits and serves the generated GLBs.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
from pathlib import Path
from typing import Any

import trimesh  # type: ignore[import-not-found]

TRIMESH_VERSION = "4.11.2"
SOURCE_FILES = {
    "base.obj": "base.glb",
    "body.obj": "upper-structure.glb",
    "arm1.obj": "boom.glb",
    "arm2.obj": "arm.glb",
    "shovel.obj": "bucket.glb",
}


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _glb_json(data: bytes) -> dict[str, Any]:
    if len(data) < 20 or data[:4] != b"glTF":
        raise ValueError("export did not produce a GLB 2.0 file")
    _, version, total_length = struct.unpack_from("<4sII", data)
    if version != 2 or total_length != len(data):
        raise ValueError("exported GLB header is inconsistent")
    chunk_length, chunk_type = struct.unpack_from("<II", data, 12)
    if chunk_type != 0x4E4F534A or 20 + chunk_length > len(data):
        raise ValueError("exported GLB has no valid JSON chunk")
    decoded = json.loads(data[20 : 20 + chunk_length].rstrip(b" \x00").decode("utf-8"))
    if not isinstance(decoded, dict):
        raise ValueError("exported GLB JSON root is not an object")
    return decoded


def convert(source_dir: Path, output_dir: Path) -> list[dict[str, object]]:
    if trimesh.__version__ != TRIMESH_VERSION:
        raise RuntimeError(
            f"expected trimesh {TRIMESH_VERSION}, found {trimesh.__version__}; "
            "use the command recorded in assets/visual/original/CONVERSION.md"
        )
    meshes_dir = source_dir / "meshes"
    material_path = meshes_dir / "material.mtl"
    if not material_path.is_file():
        raise FileNotFoundError(f"missing shared source material: {material_path}")
    output_dir.mkdir(parents=True, exist_ok=True)

    records: list[dict[str, object]] = []
    for source_name, output_name in SOURCE_FILES.items():
        source_path = meshes_dir / source_name
        if not source_path.is_file():
            raise FileNotFoundError(f"missing source mesh: {source_path}")
        scene = trimesh.load_scene(source_path, process=True)
        exported = scene.export(file_type="glb", include_normals=True)
        if not isinstance(exported, bytes):
            raise TypeError(f"trimesh returned {type(exported).__name__} for {source_name}")
        document = _glb_json(exported)
        if not document.get("meshes") or not document.get("materials"):
            raise ValueError(f"{source_name} export is missing meshes or materials")
        output_path = output_dir / output_name
        output_path.write_bytes(exported)
        records.append(
            {
                "source": source_name,
                "source_sha256": _sha256(source_path.read_bytes()),
                "output": output_name,
                "output_sha256": _sha256(exported),
                "bytes": len(exported),
                "meshes": len(document["meshes"]),
                "materials": len(document["materials"]),
            }
        )
    return records


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    records = convert(args.source.resolve(), args.output.resolve())
    print(json.dumps(records, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
