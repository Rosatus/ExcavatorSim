"""Verify the committed extraction and derivation provenance manifest."""

from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path, PurePosixPath
from typing import Any

from babylon_sim.constants import MODEL_VERSION
from babylon_sim.visual_assets import VisualAssetError, load_visual_model_manifest

ROOT = Path(__file__).resolve().parents[2]
MANIFEST_PATH = ROOT / "assets/provenance.json"
VISUAL_PROVENANCE_PATH = ROOT / "assets/visual/original/visual-provenance.json"
EXPECTED_DERIVATIONS = {
    "backend/src/babylon_sim/constants.py",
    "backend/src/babylon_sim/state.py",
    "backend/src/babylon_sim/model.py",
    "backend/src/babylon_sim/calibration.py",
    "backend/src/babylon_sim/control.py",
    "backend/src/babylon_sim/input_router.py",
    "backend/src/babylon_sim/simulation.py",
    "backend/tests/backend/test_state.py",
    "backend/tests/backend/test_model.py",
    "backend/tests/backend/test_calibration.py",
    "backend/tests/backend/test_control.py",
    "backend/tests/backend/test_input_router.py",
    "backend/tests/backend/test_simulation.py",
}
EXPECTED_VERBATIM = {
    "assets/model/library/sy135_reference.urdf",
    "assets/calibration/m1_provisional_calibration.json",
    "assets/licenses/KinematicSim-AGPL-3.0.txt",
}
EXPECTED_GENERATED = {
    "assets/model/kinematic_excavator.urdf",
    "backend/tests/fixtures/frame-parity/baseline.json",
    "godot/client/tests/fixtures/sy135_frame_parity_cases.json",
}
HEX_40 = re.compile(r"^[0-9a-f]{40}$")
HEX_64 = re.compile(r"^[0-9a-f]{64}$")


def _sha256(path: Path) -> str:
    canonical = path.read_bytes().replace(b"\r\n", b"\n")
    return hashlib.sha256(canonical).hexdigest()


def _raw_sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _mapping(value: object, label: str, errors: list[str]) -> dict[str, Any]:
    if not isinstance(value, dict):
        errors.append(f"{label} must be an object")
        return {}
    return value


def _target_destination(value: str) -> str:
    """Map BabylonSim's historical root-relative paths into backend/ on import."""

    if value.startswith("src/") or value.startswith("tests/"):
        return f"backend/{value}"
    return value


def _safe_destination(value: object, label: str, errors: list[str]) -> str | None:
    if not isinstance(value, str) or not value:
        errors.append(f"{label} must be a non-empty string")
        return None
    path = PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or "\\" in value:
        errors.append(f"{label} must be a normalized repository-relative POSIX path")
        return None
    mapped = _target_destination(value)
    resolved = (ROOT / Path(*PurePosixPath(mapped).parts)).resolve()
    try:
        resolved.relative_to(ROOT)
    except ValueError:
        errors.append(f"{label} escapes the repository")
        return None
    if not resolved.is_file():
        errors.append(f"{label} does not exist: {mapped}")
    return mapped


def _verify_hash(
    item: dict[str, Any], label: str, destination: str | None, errors: list[str]
) -> None:
    expected = item.get("destination_sha256")
    if not isinstance(expected, str) or HEX_64.fullmatch(expected) is None:
        errors.append(f"{label}.destination_sha256 must be 64 lowercase hex characters")
        return
    if destination is not None and (ROOT / destination).is_file():
        actual = _sha256(ROOT / destination)
        if actual != expected:
            errors.append(f"{destination}: SHA-256 mismatch ({actual} != {expected})")


def _verify_repository_file(item: object, label: str, errors: list[str]) -> str | None:
    value = _mapping(item, label, errors)
    path = _safe_destination(value.get("path"), f"{label}.path", errors)
    expected = value.get("sha256")
    if not isinstance(expected, str) or HEX_64.fullmatch(expected) is None:
        errors.append(f"{label}.sha256 must be 64 lowercase hex characters")
        return path
    hash_mode = value.get("hash_mode", "text-crlf-to-lf")
    if hash_mode not in {"raw", "text-crlf-to-lf"}:
        errors.append(f"{label}.hash_mode must be raw or text-crlf-to-lf")
        return path
    if path is not None and (ROOT / path).is_file():
        actual = _raw_sha256(ROOT / path) if hash_mode == "raw" else _sha256(ROOT / path)
        if actual != expected:
            errors.append(f"{path}: SHA-256 mismatch ({actual} != {expected})")
    return path


