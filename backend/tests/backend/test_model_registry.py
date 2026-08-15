from __future__ import annotations

import json

import pytest

from babylon_sim.model_registry import ModelRegistryError, load_model_registry
from babylon_sim.session_manager import ModelSelectionError, RuntimeSessionManager


def test_registry_resolves_two_reviewed_models_with_sy205_default() -> None:
    registry = load_model_registry()
    assert registry.default_model_id == "sy205"
    assert registry.model_ids == ("sy205", "sy135")
    assert registry.resolve().model_version == "sy205-glb-urdf-v4"
    assert registry.resolve("sy135").model_version == "sy135-reference-urdf-v1"
    with pytest.raises(ModelRegistryError) as error:
        registry.resolve("unknown")
    assert error.value.code == "unknown_model"


def test_backend_registry_and_godot_catalog_agree() -> None:
    registry = load_model_registry()
    catalog_path = (
        next(iter(registry.models.values())).visual_manifest_path.parents[1]
        / "models"
        / "model_catalog.json"
    )
    catalog = json.loads(catalog_path.read_text(encoding="utf-8"))
    assert catalog["default_model_id"] == registry.default_model_id
    by_id = {item["model_id"]: item for item in catalog["models"]}
    for model_id, descriptor in registry.models.items():
        item = by_id[model_id]
        assert item["model_version"] == descriptor.model_version
        assert item["visual_model_version"] == descriptor.visual_model_version
        assert item["glb_path"] == descriptor.godot_glb_resource
        assert item["manifest_path"] == descriptor.visual_manifest_resource
        assert item["parity_fixture_path"] == descriptor.parity_fixture_resource


def test_manager_switches_only_after_established_sessions_leave() -> None:
    manager = RuntimeSessionManager(model_id="sy205", profile="motion-only")
    manager.start()
    try:
        first = manager.acquire("session-a", "sy205")
        first_epoch = first.stream_epoch
        with pytest.raises(ModelSelectionError) as error:
            manager.acquire("session-b", "sy135")
        assert error.value.code == "model_switch_busy"
        assert manager.model_id == "sy205"

        manager.release("session-a")
        second = manager.acquire("session-b", "sy135")
        assert second is not first
        assert manager.model_id == "sy135"
        assert second.model.model_version == "sy135-reference-urdf-v1"
        assert second.stream_epoch != first_epoch
        assert second.model.urdf_path.name == "sy135_reference.urdf"
        manager.release("session-b")

        third = manager.acquire("session-c", "sy205")
        assert third is not second
        assert manager.model_id == "sy205"
        manager.release("session-c")
    finally:
        manager.stop()


def test_legacy_replay_uses_selected_model_identity() -> None:
    manager = RuntimeSessionManager(model_id="sy135", profile="legacy")
    try:
        assert manager.runtime.replay is not None
        assert manager.runtime.replay.replay_model.model_version == "sy135-reference-urdf-v1"
    finally:
        manager.stop()
