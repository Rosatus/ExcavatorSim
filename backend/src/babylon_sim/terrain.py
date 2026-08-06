"""Strict deterministic terrain specifications and canonical heightfield generation."""

from __future__ import annotations

import hashlib
import json
import math
from collections.abc import Mapping
from dataclasses import dataclass
from functools import lru_cache
from itertools import pairwise
from typing import Any, cast

import numpy as np
from jsonschema import Draft202012Validator  # type: ignore[import-untyped]
from numpy.typing import NDArray

from .paths import TERRAIN_SPEC_SCHEMA_PATH

TERRAIN_SPEC_VERSION = "terrain-spec-v1"
TERRAIN_ALGORITHM_VERSION = "terrain-algorithm-v2"
MAX_TERRAIN_POINTS = 50_000
MAX_TERRAIN_BYTES = MAX_TERRAIN_POINTS * 4
_UINT32_MASK = (1 << 32) - 1


class TerrainSpecError(ValueError):
    """A strict schema, relationship, or resource-budget violation."""


@dataclass(frozen=True)
class GridDomain:
    width_m: float
    depth_m: float
    spacing_m: float
    columns: int
    rows: int
    origin_x_m: float
    origin_y_m: float

    @property
    def point_count(self) -> int:
        return self.columns * self.rows


@dataclass(frozen=True)
class TerrainBaseline:
    spec_json: str
    config_id: str
    algorithm_version: str
    domain: GridDomain
    heights: NDArray[np.float32]
    height_min_m: float
    height_max_m: float
    snapshot_sha256: str

    def spec(self) -> dict[str, Any]:
        return cast(dict[str, Any], json.loads(self.spec_json))

    def metadata(self) -> dict[str, object]:
        return {
            "terrain_config_id": self.config_id,
            "terrain_algorithm_version": self.algorithm_version,
            "rows": self.domain.rows,
            "columns": self.domain.columns,
            "origin_xy_m": [self.domain.origin_x_m, self.domain.origin_y_m],
            "spacing_m": self.domain.spacing_m,
            "height_min_m": self.height_min_m,
            "height_max_m": self.height_max_m,
            "snapshot_sha256": self.snapshot_sha256,
            "snapshot_bytes": self.domain.point_count * 4,
        }


def default_terrain_spec() -> dict[str, object]:
    return {
        "terrain_spec_version": TERRAIN_SPEC_VERSION,
        "kind": "flat",
        "width_m": 20.0,
        "depth_m": 20.0,
        "spacing_m": 0.25,
        "elevation_m": 0.0,
        "seed": 0,
        "noise_amplitude_m": 0.0,
        "noise_scale_m": 4.0,
    }


