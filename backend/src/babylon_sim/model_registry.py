"""Validated model descriptors shared by runtime construction and transport identity."""

from __future__ import annotations

import hashlib
import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any, Literal, cast

from jsonschema import Draft202012Validator  # type: ignore[import-untyped]

from .paths import MODEL_REGISTRY_PATH, MODEL_REGISTRY_SCHEMA_PATH, PROJECT_ROOT

ContactMode = Literal["frame_offset", "node"]
PassiveLinkageMode = Literal["godot_visual_four_bar", "none"]


class ModelRegistryError(ValueError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class ExcavationContact:
    mode: ContactMode
    frame: str
    offset_godot: tuple[float, float, float] | None
    node_path: str | None


@dataclass(frozen=True)
class ModelDescriptor:
    model_id: str
    display_name: str
    model_version: str
    visual_model_version: str
    urdf_path: Path
    calibration_path: Path
    calibration_version: str
    godot_glb_path: Path
    godot_glb_resource: str
    visual_manifest_path: Path
    visual_manifest_resource: str
    parity_fixture_path: Path
    parity_fixture_resource: str
    passive_linkage_mode: PassiveLinkageMode
    excavation_contact: ExcavationContact


@dataclass(frozen=True)
class ModelRegistry:
    default_model_id: str
    models: Mapping[str, ModelDescriptor]

    def resolve(self, model_id: str | None = None) -> ModelDescriptor:
        selected = self.default_model_id if model_id is None else model_id
        descriptor = self.models.get(selected)
        if descriptor is None:
            raise ModelRegistryError("unknown_model", f"unknown excavator model: {selected!r}")
        return descriptor

    @property
    def model_ids(self) -> tuple[str, ...]:
        return tuple(self.models)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _repository_file(raw_path: str, expected_hash: str, *, label: str) -> Path:
    relative = Path(raw_path)
    if relative.is_absolute() or ".." in relative.parts or "\\" in raw_path:
        raise ModelRegistryError(
            "model_contract_mismatch", f"{label} must be a repository-relative POSIX path"
        )
    resolved = (PROJECT_ROOT / relative).resolve()
    try:
        resolved.relative_to(PROJECT_ROOT)
    except ValueError as exc:
        raise ModelRegistryError(
            "model_contract_mismatch", f"{label} escapes the repository"
        ) from exc
    if not resolved.is_file():
        raise ModelRegistryError("model_unavailable", f"{label} is unavailable")
    if _sha256(resolved) != expected_hash:
        raise ModelRegistryError("model_contract_mismatch", f"{label} SHA-256 mismatch")
    return resolved


def _load_json(path: Path, *, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ModelRegistryError("model_contract_mismatch", f"cannot load {label}") from exc
    if not isinstance(value, dict):
        raise ModelRegistryError("model_contract_mismatch", f"{label} must be a JSON object")
    return cast(dict[str, Any], value)


def _contact(payload: dict[str, Any]) -> ExcavationContact:
    mode = cast(ContactMode, payload["mode"])
    raw_offset = payload.get("offset_godot")
    offset = (
        cast(tuple[float, float, float], tuple(float(value) for value in raw_offset))
        if isinstance(raw_offset, list)
        else None
    )
    raw_node_path = payload.get("node_path")
    return ExcavationContact(
        mode=mode,
        frame=str(payload["frame"]),
        offset_godot=offset,
        node_path=str(raw_node_path) if raw_node_path is not None else None,
    )


def _descriptor(payload: dict[str, Any]) -> ModelDescriptor:
    model_id = str(payload["model_id"])
    prefix = f"model {model_id}"
    return ModelDescriptor(
        model_id=model_id,
        display_name=str(payload["display_name"]),
        model_version=str(payload["model_version"]),
        visual_model_version=str(payload["visual_model_version"]),
        urdf_path=_repository_file(
            str(payload["urdf_path"]), str(payload["urdf_sha256"]), label=f"{prefix} URDF"
        ),
        calibration_path=_repository_file(
            str(payload["calibration_path"]),
            str(payload["calibration_sha256"]),
            label=f"{prefix} calibration",
        ),
        calibration_version=str(payload["calibration_version"]),
        godot_glb_path=_repository_file(
            str(payload["godot_glb_path"]),
            str(payload["godot_glb_sha256"]),
            label=f"{prefix} GLB",
        ),
        godot_glb_resource=str(payload["godot_glb_resource"]),
        visual_manifest_path=_repository_file(
            str(payload["visual_manifest_path"]),
            str(payload["visual_manifest_sha256"]),
            label=f"{prefix} visual manifest",
        ),
        visual_manifest_resource=str(payload["visual_manifest_resource"]),
        parity_fixture_path=_repository_file(
            str(payload["parity_fixture_path"]),
            str(payload["parity_fixture_sha256"]),
            label=f"{prefix} parity fixture",
        ),
        parity_fixture_resource=str(payload["parity_fixture_resource"]),
        passive_linkage_mode=cast(PassiveLinkageMode, payload["passive_linkage_mode"]),
        excavation_contact=_contact(cast(dict[str, Any], payload["excavation_contact"])),
    )


def load_model_registry(
    path: Path = MODEL_REGISTRY_PATH,
    schema_path: Path = MODEL_REGISTRY_SCHEMA_PATH,
) -> ModelRegistry:
    payload = _load_json(path, label="model registry")
    schema = _load_json(schema_path, label="model registry schema")
    errors = sorted(Draft202012Validator(schema).iter_errors(payload), key=lambda error: error.path)
    if errors:
        first = errors[0]
        location = ".".join(str(part) for part in first.absolute_path) or "root"
        raise ModelRegistryError(
            "model_contract_mismatch", f"model registry schema error at {location}: {first.message}"
        )
    descriptors: dict[str, ModelDescriptor] = {}
    for raw_descriptor in cast(list[dict[str, Any]], payload["models"]):
        descriptor = _descriptor(raw_descriptor)
        if descriptor.model_id in descriptors:
            raise ModelRegistryError(
                "model_contract_mismatch", f"duplicate model ID: {descriptor.model_id}"
            )
        descriptors[descriptor.model_id] = descriptor
    default_model_id = str(payload["default_model_id"])
    if default_model_id not in descriptors:
        raise ModelRegistryError(
            "model_contract_mismatch", "default model ID is not present in the registry"
        )
    return ModelRegistry(
        default_model_id=default_model_id,
        models=MappingProxyType(descriptors),
    )
