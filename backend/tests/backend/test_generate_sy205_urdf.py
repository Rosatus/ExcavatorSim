from __future__ import annotations

import copy
import hashlib
import json
import math
import struct
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Any

import numpy as np
import pytest
from backend.scripts import generate_sy205_urdf as generator

from babylon_sim.constants import ACTIVE_JOINT_NAMES, REQUIRED_FRAME_NAMES
from babylon_sim.model import ExcavatorModel
from babylon_sim.paths import URDF_PATH


def _sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _joint_by_child(root: ET.Element, child_name: str) -> ET.Element:
    for joint in root.findall("joint"):
        child = joint.find("child")
        if child is not None and child.attrib.get("link") == child_name:
            return joint
    raise AssertionError(f"missing joint for child {child_name}")


def _xyz(element: ET.Element | None) -> tuple[float, float, float]:
    assert element is not None
    values = tuple(float(value) for value in element.attrib["xyz"].split())
    assert len(values) == 3
    return values  # type: ignore[return-value]


def _encode_glb(document: dict[str, Any], binary: bytes) -> bytes:
    json_bytes = json.dumps(
        document, separators=(",", ":"), ensure_ascii=True, allow_nan=True
    ).encode("utf-8")
    json_bytes += b" " * (-len(json_bytes) % 4)
    binary_bytes = binary + b"\x00" * (-len(binary) % 4)
    total_length = 12 + 8 + len(json_bytes) + 8 + len(binary_bytes)
    return b"".join(
        (
            struct.pack("<4sII", b"glTF", 2, total_length),
            struct.pack("<II", len(json_bytes), generator.GLB_JSON_CHUNK),
            json_bytes,
            struct.pack("<II", len(binary_bytes), generator.GLB_BIN_CHUNK),
            binary_bytes,
        )
    )


def _stage_mutated_inputs(
    tmp_path: Path,
    *,
    mutate_document: Any | None = None,
    mutate_parameters: Any | None = None,
) -> tuple[Path, Path, Path]:
    source_asset = generator.parse_glb(generator.DEFAULT_GLB_PATH.read_bytes())
    document = copy.deepcopy(source_asset.document)
    parameters = json.loads(generator.DEFAULT_PARAMETERS_PATH.read_bytes())
    manifest = json.loads(generator.DEFAULT_VISUAL_MANIFEST_PATH.read_bytes())
    if mutate_document is not None:
        mutate_document(document)
    if mutate_parameters is not None:
        mutate_parameters(parameters)
    glb_bytes = _encode_glb(document, source_asset.binary_chunk)
    glb_path = tmp_path / "source.glb"
    manifest_path = tmp_path / "manifest.json"
    parameters_path = tmp_path / "parameters.json"
    glb_path.write_bytes(glb_bytes)
    source_sha = _sha256(glb_bytes)
    parameters["source"].update({"sha256": source_sha, "byte_size": len(glb_bytes)})
    manifest["source"].update({"sha256": source_sha, "byte_size": len(glb_bytes)})
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    parameters_path.write_text(json.dumps(parameters, allow_nan=True), encoding="utf-8")
    return glb_path, manifest_path, parameters_path


def _assert_generation_failure_preserves_outputs(
    tmp_path: Path,
    *,
    message: str,
    glb_path: Path = generator.DEFAULT_GLB_PATH,
    manifest_path: Path = generator.DEFAULT_VISUAL_MANIFEST_PATH,
    parameters_path: Path = generator.DEFAULT_PARAMETERS_PATH,
) -> None:
    urdf_path = tmp_path / "candidate.urdf"
    evidence_path = tmp_path / "evidence.json"
    reference_path = tmp_path / "reference.urdf"
    originals = {
        urdf_path: b"old-urdf",
        evidence_path: b"old-evidence",
        reference_path: b"old-reference",
    }
    for path, data in originals.items():
        path.write_bytes(data)
    with pytest.raises(generator.GenerationError, match=message):
        generator.generate(
            glb_path=glb_path,
            visual_manifest_path=manifest_path,
            parameters_path=parameters_path,
            urdf_path=urdf_path,
            evidence_path=evidence_path,
            reference_output_path=reference_path,
        )
    assert {path: path.read_bytes() for path in originals} == originals
    assert not list(tmp_path.glob("*.tmp"))
    assert not list(tmp_path.glob("*.bak"))