@lru_cache(maxsize=1)
def _terrain_validator() -> Draft202012Validator:
    payload = json.loads(TERRAIN_SPEC_SCHEMA_PATH.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise RuntimeError("terrain spec schema root must be an object")
    Draft202012Validator.check_schema(payload)
    return Draft202012Validator(payload)


def _reject_nonfinite(value: object) -> None:
    if isinstance(value, float) and not math.isfinite(value):
        raise TerrainSpecError("terrain spec numbers must be finite")
    if isinstance(value, list):
        for item in value:
            _reject_nonfinite(item)
    elif isinstance(value, dict):
        for item in value.values():
            _reject_nonfinite(item)


def _grid_domain(spec: Mapping[str, object]) -> GridDomain:
    width = float(cast(float | int, spec["width_m"]))
    depth = float(cast(float | int, spec["depth_m"]))
    spacing = float(cast(float | int, spec["spacing_m"]))
    width_steps = round(width / spacing)
    depth_steps = round(depth / spacing)
    if not math.isclose(width_steps * spacing, width, rel_tol=0.0, abs_tol=1e-9):
        raise TerrainSpecError("width_m must be an integer multiple of spacing_m")
    if not math.isclose(depth_steps * spacing, depth, rel_tol=0.0, abs_tol=1e-9):
        raise TerrainSpecError("depth_m must be an integer multiple of spacing_m")
    domain = GridDomain(
        width_m=width,
        depth_m=depth,
        spacing_m=spacing,
        columns=width_steps + 1,
        rows=depth_steps + 1,
        origin_x_m=-width / 2.0,
        origin_y_m=-depth / 2.0,
    )
    if domain.point_count > MAX_TERRAIN_POINTS:
        raise TerrainSpecError(
            f"terrain grid has {domain.point_count} points; maximum is {MAX_TERRAIN_POINTS}"
        )
    return domain


def _orientation(
    left: tuple[float, float], middle: tuple[float, float], right: tuple[float, float]
) -> float:
    return (middle[1] - left[1]) * (right[0] - middle[0]) - (middle[0] - left[0]) * (
        right[1] - middle[1]
    )


def _segments_cross(
    a: tuple[float, float],
    b: tuple[float, float],
    c: tuple[float, float],
    d: tuple[float, float],
) -> bool:
    first = _orientation(a, b, c)
    second = _orientation(a, b, d)
    third = _orientation(c, d, a)
    fourth = _orientation(c, d, b)
    return first * second < 0.0 and third * fourth < 0.0


def validate_terrain_spec(raw: object) -> tuple[dict[str, Any], GridDomain]:
    _reject_nonfinite(raw)
    errors = sorted(
        _terrain_validator().iter_errors(raw), key=lambda error: list(error.absolute_path)
    )
    if errors:
        path = ".".join(str(item) for item in errors[0].absolute_path)
        prefix = f"{path}: " if path else ""
        raise TerrainSpecError(f"{prefix}{errors[0].message}")
    spec = cast(dict[str, Any], json.loads(json.dumps(raw, allow_nan=False)))
    domain = _grid_domain(spec)
    if spec["kind"] == "trench":
        top_width = float(spec["top_width_m"])
        bottom_width = float(spec["bottom_width_m"])
        if bottom_width > top_width:
            raise TerrainSpecError("bottom_width_m must be <= top_width_m")
        if top_width > domain.depth_m:
            raise TerrainSpecError("top_width_m must fit inside depth_m")
    if spec["kind"] == "profile":
        alignment = [(float(point[0]), float(point[1])) for point in spec["alignment_xy_m"]]
        section = [(float(point[0]), float(point[1])) for point in spec["section_uv_m"]]
        for index in range(len(alignment) - 1):
            if math.dist(alignment[index], alignment[index + 1]) <= 1e-9:
                raise TerrainSpecError("alignment_xy_m contains a zero-length segment")
        for first in range(len(alignment) - 1):
            for second in range(first + 2, len(alignment) - 1):
                if _segments_cross(
                    alignment[first],
                    alignment[first + 1],
                    alignment[second],
                    alignment[second + 1],
                ):
                    raise TerrainSpecError("alignment_xy_m must not self-intersect")
        section_u = [point[0] for point in section]
        if any(right <= left for left, right in pairwise(section_u)):
            raise TerrainSpecError("section_uv_m offsets must be strictly increasing")
        if section_u[0] >= 0.0 or section_u[-1] <= 0.0:
            raise TerrainSpecError("section_uv_m must span both sides of the alignment")
        if len(alignment) * len(section) > MAX_TERRAIN_POINTS:
            raise TerrainSpecError("profile alignment/section product exceeds the point budget")
    return spec, domain


def _hash_unit(x_index: int, y_index: int, seed: int) -> float:
    value = (
        (x_index & _UINT32_MASK) * 0x9E3779B1
        + (y_index & _UINT32_MASK) * 0x85EBCA77
        + seed * 0xC2B2AE3D
    ) & _UINT32_MASK
    value ^= value >> 16
    value = (value * 0x7FEB352D) & _UINT32_MASK
    value ^= value >> 15
    value = (value * 0x846CA68B) & _UINT32_MASK
    value ^= value >> 16
    return value / _UINT32_MASK * 2.0 - 1.0


def _smoothstep(value: float) -> float:
    return value * value * (3.0 - 2.0 * value)


def _value_noise(x: float, y: float, seed: int, scale: float) -> float:
    scaled_x = x / scale
    scaled_y = y / scale
    x0 = math.floor(scaled_x)
    y0 = math.floor(scaled_y)
    tx = _smoothstep(scaled_x - x0)
    ty = _smoothstep(scaled_y - y0)
    bottom = _hash_unit(x0, y0, seed) * (1.0 - tx) + _hash_unit(x0 + 1, y0, seed) * tx
    top = _hash_unit(x0, y0 + 1, seed) * (1.0 - tx) + _hash_unit(x0 + 1, y0 + 1, seed) * tx
    return bottom * (1.0 - ty) + top * ty


def _section_height(section: list[tuple[float, float]], offset: float) -> float | None:
    if offset < section[0][0] or offset > section[-1][0]:
        return None
    for left, right in pairwise(section):
        if offset <= right[0]:
            ratio = (offset - left[0]) / (right[0] - left[0])
            return left[1] + ratio * (right[1] - left[1])
    return section[-1][1]


def _profile_height(spec: Mapping[str, Any], x: float, y: float) -> float:
    alignment = [(float(point[0]), float(point[1])) for point in spec["alignment_xy_m"]]
    section = [(float(point[0]), float(point[1])) for point in spec["section_uv_m"]]
    best_distance = math.inf
    best_offset = 0.0
    for start, end in pairwise(alignment):
        dx = end[0] - start[0]
        dy = end[1] - start[1]
        length_squared = dx * dx + dy * dy
        ratio = min(1.0, max(0.0, ((x - start[0]) * dx + (y - start[1]) * dy) / length_squared))
        nearest_x = start[0] + ratio * dx
        nearest_y = start[1] + ratio * dy
        distance = math.hypot(x - nearest_x, y - nearest_y)
        if distance < best_distance:
            segment_length = math.sqrt(length_squared)
            best_distance = distance
            best_offset = (x - nearest_x) * (-dy / segment_length) + (y - nearest_y) * (
                dx / segment_length
            )
    profile = _section_height(section, best_offset)
    if profile is None:
        return float(spec["outside_elevation_m"])
    return float(spec["elevation_m"]) + profile


def generate_terrain(raw: object) -> TerrainBaseline:
    spec, domain = validate_terrain_spec(raw)
    heights = np.empty((domain.rows, domain.columns), dtype="<f4")
    kind = cast(str, spec["kind"])
    elevation = float(spec["elevation_m"])
    amplitude = float(spec["noise_amplitude_m"])
    noise_scale = float(spec["noise_scale_m"])
    seed = int(spec["seed"])
    slope = math.tan(math.radians(float(spec.get("angle_deg", 0.0))))
    direction = cast(str, spec.get("direction", "north"))
    trench_center = domain.origin_y_m + float(spec.get("position", 0.5)) * domain.depth_m
    top_half = float(spec.get("top_width_m", 0.0)) / 2.0
    bottom_half = float(spec.get("bottom_width_m", 0.0)) / 2.0
    wall_steepness = float(spec.get("wall_steepness", 0.0))
    trench_depth = float(spec.get("trench_depth_m", 0.0))

    for row in range(domain.rows):
        y = domain.origin_y_m + row * domain.spacing_m
        for column in range(domain.columns):
            x = domain.origin_x_m + column * domain.spacing_m
            height = elevation
            if kind == "slope":
                axis = y if direction in {"north", "south"} else x
                sign = 1.0 if direction in {"north", "east"} else -1.0
                height += sign * axis * slope
            elif kind == "trench":
                distance = abs(y - trench_center)
                if distance <= bottom_half:
                    factor = 1.0
                elif distance >= top_half or math.isclose(top_half, bottom_half):
                    factor = 0.0
                else:
                    transition = 1.0 - (distance - bottom_half) / (top_half - bottom_half)
                    exponent = 1.0 / max(0.05, 1.0 - wall_steepness * 0.95)
                    factor = transition**exponent
                height -= factor * trench_depth
            elif kind == "profile":
                height = _profile_height(spec, x, y)
            if amplitude > 0.0:
                height += amplitude * _value_noise(x, y, seed, noise_scale)
            heights[row, column] = height

    if not np.isfinite(heights).all():
        raise TerrainSpecError("terrain generation produced a non-finite height")
    snapshot = heights.tobytes(order="C")
    if len(snapshot) > MAX_TERRAIN_BYTES:
        raise TerrainSpecError("terrain snapshot exceeds the byte budget")
    spec_json = json.dumps(spec, sort_keys=True, separators=(",", ":"), allow_nan=False)
    config_id = hashlib.sha256(spec_json.encode("utf-8")).hexdigest()
    heights.flags.writeable = False
    return TerrainBaseline(
        spec_json=spec_json,
        config_id=config_id,
        algorithm_version=TERRAIN_ALGORITHM_VERSION,
        domain=domain,
        heights=heights,
        height_min_m=float(np.min(heights)),
        height_max_m=float(np.max(heights)),
        snapshot_sha256=hashlib.sha256(snapshot).hexdigest(),
    )


def terrain_snapshot_bytes(baseline: TerrainBaseline) -> bytes:
    return baseline.heights.tobytes(order="C")
