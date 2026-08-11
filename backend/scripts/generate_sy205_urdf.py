"""Generate the deterministic GLB-derived SY205 candidate URDF and evidence manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import shutil
import struct
import sys
import tempfile
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from itertools import pairwise
from pathlib import Path
from typing import Any, NoReturn, cast

import numpy as np
from numpy.typing import NDArray

from babylon_sim.constants import ACTIVE_JOINT_NAMES, REQUIRED_FRAME_NAMES
from babylon_sim.model import ExcavatorModel, ModelValidationError

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_GLB_PATH = ROOT / "godot/client/assets/visual/SY205_excavator_godot.glb"
DEFAULT_VISUAL_MANIFEST_PATH = ROOT / "godot/client/resources/visual/sy205_visual_manifest.json"
DEFAULT_PARAMETERS_PATH = ROOT / "assets/model/sy205_glb_derived_v4.params.json"
DEFAULT_CALIBRATION_PATH = ROOT / "assets/calibration/m1_provisional_calibration.json"
DEFAULT_REFERENCE_SOURCE_PATH = ROOT / "assets/model/kinematic_excavator.urdf"
DEFAULT_URDF_PATH = ROOT / "assets/model/sy205_glb_derived_v4.urdf"
DEFAULT_EVIDENCE_PATH = ROOT / "assets/model/sy205_glb_derived_v4.json"
DEFAULT_REFERENCE_OUTPUT_PATH = ROOT / "assets/model/library/sy135_reference.urdf"

MAIN_LINK_NAMES = (
    "base_link",
    "upper_structure_link",
    "boom_link",
    "arm_link",
    "bucket_link",
)
ZERO_SHA256 = "0" * 64
GLB_MAGIC = b"glTF"
GLB_JSON_CHUNK = 0x4E4F534A
GLB_BIN_CHUNK = 0x004E4942
FLOAT32_VEC3_SIZE = 12

FloatArray = NDArray[np.float64]
Vector3 = tuple[float, float, float]


class GenerationError(ValueError):
    """Raised when source evidence cannot produce a valid deterministic candidate."""


@dataclass(frozen=True)
class Bounds:
    minimum: Vector3
    maximum: Vector3

    @property
    def size(self) -> Vector3:
        return tuple(high - low for low, high in zip(self.minimum, self.maximum, strict=True))  # type: ignore[return-value]

    @property
    def center(self) -> Vector3:
        return tuple(
            (low + high) / 2.0 for low, high in zip(self.minimum, self.maximum, strict=True)
        )  # type: ignore[return-value]


@dataclass(frozen=True)
class PrimitiveSource:
    node_index_path: tuple[int, ...]
    node_name_path: str
    mesh_index: int
    primitive_index: int
    position_accessor: int
    vertex_count: int


@dataclass(frozen=True)
class LinkExtraction:
    name: str
    pivot_index_path: tuple[int, ...]
    pivot_name_path: str
    vertices_python: FloatArray
    bounds: Bounds
    sources: tuple[PrimitiveSource, ...]


@dataclass(frozen=True)
class LinkEstimate:
    mass_kg: float
    center_of_mass: Vector3
    visual_size: Vector3
    collision_size: Vector3
    inertia_at_com: Vector3
    inertia_at_link_origin: FloatArray


@dataclass(frozen=True)
class GlbAsset:
    document: dict[str, Any]
    binary_chunk: bytes
    sha256: str
    byte_size: int
    nodes: tuple[dict[str, Any], ...]
    parents: tuple[int | None, ...]
    scene_roots: tuple[int, ...]
    local_transforms: tuple[FloatArray, ...]
    world_transforms: tuple[FloatArray, ...]


@dataclass(frozen=True)
class ArtifactBundle:
    urdf_bytes: bytes
    evidence_bytes: bytes
    reference_urdf_bytes: bytes


def _fail(message: str) -> NoReturn:
    raise GenerationError(message)


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _reject_json_constant(value: str) -> NoReturn:
    _fail(f"JSON contains non-finite constant {value!r}")


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            _fail(f"JSON contains duplicate key {key!r}")
        result[key] = value
    return result


def _load_json_bytes(data: bytes, label: str) -> dict[str, Any]:
    try:
        value = json.loads(
            data.decode("utf-8"),
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise GenerationError(f"{label} is not valid UTF-8 JSON") from exc
    return _as_object(value, label)


def _as_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        _fail(f"{label} must be an object")
    return cast(dict[str, Any], value)


def _as_array(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        _fail(f"{label} must be an array")
    return value


def _as_string(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        _fail(f"{label} must be a non-empty string")
    return value


def _as_int(value: Any, label: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        _fail(f"{label} must be an integer")
    return value


def _as_float(value: Any, label: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        _fail(f"{label} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        _fail(f"{label} must be finite")
    return result


def _as_vector3(value: Any, label: str) -> Vector3:
    items = _as_array(value, label)
    if len(items) != 3:
        _fail(f"{label} must contain three values")
    return (
        _as_float(items[0], f"{label}[0]"),
        _as_float(items[1], f"{label}[1]"),
        _as_float(items[2], f"{label}[2]"),
    )


def _as_index_path(value: Any, label: str) -> tuple[int, ...]:
    items = _as_array(value, label)
    if not items:
        _fail(f"{label} must not be empty")
    path = tuple(_as_int(item, f"{label}[]") for item in items)
    if any(index < 0 for index in path):
        _fail(f"{label} must contain non-negative node indices")
    return path


def _format_float(value: float, decimals: int) -> str:
    if not math.isfinite(value):
        _fail("cannot render a non-finite float")
    rendered = f"{value:.{decimals}f}".rstrip("0").rstrip(".")
    if rendered in {"", "-0"}:
        return "0"
    return rendered


def _round_float(value: float, decimals: int) -> float:
    return float(_format_float(value, decimals))


def _round_vector(value: Vector3, decimals: int) -> Vector3:
    return tuple(_round_float(item, decimals) for item in value)  # type: ignore[return-value]


def _vector_text(value: Vector3, decimals: int) -> str:
    return " ".join(_format_float(item, decimals) for item in value)


def _node_transform(node: dict[str, Any], label: str) -> FloatArray:
    if "matrix" in node and any(key in node for key in ("translation", "rotation", "scale")):
        _fail(f"{label} mixes matrix and TRS transforms")
    if "matrix" in node:
        values = _as_array(node["matrix"], f"{label}.matrix")
        if len(values) != 16:
            _fail(f"{label}.matrix must contain 16 values")
        matrix = np.asarray(
            [_as_float(value, f"{label}.matrix[]") for value in values], dtype=np.float64
        ).reshape((4, 4), order="F")
        if not np.allclose(matrix[3], (0.0, 0.0, 0.0, 1.0), atol=1e-10):
            _fail(f"{label}.matrix is not affine")
        return matrix

    translation = _as_vector3(node.get("translation", [0.0, 0.0, 0.0]), f"{label}.translation")
    scale = _as_vector3(node.get("scale", [1.0, 1.0, 1.0]), f"{label}.scale")
    rotation_values = _as_array(node.get("rotation", [0.0, 0.0, 0.0, 1.0]), f"{label}.rotation")
    if len(rotation_values) != 4:
        _fail(f"{label}.rotation must contain four values")
    x, y, z, w = (_as_float(value, f"{label}.rotation[]") for value in rotation_values)
    norm = math.sqrt(x * x + y * y + z * z + w * w)
    if norm <= 1e-12:
        _fail(f"{label}.rotation has zero length")
    x, y, z, w = x / norm, y / norm, z / norm, w / norm
    rotation = np.asarray(
        [
            [1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - z * w), 2.0 * (x * z + y * w)],
            [2.0 * (x * y + z * w), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - x * w)],
            [2.0 * (x * z - y * w), 2.0 * (y * z + x * w), 1.0 - 2.0 * (x * x + y * y)],
        ],
        dtype=np.float64,
    )
    matrix = np.eye(4, dtype=np.float64)
    matrix[:3, :3] = rotation @ np.diag(np.asarray(scale, dtype=np.float64))
    matrix[:3, 3] = np.asarray(translation, dtype=np.float64)
    return matrix


def _validate_unit_rigid(transform: FloatArray, label: str) -> None:
    basis = transform[:3, :3]
    if not np.all(np.isfinite(transform)):
        _fail(f"{label} contains non-finite transform data")
    if not np.allclose(basis.T @ basis, np.eye(3), atol=1e-7):
        _fail(f"{label} has non-unit or non-rigid scale")
    determinant = float(np.linalg.det(basis))
    if not math.isclose(determinant, 1.0, abs_tol=1e-7):
        _fail(f"{label} is mirrored or non-rigid")


def parse_glb(data: bytes) -> GlbAsset:
    if len(data) < 12:
        _fail("GLB is shorter than its header")
    magic, version, declared_length = struct.unpack_from("<4sII", data, 0)
    if magic != GLB_MAGIC or version != 2:
        _fail("source must be a glTF 2.0 binary GLB")
    if declared_length != len(data):
        _fail("GLB declared length does not match source bytes")

    chunks: dict[int, bytes] = {}
    chunk_order: list[int] = []
    offset = 12
    while offset < len(data):
        if offset % 4 != 0:
            _fail("GLB chunk header is not 4-byte aligned")
        if offset + 8 > len(data):
            _fail("GLB chunk header is truncated")
        chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
        if chunk_length % 4 != 0:
            _fail("GLB chunk length is not 4-byte aligned")
        offset += 8
        chunk_end = offset + chunk_length
        if chunk_end > len(data):
            _fail("GLB chunk payload is truncated")
        if chunk_type in chunks:
            _fail("GLB contains a duplicate JSON or BIN chunk")
        if chunk_type not in {GLB_JSON_CHUNK, GLB_BIN_CHUNK}:
            _fail(f"GLB contains unsupported chunk type 0x{chunk_type:08x}")
        chunks[chunk_type] = data[offset:chunk_end]
        chunk_order.append(chunk_type)
        offset = chunk_end
    if offset != len(data) or GLB_JSON_CHUNK not in chunks or GLB_BIN_CHUNK not in chunks:
        _fail("GLB must contain exactly one JSON and one BIN chunk")
    if chunk_order != [GLB_JSON_CHUNK, GLB_BIN_CHUNK]:
        _fail("GLB chunks must appear in JSON then BIN order")

    document = _load_json_bytes(chunks[GLB_JSON_CHUNK].rstrip(b" \t\r\n\x00"), "GLB JSON")
    asset = _as_object(document.get("asset"), "GLB asset")
    if asset.get("version") != "2.0":
        _fail("GLB JSON asset.version must be '2.0'")
    buffers = _as_array(document.get("buffers"), "GLB buffers")
    if len(buffers) != 1:
        _fail("generator supports exactly one embedded GLB buffer")
    buffer = _as_object(buffers[0], "GLB buffers[0]")
    if "uri" in buffer:
        _fail("GLB buffer must be embedded")
    buffer_length = _as_int(buffer.get("byteLength"), "GLB buffers[0].byteLength")
    binary_chunk = chunks[GLB_BIN_CHUNK]
    if (
        buffer_length < 0
        or buffer_length > len(binary_chunk)
        or len(binary_chunk) - buffer_length > 3
    ):
        _fail("GLB BIN chunk length does not match buffers[0].byteLength")
    binary_chunk = binary_chunk[:buffer_length]

    raw_nodes = _as_array(document.get("nodes"), "GLB nodes")
    nodes = tuple(_as_object(node, f"GLB nodes[{index}]") for index, node in enumerate(raw_nodes))
    if not nodes:
        _fail("GLB contains no nodes")
    parents: list[int | None] = [None] * len(nodes)
    for parent_index, node in enumerate(nodes):
        children = _as_array(node.get("children", []), f"GLB nodes[{parent_index}].children")
        seen_children: set[int] = set()
        for raw_child in children:
            child_index = _as_int(raw_child, f"GLB nodes[{parent_index}].children[]")
            if child_index < 0 or child_index >= len(nodes) or child_index == parent_index:
                _fail(f"GLB node {parent_index} has an invalid child index")
            if child_index in seen_children or parents[child_index] is not None:
                _fail(f"GLB node {child_index} has duplicate or multiple parents")
            seen_children.add(child_index)
            parents[child_index] = parent_index

    states = [0] * len(nodes)

    def visit(node_index: int) -> None:
        if states[node_index] == 1:
            _fail("GLB node graph contains a cycle")
        if states[node_index] == 2:
            return
        states[node_index] = 1
        for child in _as_array(nodes[node_index].get("children", []), "GLB node children"):
            visit(_as_int(child, "GLB child index"))
        states[node_index] = 2

    for node_index in range(len(nodes)):
        visit(node_index)

    scenes = _as_array(document.get("scenes"), "GLB scenes")
    if len(scenes) != 1:
        _fail("approved GLB contract requires exactly one scene")
    scene_index = _as_int(document.get("scene", 0), "GLB scene")
    if scene_index != 0:
        _fail("approved GLB contract requires scene index 0")
    scene = _as_object(scenes[0], "GLB scenes[0]")
    scene_roots = tuple(
        _as_int(value, "GLB scenes[0].nodes[]")
        for value in _as_array(scene.get("nodes"), "GLB scenes[0].nodes")
    )
    if not scene_roots or any(index < 0 or index >= len(nodes) for index in scene_roots):
        _fail("GLB scene roots are invalid")

    local_transforms = tuple(
        _node_transform(node, f"GLB nodes[{index}]") for index, node in enumerate(nodes)
    )
    world_cache: list[FloatArray | None] = [None] * len(nodes)

    def world_transform(node_index: int) -> FloatArray:
        cached = world_cache[node_index]
        if cached is not None:
            return cached
        parent = parents[node_index]
        world = local_transforms[node_index]
        if parent is not None:
            world = world_transform(parent) @ world
        world_cache[node_index] = world
        return world

    world_transforms = tuple(world_transform(index) for index in range(len(nodes)))
    return GlbAsset(
        document=document,
        binary_chunk=binary_chunk,
        sha256=_sha256(data),
        byte_size=len(data),
        nodes=nodes,
        parents=tuple(parents),
        scene_roots=scene_roots,
        local_transforms=local_transforms,
        world_transforms=world_transforms,
    )


def _resolve_index_path(asset: GlbAsset, path: tuple[int, ...], label: str) -> int:
    if path[0] not in asset.scene_roots:
        _fail(f"{label} does not begin at a scene root")
    for parent, child in pairwise(path):
        if parent >= len(asset.nodes) or child >= len(asset.nodes):
            _fail(f"{label} references a missing node")
        children = {
            _as_int(value, f"GLB nodes[{parent}].children[]")
            for value in _as_array(asset.nodes[parent].get("children", []), "GLB node children")
        }
        if child not in children:
            _fail(f"{label} is not a valid parent-child node path")
    if path[-1] >= len(asset.nodes):
        _fail(f"{label} references a missing node")
    return path[-1]


def _node_name_path(asset: GlbAsset, path: tuple[int, ...], label: str) -> str:
    _resolve_index_path(asset, path, label)
    names = [
        _as_string(asset.nodes[index].get("name"), f"GLB nodes[{index}].name") for index in path
    ]
    return "/".join(names)


def decode_position_accessor(
    document: dict[str, Any], binary_chunk: bytes, accessor_index: int
) -> FloatArray:
    accessors = _as_array(document.get("accessors"), "GLB accessors")
    buffer_views = _as_array(document.get("bufferViews"), "GLB bufferViews")
    if accessor_index < 0 or accessor_index >= len(accessors):
        _fail("POSITION accessor index is out of range")
    accessor = _as_object(accessors[accessor_index], f"GLB accessors[{accessor_index}]")
    if accessor.get("componentType") != 5126 or accessor.get("type") != "VEC3":
        _fail("POSITION accessor must use FLOAT VEC3")
    if accessor.get("normalized", False) is not False or "sparse" in accessor:
        _fail("normalized or sparse POSITION accessors are unsupported")
    count = _as_int(accessor.get("count"), f"GLB accessors[{accessor_index}].count")
    if count <= 0:
        _fail("POSITION accessor must contain at least one vertex")
    view_index = _as_int(accessor.get("bufferView"), f"GLB accessors[{accessor_index}].bufferView")
    if view_index < 0 or view_index >= len(buffer_views):
        _fail("POSITION bufferView index is out of range")
    view = _as_object(buffer_views[view_index], f"GLB bufferViews[{view_index}]")
    if _as_int(view.get("buffer", 0), f"GLB bufferViews[{view_index}].buffer") != 0:
        _fail("POSITION bufferView must reference embedded buffer 0")
    view_offset = _as_int(view.get("byteOffset", 0), "POSITION bufferView.byteOffset")
    view_length = _as_int(view.get("byteLength"), "POSITION bufferView.byteLength")
    accessor_offset = _as_int(accessor.get("byteOffset", 0), "POSITION accessor.byteOffset")
    stride = _as_int(view.get("byteStride", FLOAT32_VEC3_SIZE), "POSITION bufferView.byteStride")
    if min(view_offset, view_length, accessor_offset) < 0:
        _fail("POSITION byte offsets and lengths must be non-negative")
    if stride < FLOAT32_VEC3_SIZE or stride % 4 != 0:
        _fail("POSITION byteStride is invalid")
    first = view_offset + accessor_offset
    end = first + (count - 1) * stride + FLOAT32_VEC3_SIZE
    view_end = view_offset + view_length
    if first < view_offset or end > view_end or view_end > len(binary_chunk):
        _fail("POSITION accessor exceeds its bufferView or BIN chunk")

    vertices = np.empty((count, 3), dtype=np.float64)
    for index in range(count):
        vertices[index] = struct.unpack_from("<fff", binary_chunk, first + index * stride)
    if not np.all(np.isfinite(vertices)):
        _fail("POSITION accessor contains non-finite vertices")

    for key, reducer in (("min", np.min), ("max", np.max)):
        if key not in accessor:
            continue
        declared = np.asarray(
            _as_vector3(accessor[key], f"GLB accessors[{accessor_index}].{key}"),
            dtype=np.float64,
        )
        actual = reducer(vertices, axis=0)
        if not np.allclose(actual, declared, atol=1e-5):
            _fail(f"POSITION accessor {key} does not match decoded vertices")
    return vertices


def _apply_transform(transform: FloatArray, vertices: FloatArray) -> FloatArray:
    return vertices @ transform[:3, :3].T + transform[:3, 3]


def _basis_from_parameters(parameters: dict[str, Any]) -> tuple[FloatArray, int, int, float]:
    coordinate = _as_object(parameters.get("coordinate_system"), "parameters.coordinate_system")
    rows = _as_array(
        coordinate.get("godot_to_python_basis"),
        "parameters.coordinate_system.godot_to_python_basis",
    )
    if len(rows) != 3:
        _fail("godot_to_python_basis must be 3x3")
    basis = np.asarray(
        [_as_vector3(row, "godot_to_python_basis row") for row in rows], dtype=np.float64
    )
    if not np.allclose(basis.T @ basis, np.eye(3), atol=1e-12):
        _fail("godot_to_python_basis must be orthonormal")
    if not math.isclose(float(np.linalg.det(basis)), 1.0, abs_tol=1e-12):
        _fail("godot_to_python_basis must preserve handedness")
    origin_decimals = _as_int(coordinate.get("joint_origin_decimals"), "joint_origin_decimals")
    geometry_decimals = _as_int(coordinate.get("geometry_decimals"), "geometry_decimals")
    tolerance = _as_float(coordinate.get("validation_tolerance_m"), "validation_tolerance_m")
    if not 0 <= origin_decimals <= 15 or not 0 <= geometry_decimals <= 15 or tolerance <= 0:
        _fail("coordinate precision and tolerance parameters are invalid")
    return basis, origin_decimals, geometry_decimals, tolerance


def _validate_source_identity(
    asset: GlbAsset,
    manifest: dict[str, Any],
    parameters: dict[str, Any],
    reference_bytes: bytes,
) -> None:
    source = _as_object(parameters.get("source"), "parameters.source")
    expected_sha = _as_string(source.get("sha256"), "parameters.source.sha256")
    expected_size = _as_int(source.get("byte_size"), "parameters.source.byte_size")
    expected_reference_sha = _as_string(
        source.get("reference_urdf_sha256"), "parameters.source.reference_urdf_sha256"
    )
    manifest_source = _as_object(manifest.get("source"), "visual manifest source")
    manifest_sha = _as_string(manifest_source.get("sha256"), "visual manifest source.sha256")
    manifest_size = _as_int(manifest_source.get("byte_size"), "visual manifest source.byte_size")
    if asset.sha256 != expected_sha or asset.sha256 != manifest_sha:
        _fail("approved GLB SHA-256 does not match parameters and visual manifest")
    if asset.byte_size != expected_size or asset.byte_size != manifest_size:
        _fail("approved GLB byte size does not match parameters and visual manifest")
    if _sha256(reference_bytes) != expected_reference_sha:
        _fail("future SY135 reference URDF bytes drifted from the approved source")


def _link_config(parameters: dict[str, Any], link_name: str) -> dict[str, Any]:
    links = _as_object(parameters.get("links"), "parameters.links")
    if set(links) != set(MAIN_LINK_NAMES):
        _fail("parameters.links must contain exactly the five authority links")
    return _as_object(links.get(link_name), f"parameters.links.{link_name}")


def _validate_link_contracts(
    asset: GlbAsset,
    manifest: dict[str, Any],
    parameters: dict[str, Any],
    tolerance: float,
) -> None:
    frame_map = _as_object(manifest.get("frame_map"), "visual manifest frame_map")
    local_kinematics = _as_object(
        manifest.get("local_kinematics"), "visual manifest local_kinematics"
    )
    frame_contracts = _as_object(
        local_kinematics.get("frame_contracts"), "visual manifest frame_contracts"
    )
    for link_name in MAIN_LINK_NAMES:
        config = _link_config(parameters, link_name)
        pivot_path = _as_index_path(config.get("pivot_index_path"), f"{link_name}.pivot_index_path")
        expected_pivot_name = _as_string(
            config.get("pivot_name_path"), f"{link_name}.pivot_name_path"
        )
        actual_pivot_name = _node_name_path(asset, pivot_path, f"{link_name} pivot path")
        if actual_pivot_name != expected_pivot_name:
            _fail(f"{link_name} node-index path no longer resolves to its approved pivot")
        pivot_index = pivot_path[-1]
        _validate_unit_rigid(asset.local_transforms[pivot_index], f"{link_name} pivot")

        manifest_frame = _as_object(frame_map.get(link_name), f"frame_map.{link_name}")
        if manifest_frame.get("node_path") != expected_pivot_name:
            _fail(f"visual manifest pivot path drifted for {link_name}")
        visual_index_paths = [
            _as_index_path(value, f"{link_name}.visual_index_paths[]")
            for value in _as_array(config.get("visual_index_paths"), "visual_index_paths")
        ]
        visual_name_paths = [
            _as_string(value, f"{link_name}.visual_name_paths[]")
            for value in _as_array(config.get("visual_name_paths"), "visual_name_paths")
        ]
        if len(visual_index_paths) != len(visual_name_paths) or not visual_index_paths:
            _fail(f"{link_name} visual path lists must be non-empty and equal length")
        actual_visual_names = [
            _node_name_path(asset, path, f"{link_name} visual path") for path in visual_index_paths
        ]
        manifest_visual_names = [
            _as_string(value, f"frame_map.{link_name}.visual_nodes[]")
            for value in _as_array(manifest_frame.get("visual_nodes"), "visual_nodes")
        ]
        if actual_visual_names != visual_name_paths or actual_visual_names != manifest_visual_names:
            _fail(f"visual ownership drifted for {link_name}")

        contract = _as_object(frame_contracts.get(link_name), f"frame_contracts.{link_name}")
        declared_position = np.asarray(
            _as_vector3(contract.get("parent_local_position"), "parent_local_position"),
            dtype=np.float64,
        )
        actual_position = asset.local_transforms[pivot_index][:3, 3]
        if not np.allclose(actual_position, declared_position, atol=tolerance):
            _fail(f"visual manifest local pivot position drifted for {link_name}")
        declared_scale = _as_vector3(contract.get("scale"), "frame contract scale")
        if not np.allclose(declared_scale, (1.0, 1.0, 1.0), atol=1e-12):
            _fail(f"visual manifest moving scale is not unit for {link_name}")


def _extract_link_geometry(
    asset: GlbAsset,
    parameters: dict[str, Any],
    link_name: str,
    godot_to_python: FloatArray,
) -> LinkExtraction:
    config = _link_config(parameters, link_name)
    pivot_path = _as_index_path(config.get("pivot_index_path"), f"{link_name}.pivot_index_path")
    pivot_name_path = _as_string(config.get("pivot_name_path"), f"{link_name}.pivot_name_path")
    pivot_index = _resolve_index_path(asset, pivot_path, f"{link_name} pivot path")
    origin_policy = _as_string(config.get("authority_origin"), f"{link_name}.authority_origin")
    if origin_policy == "scene_identity":
        authority_world = np.eye(4, dtype=np.float64)
    elif origin_policy == "pivot":
        authority_world = asset.world_transforms[pivot_index]
    else:
        _fail(f"unsupported authority origin policy for {link_name}")
    authority_inverse = np.linalg.inv(authority_world)

    all_vertices: list[FloatArray] = []
    sources: list[PrimitiveSource] = []
    meshes = _as_array(asset.document.get("meshes"), "GLB meshes")
    visual_paths = [
        _as_index_path(value, f"{link_name}.visual_index_paths[]")
        for value in _as_array(config.get("visual_index_paths"), "visual_index_paths")
    ]
    for visual_path in visual_paths:
        node_index = _resolve_index_path(asset, visual_path, f"{link_name} visual path")
        node = asset.nodes[node_index]
        mesh_index = _as_int(node.get("mesh"), f"GLB nodes[{node_index}].mesh")
        if mesh_index < 0 or mesh_index >= len(meshes):
            _fail(f"{link_name} visual node references an invalid mesh")
        mesh = _as_object(meshes[mesh_index], f"GLB meshes[{mesh_index}]")
        primitives = _as_array(mesh.get("primitives"), f"GLB meshes[{mesh_index}].primitives")
        if not primitives:
            _fail(f"{link_name} visual mesh contains no primitives")
        link_from_mesh = authority_inverse @ asset.world_transforms[node_index]
        for primitive_index, raw_primitive in enumerate(primitives):
            primitive = _as_object(
                raw_primitive, f"GLB meshes[{mesh_index}].primitives[{primitive_index}]"
            )
            if primitive.get("mode", 4) != 4:
                _fail("only triangle POSITION primitives are supported")
            attributes = _as_object(primitive.get("attributes"), "GLB primitive attributes")
            accessor_index = _as_int(attributes.get("POSITION"), "GLB primitive POSITION")
            vertices_mesh = decode_position_accessor(
                asset.document, asset.binary_chunk, accessor_index
            )
            vertices_godot = _apply_transform(link_from_mesh, vertices_mesh)
            vertices_python = vertices_godot @ godot_to_python.T
            if not np.all(np.isfinite(vertices_python)):
                _fail(f"{link_name} transformed vertices are non-finite")
            all_vertices.append(vertices_python)
            sources.append(
                PrimitiveSource(
                    node_index_path=visual_path,
                    node_name_path=_node_name_path(asset, visual_path, "visual path"),
                    mesh_index=mesh_index,
                    primitive_index=primitive_index,
                    position_accessor=accessor_index,
                    vertex_count=len(vertices_python),
                )
            )
    vertices = np.concatenate(all_vertices, axis=0)
    minimum = tuple(float(value) for value in np.min(vertices, axis=0))
    maximum = tuple(float(value) for value in np.max(vertices, axis=0))
    bounds = Bounds(cast(Vector3, minimum), cast(Vector3, maximum))
    if any(size <= 0 or not math.isfinite(size) for size in bounds.size):
        _fail(f"{link_name} has non-positive geometry bounds")
    return LinkExtraction(
        name=link_name,
        pivot_index_path=pivot_path,
        pivot_name_path=pivot_name_path,
        vertices_python=vertices,
        bounds=bounds,
        sources=tuple(sources),
    )


def _derive_joint_contracts(
    asset: GlbAsset,
    manifest: dict[str, Any],
    parameters: dict[str, Any],
    godot_to_python: FloatArray,
    origin_decimals: int,
    tolerance: float,
) -> list[dict[str, Any]]:
    raw_joints = _as_array(parameters.get("joints"), "parameters.joints")
    if len(raw_joints) != len(ACTIVE_JOINT_NAMES):
        _fail("parameters.joints must contain the four active joints")
    runtime_axes = _as_object(
        _as_object(manifest.get("coordinate_system"), "visual manifest coordinate_system").get(
            "runtime_axes"
        ),
        "visual manifest runtime_axes",
    )
    axis_godot = {
        "X": np.asarray((1.0, 0.0, 0.0), dtype=np.float64),
        "Y": np.asarray((0.0, 1.0, 0.0), dtype=np.float64),
        "Z": np.asarray((0.0, 0.0, 1.0), dtype=np.float64),
    }
    result: list[dict[str, Any]] = []
    for expected_name, raw_joint in zip(ACTIVE_JOINT_NAMES, raw_joints, strict=True):
        joint = _as_object(raw_joint, f"parameters.joints.{expected_name}")
        name = _as_string(joint.get("name"), "joint name")
        parent = _as_string(joint.get("parent"), f"{name}.parent")
        child = _as_string(joint.get("child"), f"{name}.child")
        if name != expected_name or parent not in MAIN_LINK_NAMES or child not in MAIN_LINK_NAMES:
            _fail("active joint names/order/links do not match the runtime contract")
        child_config = _link_config(parameters, child)
        child_path = _as_index_path(child_config.get("pivot_index_path"), f"{child}.pivot")
        child_index = _resolve_index_path(asset, child_path, f"{child} pivot")
        if name == "swing_joint":
            relative = asset.world_transforms[child_index]
        else:
            parent_config = _link_config(parameters, parent)
            parent_path = _as_index_path(parent_config.get("pivot_index_path"), f"{parent}.pivot")
            parent_index = _resolve_index_path(asset, parent_path, f"{parent} pivot")
            relative = (
                np.linalg.inv(asset.world_transforms[parent_index])
                @ asset.world_transforms[child_index]
            )
        rotation_python = godot_to_python @ relative[:3, :3] @ godot_to_python.T
        if not np.allclose(rotation_python, np.eye(3), atol=1e-7):
            _fail(f"{name} imported rest rotation is not identity")
        origin_raw = godot_to_python @ relative[:3, 3]
        origin = cast(
            Vector3,
            tuple(_round_float(float(value), origin_decimals) for value in origin_raw),
        )
        expected_origin = _as_vector3(joint.get("expected_origin_xyz"), f"{name}.origin")
        if not np.allclose(origin, expected_origin, atol=tolerance):
            _fail(f"{name} origin no longer matches the approved coordinate table")
        runtime_axis_name = _as_string(
            joint.get("runtime_axis_godot"), f"{name}.runtime_axis_godot"
        )
        if runtime_axes.get(child) != runtime_axis_name or runtime_axis_name not in axis_godot:
            _fail(f"{name} runtime axis disagrees with the visual manifest")
        axis_array = godot_to_python @ axis_godot[runtime_axis_name]
        axis = cast(Vector3, tuple(_round_float(float(value), 9) for value in axis_array))
        expected_axis = _as_vector3(joint.get("expected_axis_xyz"), f"{name}.axis")
        if not np.allclose(axis, expected_axis, atol=1e-12):
            _fail(f"{name} axis no longer matches the approved coordinate table")
        result.append(
            {
                "name": name,
                "parent": parent,
                "child": child,
                "origin_xyz": origin,
                "origin_xyz_observed_unrounded": tuple(float(value) for value in origin_raw),
                "axis_xyz": axis,
                "child_pivot_index_path": child_path,
                "child_pivot_name_path": _node_name_path(asset, child_path, f"{child} pivot"),
            }
        )
    return result


def _estimate_links(
    extractions: dict[str, LinkExtraction], parameters: dict[str, Any]
) -> dict[str, LinkEstimate]:
    estimates = _as_object(parameters.get("estimates"), "parameters.estimates")
    total_mass = _as_float(estimates.get("total_operating_mass_kg"), "total_operating_mass_kg")
    padding = _as_float(estimates.get("collision_padding_m"), "collision_padding_m")
    if total_mass <= 0 or padding < 0:
        _fail("mass and collision estimate parameters are invalid")
    fractions = {
        link_name: _as_float(
            _link_config(parameters, link_name).get("mass_fraction"), f"{link_name}.mass_fraction"
        )
        for link_name in MAIN_LINK_NAMES
    }
    if any(value <= 0 for value in fractions.values()) or not math.isclose(
        sum(fractions.values()), 1.0, abs_tol=1e-12
    ):
        _fail("link mass fractions must be positive and sum to one")

    result: dict[str, LinkEstimate] = {}
    for link_name in MAIN_LINK_NAMES:
        bounds = extractions[link_name].bounds
        size = bounds.size
        center = bounds.center
        mass = total_mass * fractions[link_name]
        sx, sy, sz = size
        inertia = (
            mass * (sy * sy + sz * sz) / 12.0,
            mass * (sx * sx + sz * sz) / 12.0,
            mass * (sx * sx + sy * sy) / 12.0,
        )
        displacement = np.asarray(center, dtype=np.float64)
        inertia_com = np.diag(np.asarray(inertia, dtype=np.float64))
        inertia_origin = inertia_com + mass * (
            float(displacement @ displacement) * np.eye(3) - np.outer(displacement, displacement)
        )
        collision_size = tuple(value + 2.0 * padding for value in size)
        numeric_values = (mass, *center, *size, *collision_size, *inertia)
        positive_values = (mass, *size, *collision_size, *inertia)
        if any(not math.isfinite(value) or value <= 0 for value in positive_values):
            _fail(f"{link_name} produced invalid physical estimates")
        if any(not math.isfinite(value) for value in numeric_values):
            _fail(f"{link_name} produced non-finite physical estimates")
        if np.min(np.linalg.eigvalsh(inertia_origin)) <= 0:
            _fail(f"{link_name} produced a non-positive inertia estimate")
        result[link_name] = LinkEstimate(
            mass_kg=mass,
            center_of_mass=center,
            visual_size=size,
            collision_size=cast(Vector3, collision_size),
            inertia_at_com=inertia,
            inertia_at_link_origin=inertia_origin,
        )
    return result


def _derive_fixed_frames(
    extractions: dict[str, LinkExtraction], parameters: dict[str, Any]
) -> dict[str, dict[str, Any]]:
    estimates = _as_object(parameters.get("estimates"), "parameters.estimates")
    band = _as_float(estimates.get("tooth_front_band_m"), "tooth_front_band_m")
    cluster_size = _as_int(estimates.get("tooth_cluster_size"), "tooth_cluster_size")
    if band <= 0 or cluster_size <= 0:
        _fail("tooth selection parameters must be positive")
    bucket_vertices = extractions["bucket_link"].vertices_python
    front_y = float(np.max(bucket_vertices[:, 1]))
    front_vertices = [
        cast(Vector3, tuple(float(value) for value in row))
        for row in bucket_vertices[bucket_vertices[:, 1] >= front_y - band]
    ]
    if len(front_vertices) < cluster_size * 3:
        _fail("bucket front band does not contain enough vertices for three tooth markers")
    ordered = sorted(front_vertices)
    left_values = ordered[:cluster_size]
    right_values = ordered[-cluster_size:]

    def mean(values: list[Vector3]) -> Vector3:
        array = np.asarray(values, dtype=np.float64)
        return cast(Vector3, tuple(float(value) for value in np.mean(array, axis=0)))

    left = mean(left_values)
    right = mean(right_values)
    center = cast(
        Vector3,
        tuple(
            (left_value + right_value) / 2.0
            for left_value, right_value in zip(left, right, strict=True)
        ),
    )
    tooth_positions = {
        "tooth_left": left,
        "tooth_center": center,
        "tooth_right": right,
    }
    if not (
        tooth_positions["tooth_left"][0]
        < tooth_positions["tooth_center"][0]
        < tooth_positions["tooth_right"][0]
    ):
        _fail("bucket tooth selection did not produce stable left/center/right ordering")
    result: dict[str, dict[str, Any]] = {
        name: {
            "parent": "bucket_link",
            "origin_xyz": position,
            "rule": (
                "bucket_front_band_outer_cluster_midpoint"
                if name == "tooth_center"
                else "bucket_front_band_outer_cluster"
            ),
            "candidate_vertex_count": len(front_vertices),
        }
        for name, position in tooth_positions.items()
    }

    sensor_rules = _as_object(estimates.get("sensor_rules"), "estimates.sensor_rules")
    margin = _as_float(estimates.get("gnss_top_margin_m"), "gnss_top_margin_m")
    expected_sensors = {
        "gnss_link",
        "swing_imu_link",
        "boom_imu_link",
        "arm_imu_link",
        "bucket_imu_link",
    }
    if set(sensor_rules) != expected_sensors:
        _fail("sensor_rules must define GNSS and the four required IMU frames")
    for frame_name in sorted(expected_sensors):
        rule = _as_object(sensor_rules[frame_name], f"sensor_rules.{frame_name}")
        parent = _as_string(rule.get("parent"), f"{frame_name}.parent")
        rule_name = _as_string(rule.get("rule"), f"{frame_name}.rule")
        if parent not in extractions:
            _fail(f"{frame_name} references an unknown parent link")
        bounds = extractions[parent].bounds
        if rule_name == "bounds_center":
            origin = bounds.center
        elif rule_name == "bounds_top_center" and frame_name == "gnss_link":
            origin = (bounds.center[0], bounds.center[1], bounds.maximum[2] + margin)
        else:
            _fail(f"unsupported sensor landmark rule for {frame_name}")
        result[frame_name] = {"parent": parent, "origin_xyz": origin, "rule": rule_name}
    return result


def _validate_calibration(calibration: dict[str, Any]) -> dict[str, Any]:
    if calibration.get("schema_version") != "machine-calibration-v2":
        _fail("calibration schema version is not machine-calibration-v2")
    limits = _as_object(calibration.get("joint_limits"), "calibration.joint_limits")
    if tuple(limits) != ACTIVE_JOINT_NAMES:
        _fail("calibration joint order does not match the runtime active joint order")
    retained_limits: dict[str, Any] = {}
    for joint_name in ACTIVE_JOINT_NAMES:
        payload = _as_object(limits[joint_name], f"joint_limits.{joint_name}")
        minimum = _as_float(payload.get("min_position_rad"), f"{joint_name}.min_position_rad")
        maximum = _as_float(payload.get("max_position_rad"), f"{joint_name}.max_position_rad")
        velocity = _as_float(payload.get("max_velocity_rad_s"), f"{joint_name}.max_velocity_rad_s")
        acceleration = _as_float(
            payload.get("max_acceleration_rad_s2"), f"{joint_name}.max_acceleration_rad_s2"
        )
        if minimum >= maximum or velocity <= 0 or acceleration <= 0:
            _fail(f"calibration limits are invalid for {joint_name}")
        retained_limits[joint_name] = {
            "evidence_level": "retained_provisional",
            "min_position_rad": minimum,
            "max_position_rad": maximum,
            "max_velocity_rad_s": velocity,
            "max_acceleration_rad_s2": acceleration,
        }
    cylinders = _as_array(calibration.get("cylinders"), "calibration.cylinders")
    return {
        "schema_version": calibration["schema_version"],
        "calibration_version": _as_string(
            calibration.get("calibration_version"), "calibration.calibration_version"
        ),
        "quality": _as_string(calibration.get("quality"), "calibration.quality"),
        "joint_limits": retained_limits,
        "cylinders": {
            "evidence_level": "retained_provisional",
            "activation_policy": "unchanged_in_m1",
            "values": cylinders,
        },
    }


def _material_definitions() -> tuple[tuple[str, str], ...]:
    return (
        ("undercarriage_color", "0.12 0.14 0.16 1"),
        ("machinery_color", "0.88 0.55 0.05 1"),
        ("bucket_color", "0.24 0.27 0.29 1"),
    )


def _render_urdf(
    parameters: dict[str, Any],
    extractions: dict[str, LinkExtraction],
    link_estimates: dict[str, LinkEstimate],
    joints: list[dict[str, Any]],
    fixed_frames: dict[str, dict[str, Any]],
    decimals: int,
) -> bytes:
    robot = ET.Element("robot", {"name": "sy205_glb_derived_v4"})
    robot.append(
        ET.Comment(
            " Generated deterministically from the approved SY205 GLB; "
            "all physical values are provisional estimates. "
        )
    )
    for name, rgba in _material_definitions():
        material = ET.SubElement(robot, "material", {"name": name})
        ET.SubElement(material, "color", {"rgba": rgba})

    for link_name in MAIN_LINK_NAMES:
        estimate = link_estimates[link_name]
        config = _link_config(parameters, link_name)
        material_name = _as_string(config.get("material"), f"{link_name}.material")
        link = ET.SubElement(robot, "link", {"name": link_name})
        inertial = ET.SubElement(link, "inertial")
        ET.SubElement(
            inertial,
            "origin",
            {"xyz": _vector_text(estimate.center_of_mass, decimals), "rpy": "0 0 0"},
        )
        ET.SubElement(inertial, "mass", {"value": _format_float(estimate.mass_kg, decimals)})
        ixx, iyy, izz = estimate.inertia_at_com
        ET.SubElement(
            inertial,
            "inertia",
            {
                "ixx": _format_float(ixx, decimals),
                "ixy": "0",
                "ixz": "0",
                "iyy": _format_float(iyy, decimals),
                "iyz": "0",
                "izz": _format_float(izz, decimals),
            },
        )
        visual = ET.SubElement(link, "visual")
        ET.SubElement(
            visual,
            "origin",
            {"xyz": _vector_text(extractions[link_name].bounds.center, decimals), "rpy": "0 0 0"},
        )
        geometry = ET.SubElement(visual, "geometry")
        ET.SubElement(geometry, "box", {"size": _vector_text(estimate.visual_size, decimals)})
        ET.SubElement(visual, "material", {"name": material_name})
        collision = ET.SubElement(link, "collision")
        ET.SubElement(
            collision,
            "origin",
            {"xyz": _vector_text(extractions[link_name].bounds.center, decimals), "rpy": "0 0 0"},
        )
        collision_geometry = ET.SubElement(collision, "geometry")
        ET.SubElement(
            collision_geometry, "box", {"size": _vector_text(estimate.collision_size, decimals)}
        )

    marker_radius = _as_float(
        _as_object(parameters.get("estimates"), "parameters.estimates").get("marker_radius_m"),
        "marker_radius_m",
    )
    for frame_name in REQUIRED_FRAME_NAMES:
        if frame_name in MAIN_LINK_NAMES:
            continue
        link = ET.SubElement(robot, "link", {"name": frame_name})
        if frame_name.startswith("tooth_"):
            visual = ET.SubElement(link, "visual")
            geometry = ET.SubElement(visual, "geometry")
            ET.SubElement(geometry, "sphere", {"radius": _format_float(marker_radius, decimals)})
            ET.SubElement(visual, "material", {"name": "bucket_color"})

    for joint in joints:
        element = ET.SubElement(robot, "joint", {"name": joint["name"], "type": "continuous"})
        ET.SubElement(element, "parent", {"link": joint["parent"]})
        ET.SubElement(element, "child", {"link": joint["child"]})
        ET.SubElement(
            element,
            "origin",
            {"xyz": _vector_text(joint["origin_xyz"], decimals), "rpy": "0 0 0"},
        )
        ET.SubElement(element, "axis", {"xyz": _vector_text(joint["axis_xyz"], decimals)})

    fixed_order = (
        "tooth_center",
        "tooth_left",
        "tooth_right",
        "gnss_link",
        "swing_imu_link",
        "boom_imu_link",
        "arm_imu_link",
        "bucket_imu_link",
    )
    for frame_name in fixed_order:
        frame = fixed_frames[frame_name]
        element = ET.SubElement(
            robot,
            "joint",
            {"name": f"{frame_name.removesuffix('_link')}_joint", "type": "fixed"},
        )
        ET.SubElement(element, "parent", {"link": frame["parent"]})
        ET.SubElement(element, "child", {"link": frame_name})
        ET.SubElement(
            element,
            "origin",
            {"xyz": _vector_text(frame["origin_xyz"], decimals), "rpy": "0 0 0"},
        )
    ET.indent(robot, space="  ")
    rendered = cast(bytes, ET.tostring(robot, encoding="utf-8", xml_declaration=True))
    return rendered + b"\n"


def _matrix_payload(matrix: FloatArray, decimals: int) -> list[list[float]]:
    return [[_round_float(float(value), decimals) for value in row] for row in matrix.tolist()]


def _logical_paths(parameters: dict[str, Any]) -> dict[str, str]:
    raw = _as_object(parameters.get("logical_paths"), "parameters.logical_paths")
    required = {
        "glb",
        "visual_manifest",
        "calibration",
        "candidate_urdf",
        "evidence",
        "reference_urdf",
    }
    if set(raw) != required:
        _fail("parameters.logical_paths does not contain the expected artifact set")
    return {key: _as_string(value, f"logical_paths.{key}") for key, value in raw.items()}


def _canonical_json(payload: dict[str, Any]) -> bytes:
    return (json.dumps(payload, indent=2, sort_keys=True, ensure_ascii=True) + "\n").encode("utf-8")


def _serialize_evidence(payload: dict[str, Any]) -> bytes:
    output = _as_object(_as_object(payload["outputs"], "outputs")["evidence"], "evidence output")
    output["sha256"] = ZERO_SHA256
    output["byte_size"] = 0
    while True:
        basis = _canonical_json(payload)
        size = len(basis)
        if output["byte_size"] == size:
            break
        output["byte_size"] = size
    basis = _canonical_json(payload)
    output["sha256"] = _sha256(basis)
    final = _canonical_json(payload)
    if len(final) != output["byte_size"]:
        _fail("evidence self-hash byte-size basis did not stabilize")
    return final


def _verify_evidence_self_hash(evidence_bytes: bytes) -> None:
    payload = _load_json_bytes(evidence_bytes, "generated evidence")
    evidence = _as_object(_as_object(payload.get("outputs"), "outputs").get("evidence"), "evidence")
    expected = _as_string(evidence.get("sha256"), "evidence.sha256")
    if _as_int(evidence.get("byte_size"), "evidence.byte_size") != len(evidence_bytes):
        _fail("evidence byte_size does not match generated bytes")
    evidence["sha256"] = ZERO_SHA256
    if _sha256(_canonical_json(payload)) != expected:
        _fail("evidence self-hash does not match its canonical zero-field basis")


def build_artifacts(
    *,
    glb_path: Path = DEFAULT_GLB_PATH,
    visual_manifest_path: Path = DEFAULT_VISUAL_MANIFEST_PATH,
    parameters_path: Path = DEFAULT_PARAMETERS_PATH,
    calibration_path: Path = DEFAULT_CALIBRATION_PATH,
    reference_source_path: Path = DEFAULT_REFERENCE_SOURCE_PATH,
) -> ArtifactBundle:
    paths = (
        glb_path,
        visual_manifest_path,
        parameters_path,
        calibration_path,
        reference_source_path,
    )
    missing = [str(path) for path in paths if not path.is_file()]
    if missing:
        _fail(f"required generation inputs are missing: {', '.join(missing)}")
    glb_bytes = glb_path.read_bytes()
    manifest_bytes = visual_manifest_path.read_bytes()
    parameters_bytes = parameters_path.read_bytes()
    calibration_bytes = calibration_path.read_bytes()
    reference_bytes = reference_source_path.read_bytes()
    manifest = _load_json_bytes(manifest_bytes, "visual manifest")
    parameters = _load_json_bytes(parameters_bytes, "generation parameters")
    calibration = _load_json_bytes(calibration_bytes, "calibration")
    if parameters.get("schema_version") != "sy205-urdf-generation-v1":
        _fail("generation parameter schema_version is unsupported")
    if parameters.get("model_version") != "sy205-glb-urdf-v4":
        _fail("generation parameter model_version is unsupported")
    asset = parse_glb(glb_bytes)
    _validate_source_identity(asset, manifest, parameters, reference_bytes)
    godot_to_python, origin_decimals, geometry_decimals, tolerance = _basis_from_parameters(
        parameters
    )
    _validate_link_contracts(asset, manifest, parameters, tolerance)
    extractions = {
        link_name: _extract_link_geometry(asset, parameters, link_name, godot_to_python)
        for link_name in MAIN_LINK_NAMES
    }
    joints = _derive_joint_contracts(
        asset,
        manifest,
        parameters,
        godot_to_python,
        origin_decimals,
        tolerance,
    )
    link_estimates = _estimate_links(extractions, parameters)
    fixed_frames = _derive_fixed_frames(extractions, parameters)
    if set(fixed_frames) | set(MAIN_LINK_NAMES) != set(REQUIRED_FRAME_NAMES):
        _fail("generated fixed frames do not match the runtime required frame contract")
    retained_calibration = _validate_calibration(calibration)
    urdf_bytes = _render_urdf(
        parameters,
        extractions,
        link_estimates,
        joints,
        fixed_frames,
        geometry_decimals,
    )
    logical_paths = _logical_paths(parameters)
    script_bytes = Path(__file__).read_bytes()
    evidence: dict[str, Any] = {
        "schema_version": "sy205-glb-urdf-evidence-v1",
        "model_version": parameters["model_version"],
        "generator": {
            "algorithm_version": 1,
            "path": "backend/scripts/generate_sy205_urdf.py",
            "sha256": _sha256(script_bytes),
        },
        "inputs": {
            "glb": {
                "evidence_level": "observed",
                "path": logical_paths["glb"],
                "byte_size": len(glb_bytes),
                "sha256": _sha256(glb_bytes),
            },
            "visual_manifest": {
                "evidence_level": "validated",
                "path": logical_paths["visual_manifest"],
                "byte_size": len(manifest_bytes),
                "sha256": _sha256(manifest_bytes),
            },
            "parameters": {
                "evidence_level": "decision",
                "path": "assets/model/sy205_glb_derived_v4.params.json",
                "byte_size": len(parameters_bytes),
                "sha256": _sha256(parameters_bytes),
            },
            "calibration": {
                "evidence_level": "retained_provisional",
                "path": logical_paths["calibration"],
                "byte_size": len(calibration_bytes),
                "sha256": _sha256(calibration_bytes),
            },
            "reference_urdf_source": {
                "evidence_level": "decision",
                "path": "assets/model/kinematic_excavator.urdf",
                "byte_size": len(reference_bytes),
                "sha256": _sha256(reference_bytes),
                "role": "future_sy135_reference_seed",
                "activation_policy": "not_an_sy205_runtime_or_rollback_model",
            },
        },
        "coordinate_system": {
            "evidence_level": "decision",
            "source": "right_handed_gltf_y_up",
            "target": "right_handed_python_z_up",
            "godot_to_python_basis": _matrix_payload(godot_to_python, geometry_decimals),
            "position_rule": "(x_godot, y_godot, z_godot) -> (x, -z, y)",
            "neutral_pose": "imported_glb_rest_pose",
            "base_authority_origin": "world_identity",
        },
        "joints": [
            {
                "name": joint["name"],
                "parent": joint["parent"],
                "child": joint["child"],
                "joint_type": "continuous",
                "origin": {
                    "evidence_level": "validated",
                    "xyz": _round_vector(joint["origin_xyz"], origin_decimals),
                    "observed_unrounded_xyz": _round_vector(
                        joint["origin_xyz_observed_unrounded"], geometry_decimals
                    ),
                    "rpy": [0.0, 0.0, 0.0],
                },
                "axis": {
                    "evidence_level": "decision",
                    "xyz": _round_vector(joint["axis_xyz"], geometry_decimals),
                },
                "child_pivot": {
                    "evidence_level": "validated",
                    "node_index_path": list(joint["child_pivot_index_path"]),
                    "node_name_path": joint["child_pivot_name_path"],
                },
            }
            for joint in joints
        ],
        "links": {
            link_name: {
                "pivot": {
                    "evidence_level": "validated",
                    "node_index_path": list(extractions[link_name].pivot_index_path),
                    "node_name_path": extractions[link_name].pivot_name_path,
                },
                "geometry": {
                    "evidence_level": "observed",
                    "bounds_min_xyz": _round_vector(
                        extractions[link_name].bounds.minimum, geometry_decimals
                    ),
                    "bounds_max_xyz": _round_vector(
                        extractions[link_name].bounds.maximum, geometry_decimals
                    ),
                    "size_xyz": _round_vector(
                        extractions[link_name].bounds.size, geometry_decimals
                    ),
                    "sources": [
                        {
                            "node_index_path": list(source.node_index_path),
                            "node_name_path": source.node_name_path,
                            "mesh_index": source.mesh_index,
                            "primitive_index": source.primitive_index,
                            "position_accessor": source.position_accessor,
                            "vertex_count": source.vertex_count,
                        }
                        for source in extractions[link_name].sources
                    ],
                },
                "mass": {
                    "evidence_level": "estimated",
                    "value_kg": _round_float(link_estimates[link_name].mass_kg, geometry_decimals),
                    "basis": _as_object(parameters["estimates"], "estimates")["mass_basis"],
                },
                "center_of_mass": {
                    "evidence_level": "estimated",
                    "xyz": _round_vector(
                        link_estimates[link_name].center_of_mass, geometry_decimals
                    ),
                    "rule": "link_local_geometry_aabb_center",
                },
                "inertia": {
                    "evidence_level": "estimated",
                    "at_com_diagonal_kg_m2": _round_vector(
                        link_estimates[link_name].inertia_at_com, geometry_decimals
                    ),
                    "at_link_origin_kg_m2": _matrix_payload(
                        link_estimates[link_name].inertia_at_link_origin, geometry_decimals
                    ),
                    "rule": "uniform_box_proxy_with_parallel_axis_trace",
                },
                "visual_proxy": {
                    "evidence_level": "estimated",
                    "shape": "box",
                    "size_xyz": _round_vector(
                        link_estimates[link_name].visual_size, geometry_decimals
                    ),
                },
                "collision_proxy": {
                    "evidence_level": "estimated",
                    "shape": "box",
                    "size_xyz": _round_vector(
                        link_estimates[link_name].collision_size, geometry_decimals
                    ),
                    "policy": "link_local_aabb_plus_checked_in_padding",
                },
            }
            for link_name in MAIN_LINK_NAMES
        },
        "fixed_frames": {
            frame_name: {
                "evidence_level": "estimated",
                "parent": frame["parent"],
                "origin_xyz": _round_vector(frame["origin_xyz"], geometry_decimals),
                "rule": frame["rule"],
                **(
                    {"candidate_vertex_count": frame["candidate_vertex_count"]}
                    if "candidate_vertex_count" in frame
                    else {}
                ),
                "review_state": "pending_v4_visual_gate",
            }
            for frame_name, frame in sorted(fixed_frames.items())
        },
        "retained_calibration": retained_calibration,
        "deferred": [
            "production-accurate mass and inertia",
            "hydraulic calibration",
            "contact and collision validation",
            "tooth and sensor landmark visual approval",
            "passive four-bar authority",
        ],
        "outputs": {
            "candidate_urdf": {
                "path": logical_paths["candidate_urdf"],
                "byte_size": len(urdf_bytes),
                "sha256": _sha256(urdf_bytes),
            },
            "reference_urdf": {
                "path": logical_paths["reference_urdf"],
                "byte_size": len(reference_bytes),
                "sha256": _sha256(reference_bytes),
                "role": "future_sy135_reference",
            },
            "evidence": {
                "path": logical_paths["evidence"],
                "byte_size": 0,
                "sha256": ZERO_SHA256,
                "hash_basis": "canonical JSON with this sha256 field replaced by 64 zeroes",
            },
        },
    }
    evidence_bytes = _serialize_evidence(evidence)
    _verify_evidence_self_hash(evidence_bytes)
    return ArtifactBundle(
        urdf_bytes=urdf_bytes,
        evidence_bytes=evidence_bytes,
        reference_urdf_bytes=reference_bytes,
    )


def _validate_candidate_urdf(urdf_bytes: bytes) -> None:
    with tempfile.TemporaryDirectory(prefix="sy205-urdf-validation-") as directory:
        candidate = Path(directory) / "candidate.urdf"
        candidate.write_bytes(urdf_bytes)
        try:
            model = ExcavatorModel.from_urdf(candidate)
        except ModelValidationError as exc:
            raise GenerationError(f"generated URDF failed runtime validation: {exc}") from exc
        if tuple(joint.name for joint in model.active_joints) != ACTIVE_JOINT_NAMES:
            _fail("generated URDF active joint order drifted")
        if model.frame_names != REQUIRED_FRAME_NAMES or model.pin_model.nv != len(
            ACTIVE_JOINT_NAMES
        ):
            _fail("generated URDF Pinocchio frame/DOF contract drifted")


def _write_staged(path: Path, data: bytes) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, raw_path = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    staged = Path(raw_path)
    try:
        with os.fdopen(descriptor, "wb") as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
    except Exception:
        staged.unlink(missing_ok=True)
        raise
    return staged


def _commit_payloads(payloads: dict[Path, bytes]) -> None:
    staged: dict[Path, Path] = {}
    backups: dict[Path, Path] = {}
    replaced: list[Path] = []
    try:
        staged = {target: _write_staged(target, data) for target, data in payloads.items()}
        for target in payloads:
            if target.exists():
                descriptor, raw_backup = tempfile.mkstemp(
                    prefix=f".{target.name}.", suffix=".bak", dir=target.parent
                )
                os.close(descriptor)
                backup = Path(raw_backup)
                shutil.copyfile(target, backup)
                backups[target] = backup
        for target, temporary in staged.items():
            os.replace(temporary, target)
            replaced.append(target)
    except Exception as exc:
        rollback_failures: list[str] = []
        for target in reversed(replaced):
            try:
                existing_backup = backups.get(target)
                if existing_backup is not None:
                    os.replace(existing_backup, target)
                else:
                    target.unlink(missing_ok=True)
            except OSError as rollback_exc:
                rollback_failures.append(f"{target}: {rollback_exc}")
        if rollback_failures:
            raise GenerationError(
                "artifact commit failed and rollback was incomplete: "
                + "; ".join(rollback_failures)
            ) from exc
        raise GenerationError(f"artifact commit failed: {exc}") from exc
    finally:
        for path in (*staged.values(), *backups.values()):
            path.unlink(missing_ok=True)


def _validate_output_paths(paths: tuple[Path, ...]) -> None:
    resolved = [os.path.normcase(str(path.resolve())) for path in paths]
    if len(resolved) != len(set(resolved)):
        _fail("output paths must be unique")


def generate(
    *,
    glb_path: Path = DEFAULT_GLB_PATH,
    visual_manifest_path: Path = DEFAULT_VISUAL_MANIFEST_PATH,
    parameters_path: Path = DEFAULT_PARAMETERS_PATH,
    calibration_path: Path = DEFAULT_CALIBRATION_PATH,
    reference_source_path: Path = DEFAULT_REFERENCE_SOURCE_PATH,
    urdf_path: Path = DEFAULT_URDF_PATH,
    evidence_path: Path = DEFAULT_EVIDENCE_PATH,
    reference_output_path: Path = DEFAULT_REFERENCE_OUTPUT_PATH,
    check: bool = False,
) -> ArtifactBundle:
    bundle = build_artifacts(
        glb_path=glb_path,
        visual_manifest_path=visual_manifest_path,
        parameters_path=parameters_path,
        calibration_path=calibration_path,
        reference_source_path=reference_source_path,
    )
    _validate_candidate_urdf(bundle.urdf_bytes)
    _validate_output_paths((urdf_path, evidence_path, reference_output_path))
    payloads = {
        urdf_path: bundle.urdf_bytes,
        evidence_path: bundle.evidence_bytes,
        reference_output_path: bundle.reference_urdf_bytes,
    }
    if check:
        mismatches = [
            str(path)
            for path, expected in payloads.items()
            if not path.is_file() or path.read_bytes() != expected
        ]
        if mismatches:
            _fail(f"generated artifacts are missing or stale: {', '.join(mismatches)}")
        return bundle
    _commit_payloads(payloads)
    return bundle


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--glb", type=Path, default=DEFAULT_GLB_PATH)
    parser.add_argument("--visual-manifest", type=Path, default=DEFAULT_VISUAL_MANIFEST_PATH)
    parser.add_argument("--parameters", type=Path, default=DEFAULT_PARAMETERS_PATH)
    parser.add_argument("--calibration", type=Path, default=DEFAULT_CALIBRATION_PATH)
    parser.add_argument("--reference-source", type=Path, default=DEFAULT_REFERENCE_SOURCE_PATH)
    parser.add_argument("--urdf-output", type=Path, default=DEFAULT_URDF_PATH)
    parser.add_argument("--evidence-output", type=Path, default=DEFAULT_EVIDENCE_PATH)
    parser.add_argument("--reference-output", type=Path, default=DEFAULT_REFERENCE_OUTPUT_PATH)
    parser.add_argument("--check", action="store_true")
    return parser


def main() -> int:
    args = _parser().parse_args()
    try:
        bundle = generate(
            glb_path=args.glb,
            visual_manifest_path=args.visual_manifest,
            parameters_path=args.parameters,
            calibration_path=args.calibration,
            reference_source_path=args.reference_source,
            urdf_path=args.urdf_output,
            evidence_path=args.evidence_output,
            reference_output_path=args.reference_output,
            check=args.check,
        )
    except (GenerationError, OSError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    print(
        json.dumps(
            {
                "urdf_sha256": _sha256(bundle.urdf_bytes),
                "evidence_sha256": _sha256(bundle.evidence_bytes),
                "reference_urdf_sha256": _sha256(bundle.reference_urdf_bytes),
            },
            sort_keys=True,
        )
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