def test_committed_artifacts_are_reproducible_and_loadable(tmp_path: Path) -> None:
    first_root = tmp_path / "first"
    second_root = tmp_path / "second"
    first = generator.generate(
        urdf_path=first_root / "candidate.urdf",
        evidence_path=first_root / "evidence.json",
        reference_output_path=first_root / "reference.urdf",
    )
    second = generator.generate(
        urdf_path=second_root / "candidate.urdf",
        evidence_path=second_root / "evidence.json",
        reference_output_path=second_root / "reference.urdf",
    )

    assert first == second
    assert first.urdf_bytes == generator.DEFAULT_URDF_PATH.read_bytes()
    assert first.evidence_bytes == generator.DEFAULT_EVIDENCE_PATH.read_bytes()
    assert first.reference_urdf_bytes == generator.DEFAULT_REFERENCE_OUTPUT_PATH.read_bytes()
    assert first.reference_urdf_bytes == generator.DEFAULT_REFERENCE_SOURCE_PATH.read_bytes()

    model = ExcavatorModel.from_urdf(first_root / "candidate.urdf")
    assert tuple(joint.name for joint in model.active_joints) == ACTIVE_JOINT_NAMES
    assert model.frame_names == REQUIRED_FRAME_NAMES
    assert model.pin_model.nv == 4

    evidence = json.loads(first.evidence_bytes)
    assert (
        evidence["inputs"]["glb"]["sha256"]
        == generator.parse_glb(generator.DEFAULT_GLB_PATH.read_bytes()).sha256
    )
    assert evidence["outputs"]["candidate_urdf"]["sha256"] == _sha256(first.urdf_bytes)
    assert evidence["outputs"]["reference_urdf"]["sha256"] == _sha256(first.reference_urdf_bytes)
    assert evidence["generator"]["sha256"] == _sha256(Path(generator.__file__).read_bytes())
    generator._verify_evidence_self_hash(first.evidence_bytes)


def test_candidate_preserves_joint_and_frame_contract_without_activation() -> None:
    root = ET.parse(generator.DEFAULT_URDF_PATH).getroot()
    expected_joints = {
        "swing_joint": ("base_link", "upper_structure_link", (0.0, 0.0, 0.91), (0.0, 0.0, 1.0)),
        "boom_joint": (
            "upper_structure_link",
            "boom_link",
            (-0.119, 0.075, 0.713),
            (1.0, 0.0, 0.0),
        ),
        "arm_joint": (
            "boom_link",
            "arm_link",
            (0.066, -3.915, 4.295),
            (1.0, 0.0, 0.0),
        ),
        "bucket_joint": (
            "arm_link",
            "bucket_link",
            (-0.008, 0.63, -3.026),
            (1.0, 0.0, 0.0),
        ),
    }
    active_elements = [
        joint for joint in root.findall("joint") if joint.attrib.get("type") == "continuous"
    ]
    assert tuple(joint.attrib["name"] for joint in active_elements) == ACTIVE_JOINT_NAMES
    for joint in active_elements:
        parent, child, origin, axis = expected_joints[joint.attrib["name"]]
        assert joint.find("parent").attrib["link"] == parent  # type: ignore[union-attr]
        assert joint.find("child").attrib["link"] == child  # type: ignore[union-attr]
        assert _xyz(joint.find("origin")) == pytest.approx(origin)
        assert _xyz(joint.find("axis")) == pytest.approx(axis)
        assert joint.find("origin").attrib["rpy"] == "0 0 0"  # type: ignore[union-attr]

    assert {link.attrib["name"] for link in root.findall("link")} == set(REQUIRED_FRAME_NAMES)
    assert URDF_PATH == generator.ROOT / "assets/model/kinematic_excavator.urdf"


