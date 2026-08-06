"""One-time importer for immutable KinematicSim baseline evidence and assets."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import date
from pathlib import Path
from typing import Any

import numpy as np

EXPECTED_COMMIT = "782cceb76afb635b3f9854cf48dbba1ba946f7fb"
SOURCE_REPOSITORY = "https://github.com/Rosatus/KinematicSim.git"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _git(source_root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(source_root), *args],
        check=True,
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def _source_blob(source_root: Path, relative_path: str) -> str:
    return _git(source_root, "rev-parse", f"{EXPECTED_COMMIT}:{relative_path}")


def _rpy_matrix(rpy: tuple[float, float, float], xyz: tuple[float, float, float]) -> np.ndarray:
    roll, pitch, yaw = rpy
    cr, sr = math.cos(roll), math.sin(roll)
    cp, sp = math.cos(pitch), math.sin(pitch)
    cy, sy = math.cos(yaw), math.sin(yaw)
    rx = np.array([[1, 0, 0], [0, cr, -sr], [0, sr, cr]], dtype=float)
    ry = np.array([[cp, 0, sp], [0, 1, 0], [-sp, 0, cp]], dtype=float)
    rz = np.array([[cy, -sy, 0], [sy, cy, 0], [0, 0, 1]], dtype=float)
    transform = np.eye(4)
    transform[:3, :3] = rz @ ry @ rx
    transform[:3, 3] = xyz
    return transform


def _vector(attribute: str | None) -> tuple[float, float, float]:
    if attribute is None:
        return (0.0, 0.0, 0.0)
    values = tuple(float(value) for value in attribute.split())
    if len(values) != 3:
        raise ValueError(f"expected three values, got {attribute!r}")
    return values


def _visual_origins(urdf_path: Path) -> dict[str, np.ndarray]:
    root = ET.parse(urdf_path).getroot()
    origins: dict[str, np.ndarray] = {}
    for link in root.findall("link"):
        visual = link.find("visual")
        if visual is None:
            continue
        origin = visual.find("origin")
        origins[link.attrib["name"]] = _rpy_matrix(
            _vector(None if origin is None else origin.attrib.get("rpy")),
            _vector(None if origin is None else origin.attrib.get("xyz")),
        )
    return origins


def _matrix_rows(matrix: Any) -> list[list[float]]:
    return [[float(value) for value in row] for row in np.asarray(matrix)]


def _provenance_entry(
    source_root: Path,
    source_path: str,
    destination_path: str,
    destination_root: Path,
    *,
    relationship: str,
) -> dict[str, Any]:
    destination = destination_root / destination_path
    return {
        "source_repository": SOURCE_REPOSITORY,
        "source_commit": EXPECTED_COMMIT,
        "source_path": source_path,
        "source_blob": _source_blob(source_root, source_path),
        "destination_path": destination_path.replace("\\", "/"),
        "destination_sha256": _sha256(destination),
        "license": "AGPL-3.0-only",
        "imported_at": date.today().isoformat(),
        "relationship": relationship,
        "locally_modified": False,
    }


def import_baseline(source_root: Path, destination_root: Path) -> None:
    source_root = source_root.resolve()
    destination_root = destination_root.resolve()
    commit = _git(source_root, "rev-parse", "HEAD")
    if commit != EXPECTED_COMMIT:
        raise RuntimeError(f"expected KinematicSim {EXPECTED_COMMIT}, found {commit}")
    if _git(source_root, "status", "--porcelain"):
        raise RuntimeError("KinematicSim source checkout must be clean")

    source_urdf = source_root / "docs/urdf/kinematic_excavator.urdf"
    asset_pairs = (
        (source_urdf, destination_root / "assets/model/kinematic_excavator.urdf"),
        (
            source_root / "config/m1_provisional_calibration.json",
            destination_root / "assets/calibration/m1_provisional_calibration.json",
        ),
        (source_root / "LICENSE", destination_root / "assets/licenses/KinematicSim-AGPL-3.0.txt"),
    )
    for source, destination in asset_pairs:
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)

    sys.path.insert(0, str(source_root))
    try:
        import pinocchio as pin  # type: ignore[import-untyped]
        from kinematic_sim.model import ExcavatorModel  # type: ignore[import-not-found]

        model = ExcavatorModel.from_urdf(source_urdf)
        visual_origins = _visual_origins(source_urdf)
        poses = {
            "zero": (0.0, 0.0, 0.0, 0.0),
            "swing_positive_90": (math.pi / 2.0, 0.0, 0.0, 0.0),
            "asymmetric": (0.4, 0.2, -0.3, 0.35),
        }
        fixture_poses: dict[str, Any] = {}
        for name, angles in poses.items():
            transforms = model.frame_transforms(angles)
            visual_transforms = {
                link_name: _matrix_rows(np.asarray(transforms[link_name]) @ visual_origin)
                for link_name, visual_origin in visual_origins.items()
                if link_name in transforms
            }
            fixture_poses[name] = {
                "joint_angles": list(angles),
                "frame_transforms": {
                    frame_name: _matrix_rows(transform)
                    for frame_name, transform in transforms.items()
                },
                "visual_transforms": visual_transforms,
            }

        fixture = {
            "source_repository": SOURCE_REPOSITORY,
            "source_commit": EXPECTED_COMMIT,
            "source_model_blob": _source_blob(source_root, "kinematic_sim/model.py"),
            "source_urdf_blob": _source_blob(
                source_root, "docs/urdf/kinematic_excavator.urdf"
            ),
            "source_pixi_lock_sha256": _sha256(source_root / "pixi.lock"),
            "pinocchio_version": pin.__version__,
            "matrix_semantics": "row arrays encoding right-handed T_world_frame",
            "visual_composition": "T_world_visual = T_world_link * T_link_visual",
            "poses": fixture_poses,
        }
    finally:
        sys.path.remove(str(source_root))

    fixture_path = destination_root / "tests/fixtures/frame-parity/baseline.json"
    fixture_path.parent.mkdir(parents=True, exist_ok=True)
    fixture_path.write_text(json.dumps(fixture, indent=2) + "\n", encoding="utf-8")

    entries = [
        _provenance_entry(
            source_root,
            "docs/urdf/kinematic_excavator.urdf",
            "assets/model/kinematic_excavator.urdf",
            destination_root,
            relationship="verbatim-generated-asset",
        ),
        _provenance_entry(
            source_root,
            "config/m1_provisional_calibration.json",
            "assets/calibration/m1_provisional_calibration.json",
            destination_root,
            relationship="verbatim-configuration",
        ),
        _provenance_entry(
            source_root,
            "LICENSE",
            "assets/licenses/KinematicSim-AGPL-3.0.txt",
            destination_root,
            relationship="verbatim-license",
        ),
        {
            **_provenance_entry(
                source_root,
                "kinematic_sim/model.py",
                "tests/fixtures/frame-parity/baseline.json",
                destination_root,
                relationship="generated-reference-fixture",
            ),
            "generated_from": [
                "kinematic_sim/model.py",
                "docs/urdf/kinematic_excavator.urdf",
                "pixi.lock",
            ],
        },
    ]
    existing_path = destination_root / "assets/provenance.json"
    existing: dict[str, Any] = {}
    if existing_path.is_file():
        existing = json.loads(existing_path.read_text(encoding="utf-8"))
    provenance = {
        "schema_version": 1,
        "source_baseline": {
            "repository": SOURCE_REPOSITORY,
            "commit": EXPECTED_COMMIT,
        },
        "entries": entries,
        "conceptual_derivations": existing.get("conceptual_derivations", []),
        "manual_review": existing.get(
            "manual_review",
            {
                "required": True,
                "completed": False,
                "notes": "Complete after all adapted source modules are registered.",
            },
        ),
        "external_distribution_review": existing.get(
            "external_distribution_review",
            {
                "required_before_external_distribution": True,
                "completed": False,
                "items": {
                    "source_offer": False,
                    "ui_notice": False,
                    "machine_calibration_rights": False,
                    "asset_rights": False,
                },
            },
        ),
    }
    provenance_path = destination_root / "assets/provenance.json"
    provenance_path.write_text(json.dumps(provenance, indent=2) + "\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--destination-root", type=Path, default=Path(__file__).parents[2])
    args = parser.parse_args()
    import_baseline(args.source_root, args.destination_root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