def _verify_source(
    source: object,
    label: str,
    baseline_repository: object,
    baseline_commit: object,
    errors: list[str],
) -> None:
    value = _mapping(source, label, errors)
    if value.get("repository") != baseline_repository:
        errors.append(f"{label}.repository does not match source_baseline")
    if value.get("commit") != baseline_commit:
        errors.append(f"{label}.commit does not match source_baseline")
    path = value.get("path")
    if (
        not isinstance(path, str)
        or not path
        or Path(path).is_absolute()
        or ".." in Path(path).parts
    ):
        errors.append(f"{label}.path must be a source repository-relative path")
    blob = value.get("blob")
    if not isinstance(blob, str) or HEX_40.fullmatch(blob) is None:
        errors.append(f"{label}.blob must be 40 lowercase hex characters")
    symbols = value.get("symbols")
    if not isinstance(symbols, list) or not symbols:
        errors.append(f"{label}.symbols must contain at least one symbol/range")
    else:
        for index, symbol in enumerate(symbols):
            symbol_value = _mapping(symbol, f"{label}.symbols[{index}]", errors)
            if not isinstance(symbol_value.get("name"), str) or not symbol_value.get("name"):
                errors.append(f"{label}.symbols[{index}].name is required")
            if not isinstance(symbol_value.get("lines"), str) or not symbol_value.get("lines"):
                errors.append(f"{label}.symbols[{index}].lines is required")


def _verify_visual_assets(errors: list[str]) -> None:
    try:
        manifest = load_visual_model_manifest()
    except VisualAssetError as exc:
        errors.append(f"visual model manifest failed validation: {exc}")
        return
    try:
        provenance = json.loads(VISUAL_PROVENANCE_PATH.read_text(encoding="utf-8"))
        inventory = json.loads(
            (ROOT / "assets/visual/original/source-sha256.json").read_text(encoding="utf-8")
        )
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"cannot read visual provenance evidence: {exc}")
        return
    visual = _mapping(provenance, "visual_provenance", errors)
    if visual.get("schema_version") != 1:
        errors.append("visual_provenance.schema_version must equal 1")
    expected_paths = {
        "rights_record": "assets/visual/original/SOURCE-RIGHTS.md",
        "source_inventory": "assets/visual/original/source-sha256.json",
        "conversion_record": "assets/visual/original/CONVERSION.md",
        "conversion_script": "backend/scripts/convert_original_visual.py",
        "manifest": "assets/visual/original/visual-model-v1.json",
    }
    for field, expected in expected_paths.items():
        if visual.get(field) != expected or not (ROOT / expected).is_file():
            errors.append(f"visual_provenance.{field} must reference {expected}")
    if visual.get("rights_basis") != "user-confirmed-copy-modify-use-and-distribution-2026-07-29":
        errors.append("visual_provenance.rights_basis does not match the approved record")

    source_inventory = _mapping(inventory, "visual_source_inventory", errors)
    if source_inventory.get("hash_algorithm") != "sha256-raw-bytes":
        errors.append("visual source inventory must use sha256-raw-bytes")
    source_files = source_inventory.get("files")
    if not isinstance(source_files, list) or len(source_files) != 7:
        errors.append("visual source inventory must contain exactly seven files")
        source_files = []
    source_hashes: dict[str, str] = {}
    for index, raw_file in enumerate(source_files):
        item = _mapping(raw_file, f"visual_source_inventory.files[{index}]", errors)
        source_path = item.get("path")
        source_hash = item.get("sha256")
        if not isinstance(source_path, str) or not source_path:
            errors.append(f"visual_source_inventory.files[{index}].path is required")
            continue
        if not isinstance(source_hash, str) or HEX_64.fullmatch(source_hash) is None:
            errors.append(f"visual_source_inventory.files[{index}].sha256 is invalid")
            continue
        source_hashes[source_path] = source_hash

    outputs = visual.get("outputs")
    if not isinstance(outputs, list) or len(outputs) != 5:
        errors.append("visual_provenance.outputs must contain exactly five entries")
        outputs = []
    manifest_by_destination = {
        f"assets/visual/original/{entry.filename}": entry for entry in manifest.entries
    }
    seen_destinations: set[str] = set()
    for index, raw_output in enumerate(outputs):
        item = _mapping(raw_output, f"visual_provenance.outputs[{index}]", errors)
        destination = item.get("destination_path")
        source_path = item.get("source_path")
        if not isinstance(destination, str) or destination not in manifest_by_destination:
            errors.append(f"visual_provenance.outputs[{index}].destination_path is unexpected")
            continue
        if destination in seen_destinations:
            errors.append(f"duplicate visual destination: {destination}")
        seen_destinations.add(destination)
        destination_path = ROOT / destination
        destination_hash = item.get("destination_sha256")
        if destination_hash != manifest_by_destination[destination].sha256:
            errors.append(f"{destination}: provenance and visual manifest hashes differ")
        if not destination_path.is_file() or _raw_sha256(destination_path) != destination_hash:
            errors.append(f"{destination}: raw SHA-256 mismatch")
        if not isinstance(source_path, str) or source_hashes.get(source_path) != item.get(
            "source_sha256"
        ):
            errors.append(f"{destination}: source inventory relationship is invalid")
        if item.get("relationship") != "format-converted-per-link-visual":
            errors.append(f"{destination}: visual relationship is invalid")
    if seen_destinations != set(manifest_by_destination):
        errors.append("visual provenance destinations do not match the runtime manifest")

    notice_text = (ROOT / "NOTICE.md").read_text(encoding="utf-8")
    if "assets/visual/original/SOURCE-RIGHTS.md" not in notice_text:
        errors.append("NOTICE.md does not reference the visual rights record")


