"""Focused tests for the pinned Godot + Voxel Tools resolver."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from godot_voxel_toolchain import (  # noqa: E402
    DEFAULT_LOCK_PATH,
    ToolchainError,
    _linux_version_command,
    inject_release_templates,
    load_lock,
    resolve_root,
    stage_export_project,
    verify_component,
)


def _write_lock(path: Path, root: Path, binary: bytes = b"binary") -> dict[str, object]:
    digest = hashlib.sha256(binary).hexdigest()
    asset = {
        "filename": "godot.windows.editor.x86_64.exe",
        "archive_filename": "godot.windows.editor.x86_64.exe.zip",
        "archive_sha256": "1" * 64,
        "binary_sha256": digest,
        "binary_size_bytes": len(binary),
        "platform": "windows",
        "kind": "editor",
        "variant": "standard",
    }
    payload: dict[str, object] = {
        "schema_version": 1,
        "release": {
            "url": "https://example.invalid/v1.7",
            "download_base_url": "https://example.invalid/download/v1.7",
            "tag": "v1.7",
            "release_commit": "abc1234",
            "voxel_tools_version": "1.7",
            "godot_version": "4.7.2.stable.custom_build.ed1daf0bf",
            "engine_commit": "ed1daf0bf",
        },
        "default_root": str(root),
        "assets": {
            "windows_editor": asset,
            "windows_release_template": {
                **asset,
                "filename": "godot.windows.template_release.x86_64.exe",
                "archive_filename": "godot.windows.template_release.x86_64.exe.zip",
                "kind": "release_template",
            },
            "linux_editor": {
                **asset,
                "filename": "godot.linuxbsd.editor.x86_64",
                "archive_filename": "godot.linuxbsd.editor.x86_64.zip",
                "platform": "linux",
            },
            "linux_release_template": {
                **asset,
                "filename": "godot.linuxbsd.template_release.x86_64",
                "archive_filename": "godot.linuxbsd.template_release.x86_64.zip",
                "platform": "linux",
                "kind": "release_template",
            },
        },
    }
    path.write_text(json.dumps(payload), encoding="utf-8")
    return payload


class GodotVoxelToolchainTest(unittest.TestCase):
    def test_root_precedence_is_explicit_then_environment_then_default(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            base = Path(tmp)
            lock_path = base / "lock.json"
            lock = _write_lock(lock_path, base / "default")
            environment = {"GODOT_VOXEL_ROOT": str(base / "environment")}

            self.assertEqual(
                resolve_root(lock, base / "explicit", environment=environment),
                (base / "explicit").resolve(),
            )
            self.assertEqual(
                resolve_root(lock, environment=environment),
                (base / "environment").resolve(),
            )
            self.assertEqual(
                resolve_root(lock, environment={}), (base / "default").resolve()
            )

    def test_verify_reports_missing_hash_version_and_variant_failures(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lock_path = root / "lock.json"
            payload = _write_lock(lock_path, root)
            lock = load_lock(lock_path)
            expected_path = root / "godot.windows.editor.x86_64.exe"

            with self.assertRaisesRegex(ToolchainError, "COMPONENT_MISSING"):
                verify_component(lock, "windows_editor", root=root)

            expected_path.write_bytes(b"wrongs")
            with self.assertRaisesRegex(ToolchainError, "HASH_MISMATCH"):
                verify_component(lock, "windows_editor", root=root)

            expected_path.write_bytes(b"binary")
            with patch(
                "godot_voxel_toolchain._read_version", return_value="4.7.1.stable"
            ), self.assertRaisesRegex(ToolchainError, "VERSION_MISMATCH"):
                verify_component(lock, "windows_editor", root=root)

            with self.assertRaisesRegex(ToolchainError, "VARIANT_REJECTED"):
                verify_component(
                    lock,
                    "windows_editor",
                    root=root,
                    explicit_path=root / "godot.windows.editor.double.x86_64.exe",
                )

            self.assertEqual(payload["schema_version"], 1)

    def test_verify_accepts_matching_binary_and_version(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            lock_path = root / "lock.json"
            _write_lock(lock_path, root)
            binary = root / "godot.windows.editor.x86_64.exe"
            binary.write_bytes(b"binary")
            lock = load_lock(lock_path)
            with patch(
                "godot_voxel_toolchain._read_version",
                return_value="4.7.2.stable.custom_build.ed1daf0bf",
            ):
                verified = verify_component(lock, "windows_editor", root=root)
            self.assertEqual(verified["path"], str(binary.resolve()))
            self.assertEqual(verified["binary_sha256"], hashlib.sha256(b"binary").hexdigest())

    def test_stage_project_injects_release_templates_without_mutating_source(self) -> None:
        preset = """[preset.0]