def test_estimates_are_positive_finite_and_explicitly_evidenced() -> None:
    root = ET.parse(generator.DEFAULT_URDF_PATH).getroot()
    evidence: dict[str, Any] = json.loads(generator.DEFAULT_EVIDENCE_PATH.read_bytes())
    for link_name in generator.MAIN_LINK_NAMES:
        link = root.find(f"link[@name='{link_name}']")
        assert link is not None
        mass = float(link.find("inertial/mass").attrib["value"])  # type: ignore[union-attr]
        inertia = link.find("inertial/inertia")
        collision = link.find("collision/geometry/box")
        assert inertia is not None
        assert collision is not None
        inertia_values = tuple(float(inertia.attrib[key]) for key in ("ixx", "iyy", "izz"))
        collision_size = tuple(float(value) for value in collision.attrib["size"].split())
        assert mass > 0 and math.isfinite(mass)
        assert all(value > 0 and math.isfinite(value) for value in inertia_values)
        assert all(value > 0 and math.isfinite(value) for value in collision_size)

        link_evidence = evidence["links"][link_name]
        assert link_evidence["geometry"]["evidence_level"] == "observed"
        for field in ("mass", "center_of_mass", "inertia", "visual_proxy", "collision_proxy"):
            assert link_evidence[field]["evidence_level"] == "estimated"
        inertia_origin = np.asarray(link_evidence["inertia"]["at_link_origin_kg_m2"])
        assert np.all(np.isfinite(inertia_origin))
        assert np.min(np.linalg.eigvalsh(inertia_origin)) > 0

    assert all(
        payload["evidence_level"] == "retained_provisional"
        for payload in evidence["retained_calibration"]["joint_limits"].values()
    )
    assert evidence["retained_calibration"]["cylinders"]["evidence_level"] == (
        "retained_provisional"
    )
    assert evidence["links"]["bucket_link"]["geometry"]["bounds_min_xyz"] == pytest.approx(
        (-0.649909008, -0.108453035, -0.433943987), abs=1e-9
    )
    assert evidence["links"]["bucket_link"]["geometry"]["bounds_max_xyz"] == pytest.approx(
        (0.661457013, 1.115756035, 1.159776926), abs=1e-9
    )


def test_fixed_landmarks_are_deterministic_and_rigidly_attached() -> None:
    root = ET.parse(generator.DEFAULT_URDF_PATH).getroot()
    expected_parents = {
        "tooth_center": "bucket_link",
        "tooth_left": "bucket_link",
        "tooth_right": "bucket_link",
        "gnss_link": "upper_structure_link",
        "swing_imu_link": "upper_structure_link",
        "boom_imu_link": "boom_link",
        "arm_imu_link": "arm_link",
        "bucket_imu_link": "bucket_link",
    }
    for frame_name, expected_parent in expected_parents.items():
        joint = _joint_by_child(root, frame_name)
        assert joint.find("parent").attrib["link"] == expected_parent  # type: ignore[union-attr]
        assert all(math.isfinite(value) for value in _xyz(joint.find("origin")))

    left = np.asarray(_xyz(_joint_by_child(root, "tooth_left").find("origin")))
    center = np.asarray(_xyz(_joint_by_child(root, "tooth_center").find("origin")))
    right = np.asarray(_xyz(_joint_by_child(root, "tooth_right").find("origin")))
    assert np.allclose(center, (left + right) / 2.0, atol=1e-9)
    assert left[0] < center[0] < right[0]

    model = ExcavatorModel.from_urdf(generator.DEFAULT_URDF_PATH)
    expected_distances: tuple[float, ...] | None = None
    for pose in ((0.0, 0.0, 0.0, 0.0), (0.3, -0.2, 0.4, -0.5)):
        transforms = model.frame_transforms(pose)
        positions = [
            np.asarray(transforms[name], dtype=np.float64)[:3, 3]
            for name in ("tooth_left", "tooth_center", "tooth_right")
        ]
        distances = (
            float(np.linalg.norm(positions[0] - positions[1])),
            float(np.linalg.norm(positions[1] - positions[2])),
            float(np.linalg.norm(positions[0] - positions[2])),
        )
        if expected_distances is None:
            expected_distances = distances
        else:
            assert distances == pytest.approx(expected_distances, abs=1e-12)


def test_position_accessor_supports_offsets_and_stride() -> None:
    first = (1.0, 2.0, 3.0)
    second = (-4.0, 5.0, -6.0)
    binary = (
        b"VIEW" + b"SKIP" + struct.pack("<fff", *first) + b"PAD!" + struct.pack("<fff", *second)
    )
    document = {
        "bufferViews": [{"buffer": 0, "byteOffset": 4, "byteLength": 32, "byteStride": 16}],
        "accessors": [
            {
                "bufferView": 0,
                "byteOffset": 4,
                "componentType": 5126,
                "count": 2,
                "type": "VEC3",
                "min": [-4.0, 2.0, -6.0],
                "max": [1.0, 5.0, 3.0],
            }
        ],
    }
    decoded = generator.decode_position_accessor(document, binary, 0)
    assert np.array_equal(decoded, np.asarray((first, second), dtype=np.float64))


@pytest.mark.parametrize(
    "mutate, message",
    [
        (lambda payload: payload["accessors"][0].update({"componentType": 5123}), "FLOAT VEC3"),
        (lambda payload: payload["accessors"][0].update({"count": 0}), "at least one"),
        (lambda payload: payload["bufferViews"][0].update({"byteLength": 8}), "exceeds"),
        (lambda payload: payload["accessors"][0].update({"sparse": {}}), "sparse"),
    ],
)
def test_position_accessor_rejects_unsupported_or_malformed_data(mutate: Any, message: str) -> None:
    document: dict[str, Any] = {
        "bufferViews": [{"buffer": 0, "byteLength": 12}],
        "accessors": [{"bufferView": 0, "componentType": 5126, "count": 1, "type": "VEC3"}],
    }
    mutate(document)
    with pytest.raises(generator.GenerationError, match=message):
        generator.decode_position_accessor(document, struct.pack("<fff", 1.0, 2.0, 3.0), 0)


