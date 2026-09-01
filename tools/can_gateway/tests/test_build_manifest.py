"""Focused tests for the release build manifest generator."""

from __future__ import annotations

import hashlib
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

TOOLS_DIR = Path(__file__).resolve().parents[2]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from build_manifest import (  # noqa: E402
    ManifestError,
    collect_artifact,
    create_manifest,
    read_source,
    validate_build_toolchain,
)


class BuildManifestTest(unittest.TestCase):
    def test_collects_raw_bytes_in_stable_relative_path_order(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "package"
            (root / "nested").mkdir(parents=True)
            (root / "z.bin").write_bytes(b"z\r\n")
            (root / "nested" / "a.bin").write_bytes(b"a\n")

            artifact = collect_artifact("windows", root)

            self.assertEqual(artifact["root"], ".")
            files = artifact["files"]
            self.assertEqual(
                [item["path"] for item in files],
                ["nested/a.bin", "z.bin"],
            )
            self.assertEqual(
                files[1]["sha256"], hashlib.sha256(b"z\r\n").hexdigest()
            )

    def test_output_is_excluded_and_rewritten_atomically(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp) / "package"
            root.mkdir()
            (root / "app.exe").write_bytes(b"first")
            output = root / "build-manifest.json"
            output.write_text("stale", encoding="utf-8")
            source = {
                "git_commit": "a" * 40,
                "git_tree_dirty": False,
                "software_version": "0.1.0",
            }
            build_toolchain = {
                "release_url": "https://example.invalid/v1.7",
                "tag": "v1.7",
                "release_commit": "1234567",
                "voxel_tools_version": "1.7",
                "godot_version": "4.7.2.stable.custom_build.ed1daf0bf",
                "engine_commit": "ed1daf0bf",
                "components": [
                    {
                        "component": component,
                        "filename": f"{component}.bin",
                        "binary_sha256": str(index) * 64,
                        "binary_size_bytes": index,
                        "archive_filename": f"{component}.zip",
                        "archive_sha256": str(index + 4) * 64,
                    }
                    for index, component in enumerate(
                        (
                            "windows_editor",
                            "windows_release_template",
                            "linux_editor",
                            "linux_release_template",
                        ),
                        start=1,
                    )
                ],
            }

            create_manifest(
                output,
                [("windows", root)],
                repo_root=Path(tmp),
                source=source,
                build_toolchain=build_toolchain,
                generated_at_utc="2026-08-31T00:00:00Z",
            )

            payload = json.loads(output.read_text(encoding="utf-8"))
            self.assertEqual(payload["source"], source)
            self.assertEqual(payload["build_toolchain"], build_toolchain)
            self.assertEqual(
                [item["path"] for item in payload["artifacts"][0]["files"]],
                ["app.exe"],
            )
            self.assertTrue(output.read_bytes().endswith(b"\n"))
            self.assertFalse(list(root.glob(".*.tmp")))

    def test_invalid_build_toolchain_is_rejected_by_direct_api(self) -> None:
        with self.assertRaises(ManifestError):
            validate_build_toolchain(
                {
                    "release_url": 1,
                    "tag": "v1.7",
                    "release_commit": "1234567",
                    "voxel_tools_version": "1.7",
                    "godot_version": "4.7.2",
                    "engine_commit": "ed1daf0bf",
                    "components": [],
                }
            )

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "app.exe").write_bytes(b"app")
            with self.assertRaises(ManifestError):
                create_manifest(
                    root / "build-manifest.json",
                    [("windows", root)],
                    source={"git_commit": "d" * 40},
                    build_toolchain={
                        "release_url": "https://example.invalid",
                        "tag": "v1.7",
                        "release_commit": "1234567",
                        "voxel_tools_version": "1.7",
                        "godot_version": "4.7.2",
                        "engine_commit": "ed1daf0bf",
                        "components": [],
                    },
                )

    def test_changed_artifact_changes_hash(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "gateway"
            target.write_bytes(b"one")
            first = collect_artifact("linux", root)["files"][0]["sha256"]
            target.write_bytes(b"two")
            second = collect_artifact("linux", root)["files"][0]["sha256"]
            self.assertNotEqual(first, second)

    def test_empty_root_and_duplicate_names_fail(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaises(ManifestError):
                collect_artifact("empty", root)
            (root / "app").write_bytes(b"ok")
            with self.assertRaises(ManifestError):
                create_manifest(
                    root / "manifest.json",
                    [("same", root), ("same", root)],
                    source={"git_commit": "b" * 40},
                )

    def test_read_source_reports_dirty_and_rejects_git_failure(self) -> None:
        commit = "c" * 40
        completed = [
            subprocess.CompletedProcess([], 0, stdout=f"{commit}\n", stderr=""),
            subprocess.CompletedProcess([], 0, stdout=" M file.txt\n", stderr=""),
        ]
        with patch("build_manifest.subprocess.run", side_effect=completed):
            source = read_source()
        self.assertEqual(source["git_commit"], commit)
        self.assertTrue(source["git_tree_dirty"])

        failed = subprocess.CompletedProcess([], 128, stdout="", stderr="not a repo")
        with (
            patch("build_manifest.subprocess.run", return_value=failed),
            self.assertRaises(ManifestError),
        ):
            read_source()

    @unittest.skipUnless(hasattr(Path, "symlink_to"), "symlink unsupported")
    def test_symlink_is_rejected_when_platform_allows_creation(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "target.bin"
            link = root / "link.bin"
            target.write_bytes(b"data")
            try:
                link.symlink_to(target)
            except OSError:
                self.skipTest("symlink creation is not permitted")
            with self.assertRaises(ManifestError):
                collect_artifact("package", root)


if __name__ == "__main__":
    unittest.main()
