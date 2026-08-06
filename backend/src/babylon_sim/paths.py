"""Project resource locations resolved without sibling-repository dependencies."""

from __future__ import annotations

from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parents[3]
ASSETS_ROOT = PROJECT_ROOT / "assets"
URDF_PATH = ASSETS_ROOT / "model" / "kinematic_excavator.urdf"
CALIBRATION_PATH = ASSETS_ROOT / "calibration" / "m1_provisional_calibration.json"
VISUAL_ASSETS_ROOT = ASSETS_ROOT / "visual" / "original"
VISUAL_MODEL_MANIFEST_PATH = VISUAL_ASSETS_ROOT / "visual-model-v1.json"
VISUAL_MODEL_SCHEMA_PATH = ASSETS_ROOT / "visual" / "visual-model-v1.schema.json"
PROTOCOL_SCHEMA_PATH = PROJECT_ROOT / "protocol" / "babylon-sim-v3.schema.json"
TERRAIN_SPEC_SCHEMA_PATH = PROJECT_ROOT / "protocol" / "terrain-spec-v1.schema.json"
VERSION_MANIFEST_PATH = PROJECT_ROOT / "protocol" / "version-manifest.json"
FRONTEND_DIST_PATH = PROJECT_ROOT / "godot" / "dist"
