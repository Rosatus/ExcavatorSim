"""Validated operator-semantic to joint-coordinate command calibration."""

from __future__ import annotations

import json
from collections.abc import Mapping
from dataclasses import dataclass
from pathlib import Path
from types import MappingProxyType
from typing import Any, cast

from jsonschema import Draft202012Validator  # type: ignore[import-untyped]

from .paths import EQUIPMENT_COMMAND_PROFILE_PATH, EQUIPMENT_COMMAND_PROFILE_SCHEMA_PATH

AXIS_ORDER = ("swing", "boom", "arm", "bucket")
POSITIVE_SEMANTICS = ("right_rotation", "boom_raise", "arm_extend", "bucket_curl")
NEGATIVE_SEMANTICS = ("left_rotation", "boom_lower", "arm_retract", "bucket_dump")
SUPPORTED_MODEL_IDS = ("sy205", "sy135")


class EquipmentCommandProfileError(ValueError):
    pass


@dataclass(frozen=True)
class EquipmentCommandProfile:
    signs_by_model: Mapping[str, tuple[float, float, float, float]]

    def signs_for(self, model_id: str) -> tuple[float, float, float, float]:
        signs = self.signs_by_model.get(model_id)
        if signs is None:
            raise EquipmentCommandProfileError(f"unknown equipment command model: {model_id!r}")
        return signs


def _load_object(path: Path, label: str) -> dict[str, Any]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise EquipmentCommandProfileError(f"cannot load {label}") from exc
    if not isinstance(payload, dict):
        raise EquipmentCommandProfileError(f"{label} must be a JSON object")
    return cast(dict[str, Any], payload)


def load_equipment_command_profile(
    path: Path = EQUIPMENT_COMMAND_PROFILE_PATH,
    schema_path: Path = EQUIPMENT_COMMAND_PROFILE_SCHEMA_PATH,
) -> EquipmentCommandProfile:
    payload = _load_object(path, "equipment command profile")
    schema = _load_object(schema_path, "equipment command profile schema")
    errors = sorted(Draft202012Validator(schema).iter_errors(payload), key=lambda error: error.path)
    if errors:
        first = errors[0]
        location = ".".join(str(part) for part in first.absolute_path) or "root"
        raise EquipmentCommandProfileError(
            f"equipment command profile schema error at {location}: {first.message}"
        )
    raw_models = cast(dict[str, dict[str, Any]], payload["models"])
    signs_by_model = {
        model_id: cast(
            tuple[float, float, float, float],
            tuple(float(value) for value in raw_models[model_id]["semantic_to_joint_signs"]),
        )
        for model_id in SUPPORTED_MODEL_IDS
    }
    return EquipmentCommandProfile(signs_by_model=MappingProxyType(signs_by_model))