def _verify_user_supplied_assets(root: dict[str, Any], errors: list[str]) -> None:
    raw_assets = root.get("user_supplied_assets", [])
    if not isinstance(raw_assets, list):
        errors.append("user_supplied_assets must be an array")
        return
    for index, raw_asset in enumerate(raw_assets):
        label = f"user_supplied_assets[{index}]"
        asset = _mapping(raw_asset, label, errors)
        source = asset.get("source_path")
        destination = _safe_destination(asset.get("destination_path"), label, errors)
        digest = asset.get("sha256")
        if not isinstance(source, str) or not source:
            errors.append(f"{label}.source_path is required")
        if not isinstance(digest, str) or HEX_64.fullmatch(digest) is None:
            errors.append(f"{label}.sha256 must be 64 lowercase hex characters")
        elif (
            destination is not None
            and (ROOT / destination).is_file()
            and _raw_sha256(ROOT / destination) != digest
        ):
            errors.append(f"{destination}: user-supplied SHA-256 mismatch")
        byte_size = asset.get("byte_size")
        if not isinstance(byte_size, int) or byte_size <= 0:
            errors.append(f"{label}.byte_size must be positive")
        elif destination is not None and (ROOT / destination).stat().st_size != byte_size:
            errors.append(f"{destination}: user-supplied byte size mismatch")
        for field in ("hash_mode", "relationship", "imported_at"):
            if not isinstance(asset.get(field), str) or not asset.get(field):
                errors.append(f"{label}.{field} is required")


