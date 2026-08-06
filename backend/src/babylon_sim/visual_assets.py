"""Strict visual-model manifest validation and allowlisted asset lookup."""

from __future__ import annotations

import hashlib
import json
import math
import struct
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from typing import Any

from jsonschema import Draft202012Validator  # type: ignore[import-untyped]

from .paths import VISUAL_ASSETS_ROOT, VISUAL_MODEL_MANIFEST_PATH, VISUAL_MODEL_SCHEMA_PATH

VISUAL_MODEL_SCHEMA_VERSION = "visual-model-v1"
VISUAL_MODEL_VERSION = "original-skin-v1"
VISUAL_FRAME_NAMES = frozenset(
    {"base_link", "upper_structure_link", "boom_link", "arm_link", "bucket_link"}
)
MAX_VISUAL_ASSET_BYTES = 16 * 1024 * 1024


class VisualAssetError(ValueError):
    """Raised when a committed visual asset violates the runtime contract."""


Vec3 = tuple[float, float, float]


@dataclass(frozen=True)
class VisualBounds:
    minimum: Vec3
    maximum: Vec3

    def as_dict(self) -> dict[str, list[float]]:
        return {"min": list(self.minimum), "max": list(self.maximum)}


@dataclass(frozen=True)
class VisualAssetEntry:
    asset_id: str
    filename: str
    sha256: str
    authoritative_frame: str
    translation_m: Vec3
    rpy_rad: Vec3
    scale: Vec3
    expected_bounds_m: VisualBounds
    replace_primitive_visual: bool

    def as_public_dict(self) -> dict[str, object]:
        return {
            "asset_id": self.asset_id,
            "url": f"/api/visual-assets/{self.asset_id}",
            "sha256": self.sha256,
            "authoritative_frame": self.authoritative_frame,
            "translation_m": list(self.translation_m),
            "rpy_rad": list(self.rpy_rad),
            "scale": list(self.scale),
            "expected_bounds_m": self.expected_bounds_m.as_dict(),
            "replace_primitive_visual": self.replace_primitive_visual,
        }


@dataclass(frozen=True)
class VisualModelManifest:
    schema_version: str
    visual_model_version: str
    source_model: str
    entries: tuple[VisualAssetEntry, ...]
    assets_root: Path

    def as_public_dict(self) -> dict[str, object]:
        return {
            "schema_version": self.schema_version,
            "visual_model_version": self.visual_model_version,
            "source_model": self.source_model,
            "entries": [entry.as_public_dict() for entry in self.entries],
        }

    def asset(self, asset_id: str) -> tuple[VisualAssetEntry, Path] | None:
        for entry in self.entries:
            if entry.asset_id == asset_id:
                return entry, self.assets_root / entry.filename
        return None


def _load_json(path: Path, label: str) -> dict[str, Any]:
    def reject_constant(value: str) -> None:
        raise ValueError(f"non-finite JSON constant {value}")

    try:
        value = json.loads(path.read_text(encoding="utf-8"), parse_constant=reject_constant)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        raise VisualAssetError(f"cannot read {label}: {path}") from exc
    if not isinstance(value, dict):
        raise VisualAssetError(f"{label} root must be an object")
    return value


def _vec3(value: object, label: str) -> Vec3:
    if (
        not isinstance(value, list)
        or len(value) != 3
        or any(isinstance(item, bool) or not isinstance(item, (int, float)) for item in value)
    ):
        raise VisualAssetError(f"{label} must contain exactly three numbers")
    result = tuple(float(item) for item in value)
    if any(not math.isfinite(item) for item in result):
        raise VisualAssetError(f"{label} values must be finite")
    return result  # type: ignore[return-value]


def _validate_glb(path: Path, expected_sha256: str, expected_bounds: VisualBounds) -> None:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise VisualAssetError(f"visual asset is unavailable: {path}") from exc
    if len(data) > MAX_VISUAL_ASSET_BYTES:
        raise VisualAssetError(f"visual asset exceeds {MAX_VISUAL_ASSET_BYTES} bytes: {path}")
    if len(data) < 20 or data[:4] != b"glTF":
        raise VisualAssetError(f"visual asset is not a GLB file: {path}")
    _, version, total_length = struct.unpack_from("<4sII", data)
    if version != 2 or total_length != len(data):
        raise VisualAssetError(f"visual asset has an invalid GLB header: {path}")
    json_length, chunk_type = struct.unpack_from("<II", data, 12)
    if chunk_type != 0x4E4F534A or 20 + json_length > len(data):
        raise VisualAssetError(f"visual asset has no valid GLB JSON chunk: {path}")
    try:
        document = json.loads(data[20 : 20 + json_length].rstrip(b" \x00").decode("utf-8"))
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise VisualAssetError(f"visual asset has invalid GLB JSON: {path}") from exc
    asset = document.get("asset") if isinstance(document, dict) else None
    meshes = document.get("meshes") if isinstance(document, dict) else None
    materials = document.get("materials") if isinstance(document, dict) else None
    accessors = document.get("accessors") if isinstance(document, dict) else None
    if (
        not isinstance(asset, dict)
        or asset.get("version") != "2.0"
        or not isinstance(meshes, list)
        or not meshes
        or not isinstance(materials, list)
        or not materials
        or not isinstance(accessors, list)
    ):
        raise VisualAssetError(f"visual asset has no renderable mesh/material content: {path}")
    position_accessors: list[dict[str, Any]] = []
    for mesh in meshes:
        if not isinstance(mesh, dict) or not isinstance(mesh.get("primitives"), list):
            continue
        for primitive in mesh["primitives"]:
            if not isinstance(primitive, dict) or not isinstance(primitive.get("attributes"), dict):
                continue
            position_index = primitive["attributes"].get("POSITION")
            if (
                isinstance(position_index, int)
                and not isinstance(position_index, bool)
                and 0 <= position_index < len(accessors)
                and isinstance(accessors[position_index], dict)
            ):
                position_accessors.append(accessors[position_index])
    try:
        observed_minimum = tuple(
            min(float(accessor["min"][axis]) for accessor in position_accessors)
            for axis in range(3)
        )
        observed_maximum = tuple(
            max(float(accessor["max"][axis]) for accessor in position_accessors)
            for axis in range(3)
        )
    except (KeyError, IndexError, TypeError, ValueError) as exc:
        raise VisualAssetError(f"visual asset has invalid POSITION bounds: {path}") from exc
    for observed, expected in zip(
        (*observed_minimum, *observed_maximum),
        (*expected_bounds.minimum, *expected_bounds.maximum),
        strict=True,
    ):
        if not math.isclose(observed, expected, abs_tol=1e-5):
            raise VisualAssetError(f"visual asset bounds do not match its manifest: {path}")
    if hashlib.sha256(data).hexdigest() != expected_sha256:
        raise VisualAssetError(f"visual asset digest mismatch: {path}")


