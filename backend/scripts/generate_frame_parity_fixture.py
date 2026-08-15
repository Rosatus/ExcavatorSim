"""Generate deterministic named-frame parity fixtures from a reviewed URDF."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
from pathlib import Path
from typing import Any

import pinocchio as pin  # type: ignore[import-untyped]

from babylon_sim.model import ExcavatorModel

ROOT = Path(__file__).parents[2]
GENERATOR_PATH = Path("backend/scripts/generate_frame_parity_fixture.py")
MODEL_PATH = Path("backend/src/babylon_sim/model.py")
LOCK_PATH = Path("pixi.lock")
PRESENTATION_FRAME_NAMES = (
    "base_link",
    "upper_structure_link",
    "boom_link",
    "arm_link",
    "bucket_link",
)
POSES = {
    "zero": (0.0, 0.0, 0.0, 0.0),
    "swing_positive_90": (math.pi / 2.0, 0.0, 0.0, 0.0),
    "boom_only": (0.0, 0.2, 0.0, 0.0),
    "arm_only": (0.0, 0.0, -0.3, 0.0),
    "bucket_only": (0.0, 0.0, 0.0, 0.35),
    "asymmetric": (0.4, 0.2, -0.3, 0.35),
}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _repository_path(value: Path, *, must_exist: bool) -> tuple[Path, str]:
    candidate = value if value.is_absolute() else ROOT / value
    resolved = candidate.resolve()
    try:
        relative = resolved.relative_to(ROOT).as_posix()
    except ValueError as exc:
        raise ValueError(f"path must remain inside the repository: {value}") from exc
    if must_exist and not resolved.is_file():
        raise ValueError(f"file does not exist: {relative}")
    return resolved, relative


def build_fixture(*, model_id: str, model_version: str, urdf_path: Path) -> dict[str, Any]:
    model = ExcavatorModel.from_urdf(urdf_path)
    fixture_poses: dict[str, Any] = {}
    for pose_name, angles in POSES.items():
        transforms = model.frame_transforms(angles)
        fixture_poses[pose_name] = {
            "joint_angles": list(angles),
            "frame_transforms": {
                frame_name: transforms[frame_name] for frame_name in PRESENTATION_FRAME_NAMES
            },
        }
    _, urdf_relative = _repository_path(urdf_path, must_exist=True)
    return {
        "schema_version": "articulated-frame-parity-v1",
        "model_id": model_id,
        "model_version": model_version,
        "source_urdf_path": urdf_relative,
        "source_urdf_sha256": _sha256(urdf_path),
        "source_model_path": MODEL_PATH.as_posix(),
        "source_model_sha256": _sha256(ROOT / MODEL_PATH),
        "source_pixi_lock_sha256": _sha256(ROOT / LOCK_PATH),
        "generator_path": GENERATOR_PATH.as_posix(),
        "generator_sha256": _sha256(ROOT / GENERATOR_PATH),
        "pinocchio_version": pin.__version__,
        "matrix_semantics": "row arrays encoding right-handed T_world_frame",
        "poses": fixture_poses,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model-id", required=True)
    parser.add_argument("--model-version", required=True)
    parser.add_argument("--urdf", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    urdf_path, _ = _repository_path(args.urdf, must_exist=True)
    output_path, output_relative = _repository_path(args.output, must_exist=False)
    rendered = (
        json.dumps(
            build_fixture(
                model_id=args.model_id,
                model_version=args.model_version,
                urdf_path=urdf_path,
            ),
            indent=2,
        )
        + "\n"
    )
    if args.check:
        if not output_path.is_file() or output_path.read_text(encoding="utf-8") != rendered:
            raise SystemExit(f"generated fixture is stale: {output_relative}")
        print(f"Frame parity fixture is current: {output_relative}")
        return 0

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(rendered, encoding="utf-8")
    print(f"Generated frame parity fixture: {output_relative}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
