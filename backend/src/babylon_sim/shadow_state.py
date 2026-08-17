"""Strict, observational-only storage for Godot/Jolt shadow truth."""

from __future__ import annotations

import json
import math
from dataclasses import dataclass
from functools import lru_cache
from typing import Any, cast

from jsonschema import Draft202012Validator  # type: ignore[import-untyped]

from .paths import SIMULATION_AUTHORITY_MANIFEST_PATH, SIMULATION_TRUTH_SCHEMA_PATH
from .protocol import ProtocolError

SHADOW_TRUTH_CAPABILITY = "simulation_truth_shadow_v1"
SHADOW_TRUTH_TIMEOUT_SECONDS = 0.5


@dataclass(frozen=True)
class ShadowTruthIdentity:
    session_id: str
    simulation_epoch: str
    model_id: str
    model_version: str
    rig_id: str
    rig_version: str
    calibration_version: str


@dataclass(frozen=True)
class ShadowTruthSample:
    canonical_json: str
    identity: ShadowTruthIdentity
    authority_epoch: str
    sequence: int
    physics_tick: int
    monotonic_time_ns: int
    terrain_epoch: str
    terrain_revision: int
    world_generation: int

    def as_dict(self) -> dict[str, Any]:
        return cast(dict[str, Any], json.loads(self.canonical_json))


@dataclass(frozen=True)
class LatestShadowTruth:
    sample: ShadowTruthSample
    received_monotonic_s: float

    def as_dict(self, now: float) -> dict[str, object]:
        return {
            "snapshot": self.sample.as_dict(),
            "received_monotonic_ms": self.received_monotonic_s * 1000.0,
            "age_ms": max(0.0, now - self.received_monotonic_s) * 1000.0,
        }


@lru_cache(maxsize=1)
def load_authority_manifest() -> dict[str, Any]:
    payload = json.loads(SIMULATION_AUTHORITY_MANIFEST_PATH.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError("simulation authority manifest root must be an object")
    required = {
        "schema_version",
        "truth_schema_version",
        "rig_schema_version",
        "coordinate_basis",
        "profiles",
        "models",
    }
    if set(payload) != required:
        raise RuntimeError("simulation authority manifest fields do not match the contract")
    return cast(dict[str, Any], payload)


@lru_cache(maxsize=1)
def shadow_truth_validator() -> Draft202012Validator:
    schema = json.loads(SIMULATION_TRUTH_SCHEMA_PATH.read_text(encoding="utf-8"))
    if not isinstance(schema, dict):
        raise RuntimeError("simulation truth schema root must be an object")
    Draft202012Validator.check_schema(schema)
    return Draft202012Validator(schema)


def decode_shadow_truth(
    snapshot: dict[str, Any], expected: ShadowTruthIdentity
) -> ShadowTruthSample:
    errors = sorted(
        shadow_truth_validator().iter_errors(snapshot),
        key=lambda error: list(error.absolute_path),
    )
    if errors:
        raise ProtocolError("shadow_schema_validation_failed", errors[0].message)
    identity = cast(dict[str, Any], snapshot["identity"])
    actual = ShadowTruthIdentity(
        session_id=identity["session_id"],
        simulation_epoch=identity["simulation_epoch"],
        model_id=identity["model_id"],
        model_version=identity["model_version"],
        rig_id=identity["rig_id"],
        rig_version=identity["rig_version"],
        calibration_version=identity["calibration_version"],
    )
    if actual != expected:
        raise ProtocolError("shadow_identity_mismatch", "shadow truth identity is not current")
    model_contract = cast(dict[str, Any], load_authority_manifest()["models"])[actual.model_id]
    for field in ("model_version", "rig_id", "rig_version", "calibration_version"):
        if getattr(actual, field) != model_contract[field]:
            raise ProtocolError(
                "shadow_identity_mismatch",
                f"shadow truth {field} does not match its model contract",
            )
    for body in cast(list[dict[str, Any]], snapshot["bodies"]):
        _validate_rigid_transform(cast(list[list[float]], body["transform"]))
    canonical = json.dumps(snapshot, sort_keys=True, separators=(",", ":"), allow_nan=False)
    return ShadowTruthSample(
        canonical_json=canonical,
        identity=actual,
        authority_epoch=snapshot["authority_epoch"],
        sequence=snapshot["sequence"],
        physics_tick=snapshot["physics_tick"],
        monotonic_time_ns=snapshot["monotonic_time_ns"],
        terrain_epoch=identity["terrain_epoch"],
        terrain_revision=identity["terrain_revision"],
        world_generation=identity["world_generation"],
    )


def validate_shadow_order(previous: ShadowTruthSample, current: ShadowTruthSample) -> None:
    if previous.identity.simulation_epoch != current.identity.simulation_epoch:
        return
    if previous.authority_epoch != current.authority_epoch:
        raise ProtocolError(
            "stale_shadow_epoch", "shadow authority epoch changed within a simulation epoch"
        )
    if current.sequence <= previous.sequence or current.physics_tick <= previous.physics_tick:
        raise ProtocolError("stale_shadow_tick", "shadow sequence and physics tick must increase")
    if current.monotonic_time_ns < previous.monotonic_time_ns:
        raise ProtocolError("stale_shadow_clock", "shadow monotonic clock moved backwards")
    if current.world_generation < previous.world_generation:
        raise ProtocolError(
            "stale_shadow_terrain", "shadow terrain world generation moved backwards"
        )
    if current.world_generation == previous.world_generation and (
        current.terrain_epoch != previous.terrain_epoch
        or current.terrain_revision < previous.terrain_revision
    ):
        raise ProtocolError(
            "stale_shadow_terrain",
            "shadow terrain identity changed or revision moved backwards within a world generation",
        )


def _validate_rigid_transform(rows: list[list[float]]) -> None:
    if any(
        abs(float(rows[3][index]) - expected) > 1e-6 for index, expected in enumerate((0, 0, 0, 1))
    ):
        raise ProtocolError("invalid_shadow_transform", "shadow transform bottom row is invalid")
    columns = [[float(rows[row][column]) for row in range(3)] for column in range(3)]
    for column in columns:
        if abs(sum(value * value for value in column) - 1.0) > 1e-4:
            raise ProtocolError(
                "invalid_shadow_transform", "shadow transform basis is not normalized"
            )
    for left, right in ((0, 1), (0, 2), (1, 2)):
        if abs(sum(columns[left][i] * columns[right][i] for i in range(3))) > 1e-4:
            raise ProtocolError(
                "invalid_shadow_transform", "shadow transform basis is not orthogonal"
            )
    a, b, c = columns
    determinant = (
        a[0] * (b[1] * c[2] - b[2] * c[1])
        - b[0] * (a[1] * c[2] - a[2] * c[1])
        + c[0] * (a[1] * b[2] - a[2] * b[1])
    )
    if not math.isclose(determinant, 1.0, rel_tol=0.0, abs_tol=1e-4):
        raise ProtocolError("invalid_shadow_transform", "shadow transform must be right handed")