def test_invalid_source_digest_preserves_existing_outputs(tmp_path: Path) -> None:
    parameters = json.loads(generator.DEFAULT_PARAMETERS_PATH.read_bytes())
    parameters["source"]["sha256"] = "0" * 64
    parameters_path = tmp_path / "parameters.json"
    parameters_path.write_text(json.dumps(parameters), encoding="utf-8")
    _assert_generation_failure_preserves_outputs(
        tmp_path, message="SHA-256", parameters_path=parameters_path
    )


@pytest.mark.parametrize(
    "case, message",
    [
        ("malformed_graph", "duplicate or multiple parents"),
        ("malformed_accessor", "FLOAT VEC3"),
        ("non_finite_transform", "non-finite constant"),
        ("missing_pivot", "missing node"),
        ("non_unit_scale", "non-unit"),
        ("invalid_estimate", "mass and collision"),
    ],
)
def test_invalid_generation_inputs_preserve_existing_outputs(
    tmp_path: Path, case: str, message: str
) -> None:
    def mutate_document(document: dict[str, Any]) -> None:
        if case == "malformed_graph":
            document["nodes"][19]["children"].append(16)
        elif case == "malformed_accessor":
            document["accessors"][20]["componentType"] = 5123
        elif case == "non_finite_transform":
            document["nodes"][14]["translation"][0] = float("nan")
        elif case == "non_unit_scale":
            document["nodes"][16]["scale"] = [1.0, 1.01, 1.0]

    def mutate_parameters(parameters: dict[str, Any]) -> None:
        if case == "missing_pivot":
            parameters["links"]["bucket_link"]["pivot_index_path"][-1] = 99
        elif case == "invalid_estimate":
            parameters["estimates"]["total_operating_mass_kg"] = -1.0

    glb_path, manifest_path, parameters_path = _stage_mutated_inputs(
        tmp_path,
        mutate_document=mutate_document,
        mutate_parameters=mutate_parameters,
    )
    _assert_generation_failure_preserves_outputs(
        tmp_path,
        message=message,
        glb_path=glb_path,
        manifest_path=manifest_path,
        parameters_path=parameters_path,
    )


def test_duplicate_output_paths_are_rejected_without_writes(tmp_path: Path) -> None:
    shared_path = tmp_path / "shared.output"
    reference_path = tmp_path / "reference.urdf"
    with pytest.raises(generator.GenerationError, match="must be unique"):
        generator.generate(
            urdf_path=shared_path,
            evidence_path=shared_path,
            reference_output_path=reference_path,
        )
    assert not shared_path.exists()
    assert not reference_path.exists()


def test_glb_rejects_wrong_chunk_order_and_alignment() -> None:
    source = generator.DEFAULT_GLB_PATH.read_bytes()
    json_length, json_type = struct.unpack_from("<II", source, 12)
    json_end = 20 + json_length
    bin_length, bin_type = struct.unpack_from("<II", source, json_end)
    bin_end = json_end + 8 + bin_length
    assert json_type == generator.GLB_JSON_CHUNK
    assert bin_type == generator.GLB_BIN_CHUNK
    wrong_order = b"".join(
        (
            source[:12],
            source[json_end:bin_end],
            source[12:json_end],
        )
    )
    with pytest.raises(generator.GenerationError, match="JSON then BIN"):
        generator.parse_glb(wrong_order)

    unaligned = bytearray(source)
    struct.pack_into("<I", unaligned, 12, json_length - 1)
    with pytest.raises(generator.GenerationError, match="4-byte aligned"):
        generator.parse_glb(bytes(unaligned))


def test_non_unit_pivot_scale_is_rejected() -> None:
    transform = np.eye(4, dtype=np.float64)
    transform[1, 1] = 1.01
    with pytest.raises(generator.GenerationError, match="non-unit"):
        generator._validate_unit_rigid(transform, "test pivot")


def test_parameters_do_not_mutate_during_validation() -> None:
    payload = json.loads(generator.DEFAULT_PARAMETERS_PATH.read_bytes())
    original = copy.deepcopy(payload)
    generator._basis_from_parameters(payload)
    assert payload == original
