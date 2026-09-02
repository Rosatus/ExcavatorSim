"""Unified CAN console authority, native adapter, and profile tests."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from can_console import CanConsoleRuntime, canonical_can_key  # noqa: E402
from can_special_frames import TIMED_CAN_FREQUENCY_HZ, TIMED_CAN_ID  # noqa: E402
from dbc_engine import DbcConfigStore, GatewayRuntimeError, OperatorDbcRuntime  # noqa: E402
from encoders.dxg_slew import SLEW_CAN_ID  # noqa: E402
from encoders.travel_pilot import TRAVEL_CAN_ID  # noqa: E402

SYNTHETIC_DBC = """VERSION "console"
NS_ :
BS_:
BU_: ECU
BO_ 2147483939 Extended: 2 ECU
 SG_ Signed : 0|16@1- (0.1,0) [-3276.8|3276.7] "m/s" ECU

BO_ 2566909952 MSG_18FFF000: 8 ECU
 SG_ ROTATE : 0|16@1+ (0.0054931640625,0) [0|359.9945068359375] "degree" ECU

CM_ BO_ 2147483939 "channel=can3";
CM_ BO_ 2566909952 "channel=can3";
"""

RELOADED_DBC = """VERSION "console-reloaded"
NS_ :
BS_:
BU_: ECU
BO_ 2147483940 Reloaded: 2 ECU
 SG_ Unsigned : 0|16@1+ (1,0) [0|65535] "" ECU
