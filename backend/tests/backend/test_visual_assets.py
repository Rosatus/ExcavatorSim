from __future__ import annotations

import hashlib
import json
import shutil
from collections.abc import Callable
from pathlib import Path
from typing import Any

import pytest

from babylon_sim.paths import (
    VISUAL_ASSETS_ROOT,
    VISUAL_MODEL_MANIFEST_PATH,
    VISUAL_MODEL_SCHEMA_PATH,
)
from babylon_sim.visual_assets import (
    VISUAL_FRAME_NAMES,
    VisualAssetError,
    load_visual_model_manifest,
)


def _staged_manifest(tmp_path: Path) -> tuple[Path, Path, dict[str, Any]]:
    assets_root = tmp_path / "assets"
    assets_root.mkdir()
    for source in VISUAL_ASSETS_ROOT.glob("*.glb"):
        shutil.copyfile(source, assets_root / source.name)
    payload = json.loads(VISUAL_MODEL_MANIFEST_PATH.read_text(encoding="utf-8"))
    manifest_path = assets_root / "visual-model-v1.json"
    manifest_path.write_text(json.dumps(payload), encoding="utf-8")
    return manifest_path, assets_root, payload


def _write_manifest(path: Path, payload: dict[str, Any]) -> None:
    path.write_text(json.dumps(payload), encoding="utf-8")


def test_committed_visual_model_is_complete_and_allowlisted() -> None:
    manifest = load_visual_model_manifest()
    assert manifest.visual_model_version == "original-skin-v1"
    assert {entry.authoritative_frame for entry in manifest.entries} == VISUAL_FRAME_NAMES
    assert {entry.asset_id for entry in manifest.entries} == {
        "base",
        "upper-structure",
        "boom",
        "arm",
        "bucket",
    }
    assert manifest.asset("missing") is None
    for entry in manifest.entries:
        resolved = manifest.asset(entry.asset_id)
        assert resolved is not None
        _, path = resolved
        assert hashlib.sha256(path.read_bytes()).hexdigest() == entry.sha256


@pytest.mark.parametrize(
    "mutate",
    [
        lambda payload: payload.update({"unexpected": True}),
        lambda payload: payload["entries"][1].update(
            {"authoritative_frame": payload["entries"][0]["authoritative_frame"]}
        ),
        lambda payload: payload["entries"][0].update({"file": "../base.glb"}),
        lambda payload: payload["entries"][0].update({"scale": [1.0, 0.0, 1.0]}),
        lambda payload: payload["entries"][0]["expected_bounds_m"].update(
            {"min": [2.0, 0.0, 0.0], "max": [1.0, 1.0, 1.0]}
        ),
    ],
)
def test_manifest_rejects_invalid_shape_or_relationships(
    tmp_path: Path, mutate: Callable[[dict[str, Any]], None]
) -> None:
    manifest_path, assets_root, payload = _staged_manifest(tmp_path)
    mutate(payload)
    _write_manifest(manifest_path, payload)
    with pytest.raises(VisualAssetError):
        load_visual_model_manifest(
            manifest_path, assets_root=assets_root, schema_path=VISUAL_MODEL_SCHEMA_PATH
        )


def test_manifest_rejects_corrupt_or_digest_mismatched_glb(tmp_path: Path) -> None:
    manifest_path, assets_root, payload = _staged_manifest(tmp_path)
    (assets_root / "base.glb").write_bytes(b"not-a-glb")
    payload["entries"][0]["sha256"] = hashlib.sha256(b"not-a-glb").hexdigest()
    _write_manifest(manifest_path, payload)
    with pytest.raises(VisualAssetError, match="not a GLB"):
        load_visual_model_manifest(
            manifest_path, assets_root=assets_root, schema_path=VISUAL_MODEL_SCHEMA_PATH
        )

    shutil.copyfile(VISUAL_ASSETS_ROOT / "base.glb", assets_root / "base.glb")
    with pytest.raises(VisualAssetError, match="digest mismatch"):
        load_visual_model_manifest(
            manifest_path, assets_root=assets_root, schema_path=VISUAL_MODEL_SCHEMA_PATH
        )
