#!/usr/bin/env python3
"""Inspect GLB container and JSON evidence without inferring mechanics."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from collections.abc import Sequence
from pathlib import Path
from typing import Any, NoReturn

SCHEMA_VERSION = "mechanical-glb-inspection-v1"
JSON_CHUNK_TYPE = 0x4E4F534A


class InspectionFailure(Exception):
    def __init__(self, code: str, message: str, exit_code: int) -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.exit_code = exit_code


class JsonArgumentParser(argparse.ArgumentParser):
    def error(self, _message: str) -> NoReturn:
        _write_json(_error_report("USAGE_ERROR", "invalid command-line arguments"), pretty=False)
        raise SystemExit(2)


def _error_report(code: str, message: str) -> dict[str, Any]:
    return {
        "error": {"code": code, "message": message},
        "ok": False,
        "schema_version": SCHEMA_VERSION,
    }


def _write_json(report: dict[str, Any], *, pretty: bool) -> None:
    if pretty:
        rendered = json.dumps(report, allow_nan=False, ensure_ascii=False, indent=2, sort_keys=True)
    else:
        rendered = json.dumps(
            report,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    sys.stdout.write(rendered + "\n")


def _reject_json_constant(value: str) -> NoReturn:
    raise ValueError(f"non-standard JSON constant: {value}")


def _read_glb(path: Path) -> tuple[bytes, dict[str, Any], list[dict[str, Any]]]:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise InspectionFailure("INPUT_UNREADABLE", "input GLB cannot be read", 3) from exc

    if len(data) < 12:
        raise InspectionFailure("GLB_CONTAINER_INVALID", "GLB header is truncated", 4)

    magic, version, declared_length = struct.unpack_from("<4sII", data, 0)
    if magic != b"glTF":
        raise InspectionFailure("GLB_CONTAINER_INVALID", "GLB magic is invalid", 4)
    if version != 2:
        raise InspectionFailure("GLB_CONTAINER_INVALID", "only GLB version 2 is supported", 4)
    if declared_length != len(data):
        raise InspectionFailure(
            "GLB_CONTAINER_INVALID", "GLB declared length does not match input bytes", 4
        )

    chunks: list[dict[str, Any]] = []
    offset = 12
    while offset < declared_length:
        if declared_length - offset < 8:
            raise InspectionFailure("GLB_CONTAINER_INVALID", "GLB chunk header is truncated", 4)
        chunk_length, chunk_type = struct.unpack_from("<II", data, offset)
        if chunk_length % 4 != 0:
            raise InspectionFailure(
                "GLB_CONTAINER_INVALID", "GLB chunk length is not 4-byte aligned", 4
            )
        data_offset = offset + 8
        chunk_end = data_offset + chunk_length
        if chunk_end > declared_length:
            raise InspectionFailure("GLB_CONTAINER_INVALID", "GLB chunk payload is truncated", 4)
        chunks.append(
            {
                "data_offset": data_offset,
                "header_offset": offset,
                "index": len(chunks),
                "length": chunk_length,
                "type_fourcc": struct.pack("<I", chunk_type).decode("latin-1"),
                "type_u32": chunk_type,
            }
        )
        offset = chunk_end

    if not chunks or chunks[0]["type_u32"] != JSON_CHUNK_TYPE:
        raise InspectionFailure("GLB_CONTAINER_INVALID", "first GLB chunk must be JSON", 4)

    json_chunk = chunks[0]
    json_bytes = data[
        int(json_chunk["data_offset"]) : int(json_chunk["data_offset"])
        + int(json_chunk["length"])
    ].rstrip(b" \t\r\n\x00")
    try:
        decoded = json_bytes.decode("utf-8")
        document = json.loads(decoded, parse_constant=_reject_json_constant)
    except (UnicodeError, json.JSONDecodeError, ValueError) as exc:
        raise InspectionFailure("GLB_JSON_INVALID", "GLB JSON chunk is invalid", 5) from exc
    if not isinstance(document, dict):
        raise InspectionFailure("GLTF_ROOT_INVALID", "glTF JSON root must be an object", 6)
    return data, document, chunks


def _array(
    document: dict[str, Any], key: str, diagnostics: list[dict[str, Any]]
) -> list[Any]:
    value = document.get(key, [])
    if isinstance(value, list):
        return value
    diagnostics.append({"code": "DOCUMENT_FIELD_NOT_ARRAY", "field": key})
    return []


def _index(value: Any) -> int | None:
    if isinstance(value, int) and not isinstance(value, bool):
        return value
    return None


def _node_name(nodes: list[Any], index: int) -> str | None:
    if 0 <= index < len(nodes) and isinstance(nodes[index], dict):
        name = nodes[index].get("name")
        return name if isinstance(name, str) else None
    return None


def _hierarchy(
    scenes: list[Any], nodes: list[Any], diagnostics: list[dict[str, Any]]
) -> dict[str, Any]:
    parents: list[list[int]] = [[] for _ in nodes]
    children_by_node: list[list[int]] = [[] for _ in nodes]
    for node_index, raw_node in enumerate(nodes):
        if not isinstance(raw_node, dict):
            diagnostics.append({"code": "NODE_NOT_OBJECT", "node": node_index})
            continue
        raw_children = raw_node.get("children", [])
        if not isinstance(raw_children, list):
            diagnostics.append({"code": "NODE_CHILDREN_NOT_ARRAY", "node": node_index})
            continue
        for child_position, raw_child in enumerate(raw_children):
            child = _index(raw_child)
            if child is None or not 0 <= child < len(nodes):
                diagnostics.append(
                    {
                        "child": raw_child,
                        "child_position": child_position,
                        "code": "NODE_CHILD_OUT_OF_RANGE",
                        "node": node_index,
                    }
                )
                continue
            children_by_node[node_index].append(child)
            parents[child].append(node_index)

    paths: list[list[dict[str, Any]]] = [[] for _ in nodes]
    seen_paths: list[set[tuple[int, tuple[int, ...]]]] = [set() for _ in nodes]

    def visit(scene_index: int, node_index: int, chain: tuple[int, ...]) -> None:
        if node_index in chain:
            diagnostics.append(
                {"code": "NODE_GRAPH_CYCLE", "node": node_index, "scene": scene_index}
            )
            return
        next_chain = (*chain, node_index)
        identity = (scene_index, next_chain)
        if identity not in seen_paths[node_index]:
            seen_paths[node_index].add(identity)
            paths[node_index].append(
                {
                    "names": [_node_name(nodes, item) for item in next_chain],
                    "node_indices": list(next_chain),
                    "scene": scene_index,
                }
            )
        for child in children_by_node[node_index]:
            visit(scene_index, child, next_chain)

    scene_reports: list[dict[str, Any]] = []
    for scene_index, raw_scene in enumerate(scenes):
        if not isinstance(raw_scene, dict):
            diagnostics.append({"code": "SCENE_NOT_OBJECT", "scene": scene_index})
            scene_reports.append(
                {"extras": None, "index": scene_index, "name": None, "root_nodes": []}
            )
            continue
        raw_roots = raw_scene.get("nodes", [])
        roots: list[int] = []
        if not isinstance(raw_roots, list):
            diagnostics.append({"code": "SCENE_NODES_NOT_ARRAY", "scene": scene_index})
        else:
            for root_position, raw_root in enumerate(raw_roots):
                root = _index(raw_root)
                if root is None or not 0 <= root < len(nodes):
                    diagnostics.append(
                        {
                            "code": "SCENE_ROOT_OUT_OF_RANGE",
                            "root": raw_root,
                            "root_position": root_position,
                            "scene": scene_index,
                        }
                    )
                    continue
                roots.append(root)
                visit(scene_index, root, ())
        scene_reports.append(
            {
                "extras": raw_scene.get("extras"),
                "index": scene_index,
                "name": raw_scene.get("name") if isinstance(raw_scene.get("name"), str) else None,
                "root_nodes": roots,
            }
        )

    node_reports: list[dict[str, Any]] = []
    for node_index, raw_node in enumerate(nodes):
        node = raw_node if isinstance(raw_node, dict) else {}
        node_reports.append(
            {
                "camera": node.get("camera"),
                "children": children_by_node[node_index],
                "extras": node.get("extras"),
                "index": node_index,
                "mesh": node.get("mesh"),
                "name": node.get("name") if isinstance(node.get("name"), str) else None,
                "parents": parents[node_index],
                "paths": paths[node_index],
                "skin": node.get("skin"),
                "transform": {
                    "matrix": node.get("matrix"),
                    "rotation": node.get("rotation"),
                    "scale": node.get("scale"),
                    "translation": node.get("translation"),
                },
            }
        )
    return {"nodes": node_reports, "scenes": scene_reports}


def _mesh_reports(meshes: list[Any], diagnostics: list[dict[str, Any]]) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for mesh_index, raw_mesh in enumerate(meshes):
        if not isinstance(raw_mesh, dict):
            diagnostics.append({"code": "MESH_NOT_OBJECT", "mesh": mesh_index})
            reports.append(
                {"extras": None, "index": mesh_index, "name": None, "primitives": []}
            )
            continue
        raw_primitives = raw_mesh.get("primitives", [])
        primitive_reports: list[dict[str, Any]] = []
        if not isinstance(raw_primitives, list):
            diagnostics.append({"code": "MESH_PRIMITIVES_NOT_ARRAY", "mesh": mesh_index})
        else:
            for primitive_index, raw_primitive in enumerate(raw_primitives):
                if not isinstance(raw_primitive, dict):
                    diagnostics.append(
                        {
                            "code": "MESH_PRIMITIVE_NOT_OBJECT",
                            "mesh": mesh_index,
                            "primitive": primitive_index,
                        }
                    )
                    continue
                targets = raw_primitive.get("targets", [])
                primitive_reports.append(
                    {
                        "attributes": raw_primitive.get("attributes"),
                        "extras": raw_primitive.get("extras"),
                        "indices_accessor": raw_primitive.get("indices"),
                        "material": raw_primitive.get("material"),
                        "mode": raw_primitive.get("mode", 4),
                        "targets_count": len(targets) if isinstance(targets, list) else None,
                    }
                )
        reports.append(
            {
                "extras": raw_mesh.get("extras"),
                "index": mesh_index,
                "name": raw_mesh.get("name") if isinstance(raw_mesh.get("name"), str) else None,
                "primitives": primitive_reports,
            }
        )
    return reports


def _named_reports(
    items: list[Any], kind: str, diagnostics: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for item_index, raw_item in enumerate(items):
        if not isinstance(raw_item, dict):
            diagnostics.append({"code": f"{kind.upper()}_NOT_OBJECT", kind: item_index})
            reports.append({"extras": None, "index": item_index, "name": None})
            continue
        reports.append(
            {
                "extras": raw_item.get("extras"),
                "index": item_index,
                "name": raw_item.get("name") if isinstance(raw_item.get("name"), str) else None,
            }
        )
    return reports


def _image_reports(images: list[Any], diagnostics: list[dict[str, Any]]) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for image_index, raw_image in enumerate(images):
        if not isinstance(raw_image, dict):
            diagnostics.append({"code": "IMAGE_NOT_OBJECT", "image": image_index})
            raw_image = {}
        reports.append(
            {
                "buffer_view": raw_image.get("bufferView"),
                "declared_embedded": raw_image.get("bufferView") is not None,
                "extras": raw_image.get("extras"),
                "index": image_index,
                "mime_type": raw_image.get("mimeType"),
                "name": raw_image.get("name") if isinstance(raw_image.get("name"), str) else None,
                "uri": raw_image.get("uri"),
            }
        )
    return reports


def _skin_reports(skins: list[Any], diagnostics: list[dict[str, Any]]) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for skin_index, raw_skin in enumerate(skins):
        if not isinstance(raw_skin, dict):
            diagnostics.append({"code": "SKIN_NOT_OBJECT", "skin": skin_index})
            raw_skin = {}
        joints = raw_skin.get("joints", [])
        reports.append(
            {
                "extras": raw_skin.get("extras"),
                "index": skin_index,
                "inverse_bind_matrices_accessor": raw_skin.get("inverseBindMatrices"),
                "joints": joints if isinstance(joints, list) else None,
                "name": raw_skin.get("name") if isinstance(raw_skin.get("name"), str) else None,
                "skeleton": raw_skin.get("skeleton"),
            }
        )
    return reports


def _animation_reports(
    animations: list[Any], diagnostics: list[dict[str, Any]]
) -> list[dict[str, Any]]:
    reports: list[dict[str, Any]] = []
    for animation_index, raw_animation in enumerate(animations):
        if not isinstance(raw_animation, dict):
            diagnostics.append({"animation": animation_index, "code": "ANIMATION_NOT_OBJECT"})
            raw_animation = {}
        raw_channels = raw_animation.get("channels", [])
        channels: list[dict[str, Any]] = []
        if isinstance(raw_channels, list):
            for channel_index, raw_channel in enumerate(raw_channels):
                if not isinstance(raw_channel, dict):
                    diagnostics.append(
                        {
                            "animation": animation_index,
                            "channel": channel_index,
                            "code": "ANIMATION_CHANNEL_NOT_OBJECT",
                        }
                    )
                    continue
                target = raw_channel.get("target", {})
                if not isinstance(target, dict):
                    target = {}
                channels.append(
                    {
                        "sampler": raw_channel.get("sampler"),
                        "target_node": target.get("node"),
                        "target_path": target.get("path"),
                    }
                )
        else:
            diagnostics.append(
                {"animation": animation_index, "code": "ANIMATION_CHANNELS_NOT_ARRAY"}
            )
        samplers = raw_animation.get("samplers", [])
        reports.append(
            {
                "channels": channels,
                "extras": raw_animation.get("extras"),
                "index": animation_index,
                "name": raw_animation.get("name")
                if isinstance(raw_animation.get("name"), str)
                else None,
                "samplers_count": len(samplers) if isinstance(samplers, list) else None,
            }
        )
    return reports


def _validate_reference(
    diagnostics: list[dict[str, Any]],
    *,
    code: str,
    value: Any,
    limit: int,
    context: dict[str, Any],
) -> None:
    if value is None:
        return
    reference = _index(value)
    if reference is None or not 0 <= reference < limit:
        diagnostics.append({"code": code, **context, "reference": value})


def _validate_texture_info(
    value: Any,
    *,
    diagnostics: list[dict[str, Any]],
    material_index: int,
    slot: str,
    texture_count: int,
) -> None:
    if value is None:
        return
    if not isinstance(value, dict):
        diagnostics.append(
            {"code": "MATERIAL_TEXTURE_INFO_NOT_OBJECT", "material": material_index, "slot": slot}
        )
        return
    _validate_reference(
        diagnostics,
        code="MATERIAL_TEXTURE_OUT_OF_RANGE",
        value=value.get("index"),
        limit=texture_count,
        context={"material": material_index, "slot": slot},
    )


def _validate_cross_references(
    document: dict[str, Any],
    collections: dict[str, list[Any]],
    diagnostics: list[dict[str, Any]],
) -> None:
    _validate_reference(
        diagnostics,
        code="DEFAULT_SCENE_OUT_OF_RANGE",
        value=document.get("scene"),
        limit=len(collections["scenes"]),
        context={},
    )

    for node_index, raw_node in enumerate(collections["nodes"]):
        if not isinstance(raw_node, dict):
            continue
        for field, target in (("mesh", "meshes"), ("skin", "skins"), ("camera", "cameras")):
            _validate_reference(
                diagnostics,
                code=f"NODE_{field.upper()}_OUT_OF_RANGE",
                value=raw_node.get(field),
                limit=len(collections[target]),
                context={"node": node_index},
            )

    for mesh_index, raw_mesh in enumerate(collections["meshes"]):
        if not isinstance(raw_mesh, dict) or not isinstance(raw_mesh.get("primitives", []), list):
            continue
        for primitive_index, raw_primitive in enumerate(raw_mesh.get("primitives", [])):
            if not isinstance(raw_primitive, dict):
                continue
            context = {"mesh": mesh_index, "primitive": primitive_index}
            _validate_reference(
                diagnostics,
                code="MESH_INDICES_ACCESSOR_OUT_OF_RANGE",
                value=raw_primitive.get("indices"),
                limit=len(collections["accessors"]),
                context=context,
            )
            _validate_reference(
                diagnostics,
                code="MESH_MATERIAL_OUT_OF_RANGE",
                value=raw_primitive.get("material"),
                limit=len(collections["materials"]),
                context=context,
            )
            attributes = raw_primitive.get("attributes", {})
            if isinstance(attributes, dict):
                for semantic in sorted(attributes):
                    _validate_reference(
                        diagnostics,
                        code="MESH_ATTRIBUTE_ACCESSOR_OUT_OF_RANGE",
                        value=attributes[semantic],
                        limit=len(collections["accessors"]),
                        context={**context, "semantic": semantic},
                    )
            targets = raw_primitive.get("targets", [])
            if isinstance(targets, list):
                for target_index, target in enumerate(targets):
                    if not isinstance(target, dict):
                        continue
                    for semantic in sorted(target):
                        _validate_reference(
                            diagnostics,
                            code="MESH_TARGET_ACCESSOR_OUT_OF_RANGE",
                            value=target[semantic],
                            limit=len(collections["accessors"]),
                            context={**context, "semantic": semantic, "target": target_index},
                        )

    for material_index, raw_material in enumerate(collections["materials"]):
        if not isinstance(raw_material, dict):
            continue
        pbr = raw_material.get("pbrMetallicRoughness", {})
        if isinstance(pbr, dict):
            _validate_texture_info(
                pbr.get("baseColorTexture"),
                diagnostics=diagnostics,
                material_index=material_index,
                slot="baseColorTexture",
                texture_count=len(collections["textures"]),
            )
            _validate_texture_info(
                pbr.get("metallicRoughnessTexture"),
                diagnostics=diagnostics,
                material_index=material_index,
                slot="metallicRoughnessTexture",
                texture_count=len(collections["textures"]),
            )
        for slot in ("normalTexture", "occlusionTexture", "emissiveTexture"):
            _validate_texture_info(
                raw_material.get(slot),
                diagnostics=diagnostics,
                material_index=material_index,
                slot=slot,
                texture_count=len(collections["textures"]),
            )

    for texture_index, raw_texture in enumerate(collections["textures"]):
        if not isinstance(raw_texture, dict):
            continue
        _validate_reference(
            diagnostics,
            code="TEXTURE_IMAGE_OUT_OF_RANGE",
            value=raw_texture.get("source"),
            limit=len(collections["images"]),
            context={"texture": texture_index},
        )
        _validate_reference(
            diagnostics,
            code="TEXTURE_SAMPLER_OUT_OF_RANGE",
            value=raw_texture.get("sampler"),
            limit=len(collections["samplers"]),
            context={"texture": texture_index},
        )

    for image_index, raw_image in enumerate(collections["images"]):
        if isinstance(raw_image, dict):
            _validate_reference(
                diagnostics,
                code="IMAGE_BUFFER_VIEW_OUT_OF_RANGE",
                value=raw_image.get("bufferView"),
                limit=len(collections["bufferViews"]),
                context={"image": image_index},
            )

    for skin_index, raw_skin in enumerate(collections["skins"]):
        if not isinstance(raw_skin, dict):
            continue
        _validate_reference(
            diagnostics,
            code="SKIN_INVERSE_BIND_ACCESSOR_OUT_OF_RANGE",
            value=raw_skin.get("inverseBindMatrices"),
            limit=len(collections["accessors"]),
            context={"skin": skin_index},
        )
        _validate_reference(
            diagnostics,
            code="SKIN_SKELETON_NODE_OUT_OF_RANGE",
            value=raw_skin.get("skeleton"),
            limit=len(collections["nodes"]),
            context={"skin": skin_index},
        )
        joints = raw_skin.get("joints", [])
        if isinstance(joints, list):
            for joint_position, joint in enumerate(joints):
                _validate_reference(
                    diagnostics,
                    code="SKIN_JOINT_NODE_OUT_OF_RANGE",
                    value=joint,
                    limit=len(collections["nodes"]),
                    context={"joint_position": joint_position, "skin": skin_index},
                )

    for animation_index, raw_animation in enumerate(collections["animations"]):
        if not isinstance(raw_animation, dict):
            continue
        samplers = raw_animation.get("samplers", [])
        if not isinstance(samplers, list):
            samplers = []
        for sampler_index, sampler in enumerate(samplers):
            if not isinstance(sampler, dict):
                continue
            for field in ("input", "output"):
                _validate_reference(
                    diagnostics,
                    code=f"ANIMATION_{field.upper()}_ACCESSOR_OUT_OF_RANGE",
                    value=sampler.get(field),
                    limit=len(collections["accessors"]),
                    context={"animation": animation_index, "sampler": sampler_index},
                )
        channels = raw_animation.get("channels", [])
        if not isinstance(channels, list):
            continue
        for channel_index, channel in enumerate(channels):
            if not isinstance(channel, dict):
                continue
            context = {"animation": animation_index, "channel": channel_index}
            _validate_reference(
                diagnostics,
                code="ANIMATION_SAMPLER_OUT_OF_RANGE",
                value=channel.get("sampler"),
                limit=len(samplers),
                context=context,
            )
            target = channel.get("target", {})
            if isinstance(target, dict):
                _validate_reference(
                    diagnostics,
                    code="ANIMATION_TARGET_NODE_OUT_OF_RANGE",
                    value=target.get("node"),
                    limit=len(collections["nodes"]),
                    context=context,
                )

    for view_index, raw_view in enumerate(collections["bufferViews"]):
        if isinstance(raw_view, dict):
            _validate_reference(
                diagnostics,
                code="BUFFER_VIEW_BUFFER_OUT_OF_RANGE",
                value=raw_view.get("buffer"),
                limit=len(collections["buffers"]),
                context={"buffer_view": view_index},
            )

    for accessor_index, raw_accessor in enumerate(collections["accessors"]):
        if isinstance(raw_accessor, dict):
            _validate_reference(
                diagnostics,
                code="ACCESSOR_BUFFER_VIEW_OUT_OF_RANGE",
                value=raw_accessor.get("bufferView"),
                limit=len(collections["bufferViews"]),
                context={"accessor": accessor_index},
            )


def inspect(path: Path) -> dict[str, Any]:
    data, document, chunks = _read_glb(path)
    diagnostics: list[dict[str, Any]] = []
    collection_names = (
        "scenes",
        "nodes",
        "meshes",
        "materials",
        "images",
        "textures",
        "skins",
        "animations",
        "cameras",
        "buffers",
        "bufferViews",
        "accessors",
        "samplers",
    )
    collections = {name: _array(document, name, diagnostics) for name in collection_names}
    raw_asset = document.get("asset")
    asset: dict[str, Any] = raw_asset if isinstance(raw_asset, dict) else {}
    if not asset:
        diagnostics.append({"code": "ASSET_METADATA_MISSING"})
    if not collections["scenes"]:
        diagnostics.append({"code": "SCENES_EMPTY"})
    _validate_cross_references(document, collections, diagnostics)
    hierarchy = _hierarchy(collections["scenes"], collections["nodes"], diagnostics)
    resources = {
        "animations": _animation_reports(collections["animations"], diagnostics),
        "images": _image_reports(collections["images"], diagnostics),
        "materials": _named_reports(collections["materials"], "material", diagnostics),
        "meshes": _mesh_reports(collections["meshes"], diagnostics),
        "skins": _skin_reports(collections["skins"], diagnostics),
    }
    return {
        "container": {
            "chunks": chunks,
            "declared_length": len(data),
            "magic": "glTF",
            "version": 2,
        },
        "diagnostics": diagnostics,
        "document": {
            "asset": {
                "copyright": asset.get("copyright"),
                "generator": asset.get("generator"),
                "min_version": asset.get("minVersion"),
                "version": asset.get("version"),
            },
            "counts": {
                "accessors": len(collections["accessors"]),
                "animations": len(collections["animations"]),
                "buffer_views": len(collections["bufferViews"]),
                "buffers": len(collections["buffers"]),
                "cameras": len(collections["cameras"]),
                "images": len(collections["images"]),
                "materials": len(collections["materials"]),
                "meshes": len(collections["meshes"]),
                "nodes": len(collections["nodes"]),
                "scenes": len(collections["scenes"]),
                "skins": len(collections["skins"]),
                "textures": len(collections["textures"]),
                "samplers": len(collections["samplers"]),
            },
            "default_scene": document.get("scene"),
            "extensions_required": document.get("extensionsRequired", []),
            "extensions_used": document.get("extensionsUsed", []),
        },
        "file": {"bytes": len(data), "sha256": hashlib.sha256(data).hexdigest()},
        "hierarchy": hierarchy,
        "ok": True,
        "resources": resources,
        "schema_version": SCHEMA_VERSION,
    }


def _parser() -> JsonArgumentParser:
    parser = JsonArgumentParser(description=__doc__)
    parser.add_argument("path", type=Path, help="GLB file to inspect")
    parser.add_argument("--pretty", action="store_true", help="pretty-print stable JSON")
    return parser


def main(argv: Sequence[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        report = inspect(args.path)
    except InspectionFailure as exc:
        _write_json(_error_report(exc.code, exc.message), pretty=args.pretty)
        return exc.exit_code
    _write_json(report, pretty=args.pretty)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