CM_ BO_ 2147483940 "channel=can3";
"""


class CanConsoleRuntimeTest(unittest.TestCase):
    def make_runtime(self, root: Path, mode: str = "standalone") -> CanConsoleRuntime:
        dbc_root = root / "dbc"
        dbc_root.mkdir(exist_ok=True)
        (dbc_root / "fixture.dbc").write_text(SYNTHETIC_DBC, encoding="utf-8")
        operator = OperatorDbcRuntime(
            [dbc_root],
            store=DbcConfigStore(root / "dbc-config.json"),
        )
        return CanConsoleRuntime(
            operator,
            mode=mode,  # type: ignore[arg-type]
            simulation_rates={
                0x123: 20,
                SLEW_CAN_ID: 100,
                TRAVEL_CAN_ID: 10,
                TIMED_CAN_ID: TIMED_CAN_FREQUENCY_HZ,
            },
        )

    def test_identity_distinguishes_sff_and_eff(self) -> None:
        self.assertEqual(canonical_can_key(0x123, False), "sff:00000123")
        self.assertEqual(canonical_can_key(0x123, True), "eff:00000123")
        self.assertNotEqual(canonical_can_key(0x123, False), canonical_can_key(0x123, True))

    def test_standalone_roundtrip_persists_but_never_arms(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = self.make_runtime(root)
            key = canonical_can_key(0x123, True)
            runtime.set_authority(key, "custom")
            preview = runtime.preview(key, payload_hex="7B 00")
            self.assertEqual(preview["values"]["Signed"], 12.3)
            runtime.update(key, values={"Signed": -4.5}, frequency_hz=25)
            runtime.start(transport_ready=True)
            self.assertTrue(runtime.armed)

            restored = self.make_runtime(root)
            row = next(item for item in restored.snapshot()["messages"] if item["key"] == key)
            self.assertEqual(row["authority"], "custom")
            self.assertEqual(row["frequency_hz"], 25)
            self.assertEqual(row["values"]["Signed"], -4.5)
            self.assertFalse(restored.armed)

    def test_dbc_slew_and_native_adapters_reuse_exact_payload_layouts(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runtime = self.make_runtime(Path(tmp))
            slew = canonical_can_key(SLEW_CAN_ID)
            travel = canonical_can_key(TRAVEL_CAN_ID)
            timed = canonical_can_key(TIMED_CAN_ID)
            runtime.set_authority(slew, "custom")
            runtime.set_authority(travel, "custom")
            self.assertEqual(
                runtime.preview(slew, values={"ROTATE": 90})["payload_hex"],
                "00 40 00 00 00 00 00 00",
            )
            self.assertEqual(runtime.entries[slew].definition_dict()["kind"], "dbc")
            self.assertEqual(runtime.entries[slew].channel, "ch3")
            self.assertEqual(
                runtime.preview(
                    travel,
                    values={"left_pressure": 12, "right_pressure": 34},
                )["payload_hex"],
                "00 00 00 00 0C 00 22 00",
            )
            self.assertEqual(runtime.entries[travel].definition_dict()["kind"], "native")
            self.assertEqual(runtime.entries[travel].channel, "ch0")
            self.assertEqual(runtime.entries[timed].definition_dict()["kind"], "native")
            self.assertEqual(runtime.entries[timed].channel, "ch3")
            with self.assertRaises(GatewayRuntimeError) as error:
                runtime.preview(travel, values={"left_pressure": 12.5})
            self.assertEqual(error.exception.code, "dbc_value_invalid")

    def test_console_rebuild_after_operator_reload_uses_new_catalog(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = self.make_runtime(root)
            old_key = canonical_can_key(0x123, True)
            self.assertIn(old_key, runtime.entries)
            (root / "dbc" / "fixture.dbc").write_text(RELOADED_DBC, encoding="utf-8")
            runtime.operator.reload()
            rebuilt = CanConsoleRuntime(
                runtime.operator,
                mode="standalone",
                simulation_rates={
                    0x124: 20,
                    SLEW_CAN_ID: 100,
                    TRAVEL_CAN_ID: 10,
                    TIMED_CAN_ID: TIMED_CAN_FREQUENCY_HZ,
                },
            )
            self.assertNotIn(old_key, rebuilt.entries)
            self.assertIn(canonical_can_key(0x124, True), rebuilt.entries)
            self.assertFalse(rebuilt.armed)

    def test_managed_defaults_and_overrides_are_session_only(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            runtime = self.make_runtime(root, "godot-managed")
            key = canonical_can_key(SLEW_CAN_ID)
            self.assertEqual(runtime.entries[key].authority, "simulation")
            self.assertTrue(runtime.allows("godot", SLEW_CAN_ID))
            self.assertFalse(runtime.allows("web", SLEW_CAN_ID))
            runtime.set_authority(key, "custom")
            self.assertTrue(runtime.armed)
            self.assertFalse(runtime.allows("godot", SLEW_CAN_ID))
            self.assertTrue(runtime.allows("web", SLEW_CAN_ID))
            self.assertTrue(runtime.allows("timed", 0x18FFF100))
            self.assertFalse((root / "can-console.json").exists())
            runtime.reset_managed_overrides()
            self.assertEqual(runtime.entries[key].authority, "simulation")
            self.assertFalse(runtime.armed)

    def test_portable_import_is_full_and_rejects_incompatible_profile(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runtime = self.make_runtime(Path(tmp))
            key = canonical_can_key(0x123, True)
            runtime.set_authority(key, "custom")
            profile = runtime.export_profile()
            runtime.set_authority(key, "off")
            runtime.import_profile(profile)
            self.assertEqual(runtime.entries[key].authority, "custom")
            self.assertFalse(runtime.armed)
            runtime.start(transport_ready=True)
            before = json.dumps(runtime.export_profile(), sort_keys=True)
            profile["catalog_fingerprint"] = "wrong"
            with self.assertRaises(GatewayRuntimeError) as error:
                runtime.import_profile(profile)
            self.assertEqual(error.exception.code, "console_profile_incompatible")
            self.assertEqual(json.dumps(runtime.export_profile(), sort_keys=True), before)
            self.assertTrue(runtime.armed)

    def test_low_numeric_extended_dbc_keeps_explicit_identity_in_schedule(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runtime = self.make_runtime(Path(tmp))
            key = canonical_can_key(0x123, True)
            runtime.set_authority(key, "custom")
            runtime.start(transport_ready=True)
            sent: list[tuple[str, int, bytes]] = []
            runtime.service(lambda *frame: sent.append(frame), now_s=10**9)
            self.assertEqual(sent[0][0], key)
            self.assertTrue(runtime.entries[sent[0][0]].is_extended)

    def test_import_write_failure_preserves_live_profile_and_arm(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runtime = self.make_runtime(Path(tmp))
            key = canonical_can_key(0x123, True)
            runtime.set_authority(key, "custom")
            runtime.start(transport_ready=True)
            before = runtime.export_profile()
            candidate = json.loads(json.dumps(before))
            candidate["messages"][key]["frequency_hz"] = 17
            with (
                patch.object(runtime.store, "save", side_effect=OSError("disk full")),
                self.assertRaises(GatewayRuntimeError) as error,
            ):
                runtime.import_profile(candidate)
            self.assertEqual(error.exception.code, "dbc_config_write_failed")
            self.assertEqual(runtime.export_profile(), before)
            self.assertTrue(runtime.armed)


if __name__ == "__main__":
    unittest.main()