def load_visual_model_manifest(
    manifest_path: Path = VISUAL_MODEL_MANIFEST_PATH,
    *,
    assets_root: Path = VISUAL_ASSETS_ROOT,
    schema_path: Path = VISUAL_MODEL_SCHEMA_PATH,
) -> VisualModelManifest:
    """Load and verify the complete committed visual-model asset set."""

    manifest_path = manifest_path.resolve()
    assets_root = assets_root.resolve()
    schema = _load_json(schema_path.resolve(), "visual model schema")
    payload = _load_json(manifest_path, "visual model manifest")
    errors = sorted(
        Draft202012Validator(schema).iter_errors(payload), key=lambda item: list(item.path)
    )
    if errors:
        detail = "; ".join(error.message for error in errors[:5])
        raise VisualAssetError(f"visual model manifest schema validation failed: {detail}")
    if payload["schema_version"] != VISUAL_MODEL_SCHEMA_VERSION:
        raise VisualAssetError("unsupported visual model schema version")
    if payload["visual_model_version"] != VISUAL_MODEL_VERSION:
        raise VisualAssetError("unsupported visual model version")

    entries: list[VisualAssetEntry] = []
    asset_ids: set[str] = set()
    filenames: set[str] = set()
    frames: set[str] = set()
    for index, raw_entry in enumerate(payload["entries"]):
        asset_id = raw_entry["asset_id"]
        filename = raw_entry["file"]
        frame = raw_entry["authoritative_frame"]
        if asset_id in asset_ids or filename in filenames or frame in frames:
            raise VisualAssetError("visual model entries must have unique ids, files, and frames")
        asset_ids.add(asset_id)
        filenames.add(filename)
        frames.add(frame)
        relative = PurePosixPath(filename)
        if relative.is_absolute() or len(relative.parts) != 1 or relative.suffix != ".glb":
            raise VisualAssetError(f"entries[{index}].file is not an allowlisted GLB filename")
        asset_path = (assets_root / filename).resolve()
        try:
            asset_path.relative_to(assets_root)
        except ValueError as exc:
            raise VisualAssetError(f"entries[{index}].file escapes the visual asset root") from exc
        translation = _vec3(raw_entry["translation_m"], f"entries[{index}].translation_m")
        rpy = _vec3(raw_entry["rpy_rad"], f"entries[{index}].rpy_rad")
        scale = _vec3(raw_entry["scale"], f"entries[{index}].scale")
        if any(value <= 0.0 for value in scale):
            raise VisualAssetError(f"entries[{index}].scale values must be positive")
        minimum = _vec3(
            raw_entry["expected_bounds_m"]["min"], f"entries[{index}].expected_bounds_m.min"
        )
        maximum = _vec3(
            raw_entry["expected_bounds_m"]["max"], f"entries[{index}].expected_bounds_m.max"
        )
        if any(low >= high for low, high in zip(minimum, maximum, strict=True)):
            raise VisualAssetError(f"entries[{index}].expected_bounds_m is inverted or empty")
        expected_bounds = VisualBounds(minimum=minimum, maximum=maximum)
        _validate_glb(asset_path, raw_entry["sha256"], expected_bounds)
        entries.append(
            VisualAssetEntry(
                asset_id=asset_id,
                filename=filename,
                sha256=raw_entry["sha256"],
                authoritative_frame=frame,
                translation_m=translation,
                rpy_rad=rpy,
                scale=scale,
                expected_bounds_m=expected_bounds,
                replace_primitive_visual=raw_entry["replace_primitive_visual"],
            )
        )
    if frames != VISUAL_FRAME_NAMES:
        missing = sorted(VISUAL_FRAME_NAMES - frames)
        unexpected = sorted(frames - VISUAL_FRAME_NAMES)
        raise VisualAssetError(
            f"visual model frame set is incompatible (missing={missing}, unexpected={unexpected})"
        )
    return VisualModelManifest(
        schema_version=payload["schema_version"],
        visual_model_version=payload["visual_model_version"],
        source_model=payload["source_model"],
        entries=tuple(entries),
        assets_root=assets_root,
    )