name="ExcavatorSim"

[preset.0.options]

custom_template/debug="stale"
custom_template/release=""

[preset.1]

name="Linux"

[preset.1.options]

custom_template/debug="stale"
custom_template/release=""
"""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            destination = root / "staged"
            source.mkdir()
            (source / "project.godot").write_text("[application]\n", encoding="utf-8")
            source_preset = source / "export_presets.cfg"
            source_preset.write_text(preset, encoding="utf-8")
            (source / ".godot").mkdir()
            (source / ".godot" / "cache").write_text("ignored", encoding="utf-8")
            windows_template = root / "windows template.exe"
            linux_template = root / "linux template"

            stage_export_project(
                source, destination, windows_template, linux_template
            )

            self.assertEqual(source_preset.read_text(encoding="utf-8"), preset)
            staged = (destination / "export_presets.cfg").read_text(encoding="utf-8")
            self.assertIn(
                f'custom_template/release="{windows_template.resolve().as_posix()}"',
                staged,
            )
            self.assertIn(
                f'custom_template/release="{linux_template.resolve().as_posix()}"',
                staged,
            )
            self.assertEqual(staged.count('custom_template/debug=""'), 2)
            self.assertFalse((destination / ".godot").exists())

    def test_inject_rejects_missing_required_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            preset_path = Path(tmp) / "export_presets.cfg"
            preset_path.write_text("[preset.0]\nname=\"ExcavatorSim\"\n", encoding="utf-8")
            with self.assertRaisesRegex(ToolchainError, "PRESET_INVALID"):
                inject_release_templates(preset_path, Path("win"), Path("linux"))

    def test_lock_rejects_duplicate_keys(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "lock.json"
            path.write_text('{"schema_version":1,"schema_version":1}', encoding="utf-8")
            with self.assertRaisesRegex(ToolchainError, "duplicate key"):
                load_lock(path)

    def test_real_lock_is_complete_and_asset_order_is_not_significant(self) -> None:
        real_lock = load_lock(DEFAULT_LOCK_PATH)
        self.assertEqual(real_lock["release"]["engine_commit"], "ed1daf0bf")
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "lock.json"
            payload = _write_lock(path, root)
            assets = payload["assets"]
            assert isinstance(assets, dict)
            payload["assets"] = dict(reversed(tuple(assets.items())))
            path.write_text(json.dumps(payload), encoding="utf-8")
            self.assertEqual(set(load_lock(path)["assets"]), set(assets))

    def test_lock_rejects_missing_nested_fields(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            path = root / "lock.json"
            payload = _write_lock(path, root)
            release = payload["release"]
            assert isinstance(release, dict)
            del release["engine_commit"]
            path.write_text(json.dumps(payload), encoding="utf-8")
            with self.assertRaisesRegex(ToolchainError, "LOCK_INVALID"):
                load_lock(path)

    def test_linux_version_command_passes_path_as_positional_argument(self) -> None:
        path = Path("E:/toolchains/space and ' quote/godot.linuxbsd.editor.x86_64")
        with patch("godot_voxel_toolchain.os.name", "nt"):
            command = _linux_version_command(path)
        self.assertEqual(command[:4], ["wsl.exe", "--exec", "sh", "-c"])
        self.assertEqual(command[-1], str(path))
        self.assertIn('chmod u+x "$binary_path"', command[4])
        self.assertNotIn(str(path), command[4])

    def test_copy_failure_removes_partial_staging_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            destination = root / "staged"
            source.mkdir()
            (source / "project.godot").write_text("[application]\n", encoding="utf-8")

            def fail_copy(_source: Path, target: Path, **_kwargs: object) -> None:
                target.mkdir()
                (target / "partial").write_text("partial", encoding="utf-8")
                raise OSError("copy failed")

            with (
                patch("godot_voxel_toolchain.shutil.copytree", side_effect=fail_copy),
                self.assertRaisesRegex(ToolchainError, "STAGE_FAILED"),
            ):
                stage_export_project(source, destination, Path("win"), Path("linux"))
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    unittest.main()
