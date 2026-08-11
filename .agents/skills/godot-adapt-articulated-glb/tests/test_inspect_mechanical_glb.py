from __future__ import annotations

import json
import struct
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SKILL_ROOT = Path(__file__).resolve().parents[1]
REPOSITORY_ROOT = Path(__file__).resolve().parents[4]
SCRIPT = SKILL_ROOT / "scripts" / "inspect_mechanical_glb.py"
REAL_GLB = REPOSITORY_ROOT / "godot" / "client" / "assets" / "visual" / "SY205_excavator_godot.glb"


def _glb(document: object, *, declared_length: int | None = None) -> bytes:
    payload = json.dumps(document, allow_nan=False, separators=(",", ":")).encode("utf-8")
    payload += b" " * ((-len(payload)) % 4)
    total_length = 20 + len(payload) if declared_length is None else declared_length
    return b"glTF" + struct.pack("<II", 2, total_length) + struct.pack(
        "<II", len(payload), 0x4E4F534A
    ) + payload


class MechanicalGlbInspectorTests(unittest.TestCase):
    def _run(self, path: Path, *extra_arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), str(path), *extra_arguments],
            capture_output=True,
            check=False,
            text=True,
        )

    def _write(self, directory: Path, name: str, data: bytes) -> Path:
        path = directory / name
        path.write_bytes(data)
        return path

    def test_real_asset_report_is_repeatable(self) -> None:
        first = self._run(REAL_GLB)
        second = self._run(REAL_GLB)
        self.assertEqual(first.returncode, 0, first.stdout)
        self.assertEqual(first.stderr, "")
        self.assertEqual(first.stdout, second.stdout)
        report = json.loads(first.stdout)
        self.assertEqual(
            report["file"]["sha256"],
            "cf95534b31bcc156980afefef0a9f273e5c6f727547b3db1e9062ca5619b495a",
        )
        self.assertEqual(report["document"]["counts"]["nodes"], 20)
        self.assertEqual(report["document"]["counts"]["meshes"], 11)
        self.assertEqual(report["document"]["counts"]["materials"], 9)
        self.assertEqual(report["document"]["counts"]["images"], 2)
        self.assertEqual(report["document"]["counts"]["skins"], 0)
        self.assertEqual(report["document"]["counts"]["animations"], 0)

    def test_unreadable_input_has_stable_error(self) -> None:
        result = self._run(REPOSITORY_ROOT / "does-not-exist.glb")
        self.assertEqual(result.returncode, 3)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "INPUT_UNREADABLE")
        self.assertEqual(result.stderr, "")

    def test_invalid_container_variants(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            cases = {
                "truncated.glb": b"glTF",
                "magic.glb": b"BAD!" + struct.pack("<II", 2, 12),
                "length.glb": _glb({"asset": {"version": "2.0"}}, declared_length=999),
            }
            for name, data in cases.items():
                with self.subTest(name=name):
                    result = self._run(self._write(directory, name, data))
                    self.assertEqual(result.returncode, 4)
                    self.assertEqual(
                        json.loads(result.stdout)["error"]["code"], "GLB_CONTAINER_INVALID"
                    )
                    self.assertEqual(result.stderr, "")

    def test_unaligned_chunks_are_rejected(self) -> None:
        unaligned_json = (
            b"glTF"
            + struct.pack("<II", 2, 22)
            + struct.pack("<II", 2, 0x4E4F534A)
            + b"{}"
        )
        aligned_json = json.dumps({"asset": {"version": "2.0"}}).encode("utf-8")
        aligned_json += b" " * ((-len(aligned_json)) % 4)
        unaligned_second = (
            b"glTF"
            + struct.pack("<II", 2, 20 + len(aligned_json) + 9)
            + struct.pack("<II", len(aligned_json), 0x4E4F534A)
            + aligned_json
            + struct.pack("<II", 1, 0x004E4942)
            + b"\x00"
        )
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            for name, data in {
                "json-unaligned.glb": unaligned_json,
                "bin-unaligned.glb": unaligned_second,
            }.items():
                with self.subTest(name=name):
                    result = self._run(self._write(directory, name, data))
                    self.assertEqual(result.returncode, 4)
                    self.assertEqual(
                        json.loads(result.stdout)["error"]["code"], "GLB_CONTAINER_INVALID"
                    )

    def test_invalid_json_and_root_are_distinct(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            directory = Path(temp_dir)
            invalid_payload = b"{]  "
            invalid_json = (
                b"glTF"
                + struct.pack("<II", 2, 20 + len(invalid_payload))
                + struct.pack("<II", len(invalid_payload), 0x4E4F534A)
                + invalid_payload
            )
            json_result = self._run(self._write(directory, "json.glb", invalid_json))
            root_result = self._run(self._write(directory, "root.glb", _glb([])))
            self.assertEqual(json_result.returncode, 5)
            self.assertEqual(json.loads(json_result.stdout)["error"]["code"], "GLB_JSON_INVALID")
            self.assertEqual(root_result.returncode, 6)
            self.assertEqual(json.loads(root_result.stdout)["error"]["code"], "GLTF_ROOT_INVALID")

    def test_bad_hierarchy_is_reported_without_losing_evidence(self) -> None:
        document = {
            "asset": {"version": "2.0"},
            "nodes": [{"children": [4], "name": "candidate"}],
            "scene": 0,
            "scenes": [{"nodes": [0]}],
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self._write(Path(temp_dir), "hierarchy.glb", _glb(document))
            result = self._run(path)
        self.assertEqual(result.returncode, 0)
        report = json.loads(result.stdout)
        self.assertTrue(report["ok"])
        self.assertIn("NODE_CHILD_OUT_OF_RANGE", [item["code"] for item in report["diagnostics"]])

    def test_cross_reference_faults_are_non_fatal_diagnostics(self) -> None:
        document = {
            "accessors": [{"bufferView": 9}],
            "animations": [
                {
                    "channels": [{"sampler": 8, "target": {"node": 8}}],
                    "samplers": [{"input": 8, "output": 8}],
                }
            ],
            "asset": {"version": "2.0"},
            "bufferViews": [{"buffer": 9}],
            "buffers": [{}],
            "images": [{"bufferView": 9}],
            "materials": [{"pbrMetallicRoughness": {"baseColorTexture": {"index": 9}}}],
            "meshes": [
                {
                    "primitives": [
                        {
                            "attributes": {"POSITION": 9},
                            "indices": 9,
                            "material": 9,
                            "targets": [{"POSITION": 9}],
                        }
                    ]
                }
            ],
            "nodes": [{"camera": 9, "mesh": 9, "skin": 9}],
            "scene": 9,
            "scenes": [{"nodes": [0]}],
            "skins": [{"inverseBindMatrices": 9, "joints": [9], "skeleton": 9}],
            "textures": [{"sampler": 9, "source": 9}],
        }
        with tempfile.TemporaryDirectory() as temp_dir:
            path = self._write(Path(temp_dir), "references.glb", _glb(document))
            result = self._run(path)
        self.assertEqual(result.returncode, 0)
        codes = {item["code"] for item in json.loads(result.stdout)["diagnostics"]}
        self.assertTrue(
            {
                "ACCESSOR_BUFFER_VIEW_OUT_OF_RANGE",
                "ANIMATION_INPUT_ACCESSOR_OUT_OF_RANGE",
                "ANIMATION_OUTPUT_ACCESSOR_OUT_OF_RANGE",
                "ANIMATION_SAMPLER_OUT_OF_RANGE",
                "ANIMATION_TARGET_NODE_OUT_OF_RANGE",
                "BUFFER_VIEW_BUFFER_OUT_OF_RANGE",
                "DEFAULT_SCENE_OUT_OF_RANGE",
                "IMAGE_BUFFER_VIEW_OUT_OF_RANGE",
                "MATERIAL_TEXTURE_OUT_OF_RANGE",
                "MESH_ATTRIBUTE_ACCESSOR_OUT_OF_RANGE",
                "MESH_INDICES_ACCESSOR_OUT_OF_RANGE",
                "MESH_MATERIAL_OUT_OF_RANGE",
                "MESH_TARGET_ACCESSOR_OUT_OF_RANGE",
                "NODE_CAMERA_OUT_OF_RANGE",
                "NODE_MESH_OUT_OF_RANGE",
                "NODE_SKIN_OUT_OF_RANGE",
                "SKIN_INVERSE_BIND_ACCESSOR_OUT_OF_RANGE",
                "SKIN_JOINT_NODE_OUT_OF_RANGE",
                "SKIN_SKELETON_NODE_OUT_OF_RANGE",
                "TEXTURE_IMAGE_OUT_OF_RANGE",
                "TEXTURE_SAMPLER_OUT_OF_RANGE",
            }.issubset(codes)
        )

    def test_usage_error_does_not_echo_absolute_argument(self) -> None:
        secret_path = str(REPOSITORY_ROOT / "private" / "unexpected.glb")
        result = self._run(REAL_GLB, secret_path)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(json.loads(result.stdout)["error"]["code"], "USAGE_ERROR")
        self.assertNotIn(secret_path, result.stdout)
        self.assertEqual(result.stderr, "")


if __name__ == "__main__":
    unittest.main()