def verify() -> list[str]:
    errors: list[str] = []
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return [f"cannot read {MANIFEST_PATH.relative_to(ROOT)}: {exc}"]
    root = _mapping(manifest, "manifest", errors)
    _verify_user_supplied_assets(root, errors)
    if root.get("schema_version") != 1:
        errors.append("schema_version must equal 1")
    if root.get("hash_canonicalization") != "text-crlf-to-lf":
        errors.append("hash_canonicalization must equal text-crlf-to-lf")
    baseline = _mapping(root.get("source_baseline"), "source_baseline", errors)
    repository = baseline.get("repository")
    commit = baseline.get("commit")
    if not isinstance(repository, str) or not repository.startswith("https://"):
        errors.append("source_baseline.repository must be an HTTPS URL")
    if not isinstance(commit, str) or HEX_40.fullmatch(commit) is None:
        errors.append("source_baseline.commit must be 40 lowercase hex characters")

    destinations: set[str] = set()
    entry_destinations: set[str] = set()
    entries = root.get("entries")
    if not isinstance(entries, list):
        errors.append("entries must be an array")
        entries = []
    for index, raw_entry in enumerate(entries):
        label = f"entries[{index}]"
        entry = _mapping(raw_entry, label, errors)
        if entry.get("source_repository") != repository:
            errors.append(f"{label}.source_repository does not match source_baseline")
        if entry.get("source_commit") != commit:
            errors.append(f"{label}.source_commit does not match source_baseline")
        if not isinstance(entry.get("source_path"), str) or not entry.get("source_path"):
            errors.append(f"{label}.source_path is required")
        if (
            not isinstance(entry.get("source_blob"), str)
            or HEX_40.fullmatch(entry.get("source_blob", "")) is None
        ):
            errors.append(f"{label}.source_blob must be 40 lowercase hex characters")
        destination = _safe_destination(entry.get("destination_path"), label, errors)
        _verify_hash(entry, label, destination, errors)
        if destination is not None:
            if destination in destinations:
                errors.append(f"duplicate destination_path: {destination}")
            destinations.add(destination)
            entry_destinations.add(destination)
        if entry.get("locally_modified") not in {True, False}:
            errors.append(f"{label}.locally_modified must be boolean")
        for field in ("license", "imported_at", "relationship"):
            if not isinstance(entry.get(field), str) or not entry.get(field):
                errors.append(f"{label}.{field} is required")

    generated_destinations: set[str] = set()
    generated_by_destination: dict[str, dict[str, Any]] = {}
    generated_assets = root.get("generated_assets")
    if not isinstance(generated_assets, list):
        errors.append("generated_assets must be an array")
        generated_assets = []
    for index, raw_asset in enumerate(generated_assets):
        label = f"generated_assets[{index}]"
        asset = _mapping(raw_asset, label, errors)
        destination = _safe_destination(asset.get("destination_path"), label, errors)
        _verify_hash(asset, label, destination, errors)
        if destination is not None:
            if destination in destinations:
                errors.append(f"duplicate destination_path: {destination}")
            destinations.add(destination)
            generated_destinations.add(destination)
            generated_by_destination[destination] = asset
        generator = asset.get("generator")
        _verify_repository_file(generator, f"{label}.generator", errors)
        inputs = asset.get("inputs")
        if not isinstance(inputs, list) or not inputs:
            errors.append(f"{label}.inputs must be a non-empty array")
        else:
            for input_index, source in enumerate(inputs):
                _verify_repository_file(source, f"{label}.inputs[{input_index}]", errors)
        for field in ("license", "generated_at", "relationship"):
            if not isinstance(asset.get(field), str) or not asset.get(field):
                errors.append(f"{label}.{field} is required")

    derivation_destinations: set[str] = set()
    derivations = root.get("conceptual_derivations")
    if not isinstance(derivations, list) or not derivations:
        errors.append("conceptual_derivations must be a non-empty array")
        derivations = []
    for index, raw_derivation in enumerate(derivations):
        label = f"conceptual_derivations[{index}]"
        derivation = _mapping(raw_derivation, label, errors)
        destination = _safe_destination(derivation.get("destination_path"), label, errors)
        _verify_hash(derivation, label, destination, errors)
        if destination is not None:
            if destination in destinations:
                errors.append(f"duplicate destination_path: {destination}")
            destinations.add(destination)
            derivation_destinations.add(destination)
        if derivation.get("locally_modified") is not True:
            errors.append(f"{label}.locally_modified must be true")
        for field in ("license", "modified_at", "relationship"):
            if not isinstance(derivation.get(field), str) or not derivation.get(field):
                errors.append(f"{label}.{field} is required")
        sources = derivation.get("sources")
        if not isinstance(sources, list) or not sources:
            errors.append(f"{label}.sources must be a non-empty array")
        else:
            for source_index, source in enumerate(sources):
                _verify_source(
                    source,
                    f"{label}.sources[{source_index}]",
                    repository,
                    commit,
                    errors,
                )
        destination_symbols = derivation.get("destination_symbols")
        if not isinstance(destination_symbols, list) or not destination_symbols:
            errors.append(f"{label}.destination_symbols must be non-empty")
        tests = derivation.get("tests")
        if not isinstance(tests, list) or not tests:
            errors.append(f"{label}.tests must be non-empty")
        else:
            for test_path in tests:
                if isinstance(test_path, str) and test_path.startswith("frontend/"):
                    # Historical Babylon client coverage is retained as provenance only.
                    continue
                mapped_test_path = (
                    _target_destination(test_path) if isinstance(test_path, str) else None
                )
                if mapped_test_path is None or not (ROOT / mapped_test_path).is_file():
                    errors.append(f"{label}.tests references a missing file: {test_path!r}")

    missing_entries = EXPECTED_VERBATIM - entry_destinations
    if missing_entries:
        errors.append(f"missing verbatim/generated entries: {sorted(missing_entries)}")
    missing_generated = EXPECTED_GENERATED - generated_destinations
    if missing_generated:
        errors.append(f"missing generated asset entries: {sorted(missing_generated)}")
    missing_derivations = EXPECTED_DERIVATIONS - derivation_destinations
    if missing_derivations:
        errors.append(f"missing conceptual derivations: {sorted(missing_derivations)}")

    review = _mapping(root.get("manual_review"), "manual_review", errors)
    if review.get("required") is not True or review.get("completed") is not True:
        errors.append("manual_review must be required and completed")
    checklist = _mapping(review.get("checklist"), "manual_review.checklist", errors)
    for item in (
        "source_ranges_checked",
        "destination_hashes_checked",
        "test_mappings_checked",
        "conceptual_rewrites_checked",
    ):
        if checklist.get(item) is not True:
            errors.append(f"manual_review.checklist.{item} must be true")

    fixture_path = ROOT / "backend/tests/fixtures/frame-parity/baseline.json"
    if fixture_path.is_file():
        try:
            fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            errors.append(f"frame fixture is invalid JSON: {exc}")
        else:
            if fixture.get("schema_version") != "sy205-frame-parity-v1":
                errors.append("frame fixture schema_version must equal sy205-frame-parity-v1")
            if fixture.get("model_version") != MODEL_VERSION:
                errors.append("frame fixture model_version does not match the backend")
            frame_entry = generated_by_destination.get(
                "backend/tests/fixtures/frame-parity/baseline.json"
            )
            urdf_entry = generated_by_destination.get("assets/model/kinematic_excavator.urdf")
            if fixture.get("source_urdf_path") != "assets/model/kinematic_excavator.urdf":
                errors.append("frame fixture source_urdf_path is incorrect")
            if urdf_entry is not None and fixture.get("source_urdf_sha256") != urdf_entry.get(
                "destination_sha256"
            ):
                errors.append("frame fixture URDF hash does not match the active URDF entry")
            if fixture.get("source_model_path") != "backend/src/babylon_sim/model.py":
                errors.append("frame fixture source_model_path is incorrect")
            if fixture.get("source_model_sha256") != _sha256(
                ROOT / "backend/src/babylon_sim/model.py"
            ):
                errors.append("frame fixture source_model_sha256 is stale")
            source_lock_hash = fixture.get("source_pixi_lock_sha256")
            if source_lock_hash != _sha256(ROOT / "pixi.lock"):
                errors.append("frame fixture source_pixi_lock_sha256 is stale")
            if fixture.get("pinocchio_version") != "4.1.0":
                errors.append("frame fixture must record the pinned Pinocchio 4.1.0 baseline")
            if frame_entry is not None:
                frame_inputs = {
                    value.get("path")
                    for value in frame_entry.get("inputs", [])
                    if isinstance(value, dict)
                }
                if frame_inputs != {"assets/model/kinematic_excavator.urdf", "pixi.lock"}:
                    errors.append("frame fixture generated inputs are incomplete")

    notice = ROOT / "NOTICE.md"
    retained_license = "assets/licenses/KinematicSim-AGPL-3.0.txt"
    if notice.is_file() and retained_license not in notice.read_text(encoding="utf-8"):
        errors.append("NOTICE.md does not reference the retained KinematicSim license")
    _verify_visual_assets(errors)
    return errors


def main() -> int:
    errors = verify()
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
    print(
        "Provenance verified: "
        f"{len(manifest['entries'])} imported entries, "
        f"{len(manifest['generated_assets'])} generated assets, "
        f"{len(manifest['conceptual_derivations'])} conceptual derivations."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
