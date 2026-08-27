from __future__ import annotations

import json
from pathlib import Path

import pytest

from babylon_sim.equipment_command_profile import (
    AXIS_ORDER,
    NEGATIVE_SEMANTICS,
    POSITIVE_SEMANTICS,
    EquipmentCommandProfileError,
    load_equipment_command_profile,
)
from babylon_sim.input_router import InputRouter, InputSnapshot


def test_profile_locks_operator_semantics_and_model_signs() -> None:
    profile = load_equipment_command_profile()
    assert AXIS_ORDER == ("swing", "boom", "arm", "bucket")
    assert POSITIVE_SEMANTICS == (
        "right_rotation",
        "boom_raise",
        "arm_extend",
        "bucket_curl",
    )
    assert NEGATIVE_SEMANTICS == (
        "left_rotation",
        "boom_lower",
        "arm_retract",
        "bucket_dump",
    )
    assert profile.signs_for("sy205") == (-1.0, -1.0, -1.0, 1.0)
    assert profile.signs_for("sy135") == (-1.0, 1.0, 1.0, -1.0)


@pytest.mark.parametrize("model_id", ["sy205", "sy135"])
def test_router_maps_each_isolated_operator_direction(model_id: str) -> None:
    signs = load_equipment_command_profile().signs_for(model_id)
    for index in range(4):
        for direction in (-1.0, 1.0):
            router = InputRouter(operator_to_joint_signs=signs)
            router.submit(
                InputSnapshot("godot", 0, True, (0.0, 0.0, 0.0, 0.0)),
                client_id="client",
            )
            axes = [0.0, 0.0, 0.0, 0.0]
            axes[index] = direction
            router.submit(InputSnapshot("godot", 1, True, tuple(axes)), client_id="client")
            command = router.command(timestamp=0.0, sequence_number=0)
            expected = [0.0, 0.0, 0.0, 0.0]
            expected[index] = direction * signs[index]
            assert command.channels == tuple(expected)


def test_profile_schema_rejects_non_sign_and_unknown_model(tmp_path: Path) -> None:
    root = Path(__file__).resolve().parents[3]
    payload = json.loads(
        (root / "protocol/equipment-command-profile-v1.json").read_text(encoding="utf-8")
    )
    payload["models"]["sy205"]["semantic_to_joint_signs"][0] = 0
    payload["models"]["unknown"] = payload["models"]["sy135"]
    invalid = tmp_path / "invalid.json"
    invalid.write_text(json.dumps(payload), encoding="utf-8")
    with pytest.raises(EquipmentCommandProfileError, match="schema error"):
        load_equipment_command_profile(invalid)


def test_godot_runtime_copy_is_exactly_generated() -> None:
    root = Path(__file__).resolve().parents[3]
    source = json.loads(
        (root / "protocol/equipment-command-profile-v1.json").read_text(encoding="utf-8")
    )
    expected = (json.dumps(source, indent=2, ensure_ascii=False) + "\n").encode()
    generated = root / "godot/client/resources/protocol/equipment-command-profile-v1.json"
    assert generated.read_bytes() == expected
