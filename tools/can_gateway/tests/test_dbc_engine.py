"""DBC catalog, strict codec, persistence, scheduler, and protocol adapter tests."""

from __future__ import annotations

import hashlib
import json
import sys
import tempfile
import unittest
from pathlib import Path

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from dbc_engine import (  # noqa: E402
    DEFAULT_FREQUENCY_HZ,
    PROTOCOL_DBC_HASHES,
    DbcCatalog,
    DbcCodec,
    DbcConfigStore,
    GatewayRuntimeError,
    OperatorDbcRuntime,
    PeriodicDbcScheduler,
    _ScheduleEntry,
    encode_godot_imu,
    encode_godot_rtk,
    estimate_bus_load,
    load_protocol_codec,
)
from encoders.ruifen_imu import encode_ruifen_frame  # noqa: E402
from encoders.sinan_rtk import build_rtk_frames, encode_velocity_frame  # noqa: E402
from sinks import CAN_FRAME_STRUCT, pack_can_frame  # noqa: E402

RESOURCE_DBC = TOOLS_DIR / "resources" / "dbc"

SYNTHETIC_DBC = """VERSION "test"

NS_ :

BS_:

BU_: ECU

BO_ 291 Mixed: 8 ECU
 SG_ Mux M : 32|8@1+ (1,0) [0|1] "" ECU
 SG_ ChoiceA m0 : 40|8@1+ (1,0) [0|255] "" ECU
 SG_ ChoiceB m1 : 48|8@1+ (1,0) [0|255] "" ECU
 SG_ MotorolaSigned : 23|16@0- (2,0) [-65536|65534] "u" ECU
 SG_ IntelUnsigned : 0|16@1+ (0.5,-1) [-1|32766.5] "u" ECU

BO_ 2147483939 Extended: 2 ECU
 SG_ Signed : 0|16@1- (0.1,0) [-3276.8|3276.7] "" ECU
"""


class FakeRtkState:
    def __init__(self, velocity: tuple[float, float, float, float] | None = None) -> None:
        self.velocity = velocity or (1.234, -0.567, 0.001, 1.35)

    def wall_clock_unix_s(self) -> float:
        return 315_964_800.0 + 2300 * 604_800 + 452_967.891

    def geodetic(self) -> tuple[float, float, float]:
        return 30.86751234, 120.09331234, -12.345

    def vice_antenna_geodetic(self) -> tuple[float, float, float]:
        return 30.86751111, 120.09331111, -11.234

    def velocity_enu(self) -> tuple[float, float, float, float]:
        return self.velocity

    def heading_degrees(self) -> float:
        return 359.99


class ProtocolCodecTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.codec = load_protocol_codec(RESOURCE_DBC)

    def test_bundled_hashes_and_message_count_are_bound(self) -> None:
        for name, expected in PROTOCOL_DBC_HASHES.items():
            self.assertEqual(
                hashlib.sha256((RESOURCE_DBC / name).read_bytes()).hexdigest(), expected
            )
        self.assertEqual(len(self.codec.messages), 27)

    def test_all_imu_angle_frames_match_manual_encoder(self) -> None:
        cases = (
            (0, 0, 0),
            (1, 32768, 65535),
            (1000, 20000, 30000),
            (18000, 18000, 18000),
        )
        for frame_id in (0x18FF3A00, 0x18FF3B00, 0x18FF3C00, 0x18FF3D00):
            for counts in cases:
                self.assertEqual(
                    encode_godot_imu(self.codec, frame_id, counts),
                    encode_ruifen_frame(counts),
                )

    def test_rtk_family_matches_manual_little_endian_encoder(self) -> None:
        state = FakeRtkState()
        expected = build_rtk_frames(state, byteorder="little", satellite_status=4)
        actual = encode_godot_rtk(self.codec, state, satellite_status=4)
        self.assertEqual(actual, expected)

    def test_godot_and_generic_web_a800_share_little_endian_payload(self) -> None:
        state = FakeRtkState()
        godot = encode_godot_rtk(self.codec, state)[0x0CFDA800]
        web = self.codec.encode_frame(
            0x0CFDA800,
            {"VelE": 1.23, "VelN": -0.57, "VelU": 0.0, "Vel": 1.35},
        )
        self.assertEqual(godot, web)
        self.assertEqual(web.hex(), "7b00c7ff00008700")
        cases = (
            (0.0, 0.0, 0.0, 0.0),
            (327.67, -327.68, 1.235, -1.235),
            (-12.345, 67.895, -0.005, 0.005),
        )
        for values in cases:
            state = FakeRtkState(values)
            godot = encode_godot_rtk(self.codec, state)[0x0CFDA800]
            web = self.codec.encode_frame(
                0x0CFDA800,
                dict(zip(("VelE", "VelN", "VelU", "Vel"), values, strict=True)),
            )
            self.assertEqual(web, godot)
        aligned = (327.67, -327.68, 1.23, -1.23)
        self.assertEqual(
            encode_godot_rtk(self.codec, FakeRtkState(aligned))[0x0CFDA800],
            encode_velocity_frame(*aligned, byteorder="little"),
        )
        with self.assertRaises(GatewayRuntimeError):
            self.codec.encode_frame(
                0x0CFDA800,
                {"VelE": float("nan"), "VelN": 0, "VelU": 0, "Vel": 0},
            )
        clamped = encode_godot_rtk(self.codec, FakeRtkState((999.0, -999.0, 0.0, 0.0)))[0x0CFDA800]
        self.assertEqual(clamped, encode_velocity_frame(999.0, -999.0, 0.0, 0.0))

    def test_operator_reload_failure_cannot_change_protocol_codec(self) -> None:
        before = self.codec.encode_frame(0x0CFDA800, {"VelE": 1, "VelN": 2, "VelU": 3, "Vel": 4})
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp, "operator")
            root.mkdir()
            Path(root, "broken.dbc").write_text("not a dbc", encoding="utf-8")
            operator = OperatorDbcRuntime([root], store=DbcConfigStore(Path(tmp, "config.json")))
            self.assertTrue(operator.catalog.snapshot.files[0].parse_error)
            Path(root, "broken.dbc").write_text("still not a dbc", encoding="utf-8")
            operator.reload()
            self.assertTrue(operator.catalog.snapshot.files[0].parse_error)
        after = self.codec.encode_frame(0x0CFDA800, {"VelE": 1, "VelN": 2, "VelU": 3, "Vel": 4})
        self.assertEqual(after, before)


class CatalogAndStrictCodecTest(unittest.TestCase):
    def test_parse_isolation_dedup_and_same_name_distinct_content(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root_a = Path(tmp, "a")
            root_b = Path(tmp, "b")
            root_a.mkdir()
            root_b.mkdir()
            (root_a / "same.dbc").write_text(SYNTHETIC_DBC, encoding="utf-8")
            (root_b / "copy.dbc").write_text(SYNTHETIC_DBC, encoding="utf-8")
            (root_b / "same.dbc").write_text(
                SYNTHETIC_DBC.replace("BO_ 291 Mixed", "BO_ 292 Mixed"), encoding="utf-8"
            )
            (root_a / "broken.dbc").write_text("broken", encoding="utf-8")
            catalog = DbcCatalog.discover([root_b, root_a])
            self.assertEqual(len(catalog.snapshot.files), 3)
            duplicate = next(file for file in catalog.snapshot.files if len(file.sources) == 2)
            self.assertEqual(len(duplicate.messages), 2)
            self.assertTrue(any(file.parse_error for file in catalog.snapshot.files))
            self.assertEqual(
                sum(message.name == "Mixed" for message in catalog.snapshot.messages), 2
            )
            self.assertFalse(
                any(notice.code == "dbc_duplicate_collapsed" for notice in catalog.snapshot.notices)
            )

    def test_utf8_metadata_cp1252_fallback_and_decode_failure_are_isolated(self) -> None:
        approved = DbcCatalog.discover([RESOURCE_DBC])
        pitch = next(
            signal
            for message in approved.snapshot.messages
            for signal in message.signals
            if signal.name == "Pitch_Angle"
        )
        self.assertEqual(pitch.unit, "°/度")
        self.assertFalse(
            any(notice.code == "dbc_encoding_fallback" for notice in approved.snapshot.notices)
        )

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            cp1252 = SYNTHETIC_DBC.replace('"u" ECU', '"café" ECU', 1)
            (root / "legacy.dbc").write_bytes(cp1252.encode("cp1252"))
            (root / "invalid.dbc").write_bytes(SYNTHETIC_DBC.encode("ascii") + b'\nCM_ "\x81";\n')
            (root / "valid.dbc").write_text(SYNTHETIC_DBC, encoding="utf-8")
            catalog = DbcCatalog.discover([root])
            legacy = next(
                file for file in catalog.snapshot.files if file.sources[0].endswith("legacy.dbc")
            )
            invalid = next(
                file for file in catalog.snapshot.files if file.sources[0].endswith("invalid.dbc")
            )
            self.assertFalse(legacy.parse_error)
            self.assertTrue(
                any(
                    signal.unit == "café"
                    for message in legacy.messages
                    for signal in message.signals
                )
            )
            self.assertTrue(invalid.parse_error)
            self.assertEqual(
                sum(notice.code == "dbc_encoding_fallback" for notice in catalog.snapshot.notices),
                1,
            )
            self.assertEqual(
                sum(notice.code == "dbc_parse_failed" for notice in catalog.snapshot.notices),
                1,
            )

    def test_intel_motorola_signed_scaled_mux_and_extended_encode(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "fixture.dbc")
            path.write_text(SYNTHETIC_DBC, encoding="utf-8")
            codec = DbcCodec(DbcCatalog.discover([Path(tmp)]))
            mixed = next(message for message in codec.messages.values() if message.name == "Mixed")
            encoded = codec.encode(
                mixed.key,
                {
                    "IntelUnsigned": 1.0,
                    "MotorolaSigned": -4.0,
                    "Mux": 0,
                    "ChoiceA": 7,
                },
            )
            self.assertEqual(encoded.hex(), "0400fffe00070000")
            extended = next(
                message for message in codec.messages.values() if message.name == "Extended"
            )
            self.assertTrue(extended.is_extended)
            short_payload = codec.encode(extended.key, {"Signed": -1.2})
            self.assertEqual(short_payload.hex(), "f4ff")
            _can_id, dlc, _pad, _res0, _len8_dlc, data = CAN_FRAME_STRUCT.unpack(
                pack_can_frame(extended.frame_id, short_payload)
            )
            self.assertEqual(dlc, 2)
            self.assertEqual(data, b"\xf4\xff" + bytes(6))
            with self.assertRaises(GatewayRuntimeError):
                codec.encode(mixed.key, {"IntelUnsigned": 1, "MotorolaSigned": 0, "Mux": 0})
            with self.assertRaises(GatewayRuntimeError):
                codec.encode(extended.key, {"Signed": 9999})

    def test_payload_decode_value_merge_preserves_unmodeled_bits_and_switches_mux(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp, "fixture.dbc")
            path.write_text(SYNTHETIC_DBC, encoding="utf-8")
            codec = DbcCodec(DbcCatalog.discover([Path(tmp)]))
            mixed = next(message for message in codec.messages.values() if message.name == "Mixed")
            base = bytes.fromhex("0400fffe0007aa55")
            self.assertEqual(codec.decode(mixed.key, base)["ChoiceA"], 7.0)
            active_merged, _active_values = codec.merge_values(
                mixed.key,
                base,
                {"IntelUnsigned": 2.0},
            )
            self.assertEqual(active_merged.hex(), "0600fffe0007aa55")
            merged, values = codec.merge_values(
                mixed.key,
                base,
                {"IntelUnsigned": 2.0, "Mux": 1, "ChoiceB": 9},
            )
            self.assertEqual(merged.hex(), "0600fffe01000955")
            self.assertEqual(values["Mux"], 1.0)
            self.assertEqual(values["ChoiceB"], 9.0)
            self.assertNotIn("ChoiceA", values)
            compact, compact_values = codec.normalize_payload(mixed.key, merged.hex())
            spaced, spaced_values = codec.normalize_payload(mixed.key, "06 00 FF FE 01 00 09 55")
            self.assertEqual(compact, merged)
            self.assertEqual(spaced, merged)
            self.assertEqual(compact_values, spaced_values)
            self.assertEqual(codec.format_payload(merged), "06 00 FF FE 01 00 09 55")
            for invalid in ("0x0600FFFE01000955", "060", "GG", "06 00"):
                with self.assertRaises(GatewayRuntimeError):
                    codec.normalize_payload(mixed.key, invalid)
            for selector in (0.5, 1.5):
                with self.assertRaises(GatewayRuntimeError) as error:
                    codec.merge_values(mixed.key, base, {"Mux": selector})
                self.assertEqual(error.exception.code, "dbc_value_invalid")


class OperatorRuntimeTest(unittest.TestCase):
    def test_generated_defaults_persistence_conflict_and_never_persist_armed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            store = DbcConfigStore(Path(tmp, "config.json"))
            runtime = OperatorDbcRuntime([RESOURCE_DBC], store=store)
            self.assertTrue(runtime.drafts)
            first = next(
                key
                for key, message in runtime.codec.messages.items()
                if message.frame_id == 0x0CFDA800
            )
            self.assertEqual(runtime.drafts[first].frequency_hz, DEFAULT_FREQUENCY_HZ)
            runtime.update_message(
                first,
                values={"VelE": 1, "VelN": 2, "VelU": 3, "Vel": 4},
                enabled=True,
                frequency_hz=25,
            )
            runtime.start(transport_ready=True)
            self.assertTrue(runtime.armed)
            persisted = json.loads(store.path.read_text(encoding="utf-8"))
            self.assertNotIn("armed", persisted)
            restored = OperatorDbcRuntime([RESOURCE_DBC], store=store)
            self.assertFalse(restored.armed)
            self.assertTrue(restored.drafts[first].enabled)
            self.assertEqual(restored.drafts[first].frequency_hz, 25)
            with self.assertRaises(GatewayRuntimeError):
                restored.update_message(first, frequency_hz=1.5)  # type: ignore[arg-type]

    def test_payload_is_canonical_preview_is_pure_and_legacy_values_migrate(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp, "dbc")
            root.mkdir()
            (root / "fixture.dbc").write_text(SYNTHETIC_DBC, encoding="utf-8")
            store = DbcConfigStore(Path(tmp, "config.json"))
            runtime = OperatorDbcRuntime([root], store=store)
            key = next(
                key for key, message in runtime.codec.messages.items() if message.name == "Mixed"
            )
            before = runtime.drafts[key].payload
            preview = runtime.preview_message(key, payload_hex="04 00 FF FE 00 07 AA 55")
            self.assertEqual(runtime.drafts[key].payload, before)
            self.assertFalse(store.path.exists())
            self.assertEqual(preview["payload_hex"], "04 00 FF FE 00 07 AA 55")

            runtime.update_message(
                key,
                payload_hex="04 00 FF FE 00 07 AA 55",
                enabled=True,
                frequency_hz=25,
            )
            runtime.update_message(key, frequency_hz=20)
            self.assertEqual(runtime.drafts[key].payload.hex(), "0400fffe0007aa55")
            persisted = json.loads(store.path.read_text(encoding="utf-8"))
            self.assertEqual(persisted["schema_version"], 2)
            self.assertEqual(persisted["messages"][key]["payload_hex"], "0400FFFE0007AA55")
            restored = OperatorDbcRuntime([root], store=store)
            self.assertEqual(restored.drafts[key].payload, runtime.drafts[key].payload)
            self.assertEqual(
                next(
                    item
                    for item in restored.snapshot()["messages"]
                    if item["message"]["key"] == key
                )["payload_hex"],
                "04 00 FF FE 00 07 AA 55",
            )

            legacy_values = {
                "IntelUnsigned": 1.0,
                "MotorolaSigned": -4.0,
                "Mux": 0,
                "ChoiceA": 7,
            }
            store.path.write_text(
                json.dumps(
                    {
                        "schema_version": 1,
                        "messages": {
                            key: {
                                "values": legacy_values,
                                "enabled": True,
                                "frequency_hz": 10,
                            }
                        },
                    }
                ),
                encoding="utf-8",
            )
            migrated = OperatorDbcRuntime([root], store=store)
            self.assertEqual(migrated.drafts[key].payload.hex(), "0400fffe00070000")
            self.assertTrue(migrated.drafts[key].enabled)
            self.assertFalse(migrated.armed)

    def test_reload_disarms_and_ignores_disk_edits_until_explicit_reload(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp, "dbc")
            root.mkdir()
            path = root / "fixture.dbc"
            path.write_text(SYNTHETIC_DBC, encoding="utf-8")
            runtime = OperatorDbcRuntime([root], store=DbcConfigStore(Path(tmp, "config.json")))
            count = len(runtime.codec.messages)
            path.write_text(
                SYNTHETIC_DBC + '\nBO_ 400 Later: 1 ECU\n SG_ X : 0|8@1+ (1,0) [0|255] "" ECU\n',
                encoding="utf-8",
            )
            self.assertEqual(len(runtime.codec.messages), count)
            key = next(iter(runtime.codec.messages))
            runtime.update_message(key, enabled=True)
            runtime.start(transport_ready=True)
            runtime.reload()
            self.assertFalse(runtime.armed)
            self.assertEqual(len(runtime.codec.messages), count + 1)

    def test_same_can_id_definition_cannot_be_enabled_twice(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root_a = Path(tmp, "a")
            root_b = Path(tmp, "b")
            root_a.mkdir()
            root_b.mkdir()
            (root_a / "one.dbc").write_text(SYNTHETIC_DBC, encoding="utf-8")
            (root_b / "two.dbc").write_text(
                SYNTHETIC_DBC.replace('VERSION "test"', 'VERSION "different"'),
                encoding="utf-8",
            )
            runtime = OperatorDbcRuntime(
                [root_a, root_b], store=DbcConfigStore(Path(tmp, "config.json"))
            )
            conflicts = [
                key
                for key, message in runtime.codec.messages.items()
                if message.frame_id == 0x123 and not message.is_extended
            ]
            self.assertEqual(len(conflicts), 2)
            runtime.update_message(conflicts[0], enabled=True)
            with self.assertRaises(GatewayRuntimeError) as ctx:
                runtime.update_message(conflicts[1], enabled=True)
            self.assertEqual(ctx.exception.code, "dbc_can_id_conflict")

    def test_load_warning_never_blocks_start(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            runtime = OperatorDbcRuntime(
                [RESOURCE_DBC], store=DbcConfigStore(Path(tmp, "config.json"))
            )
            for key in runtime.drafts:
                runtime.update_message(key, enabled=True, frequency_hz=100)
            estimate = estimate_bus_load(runtime.drafts, runtime.codec)
            self.assertGreater(estimate["percent"], 100)
            self.assertEqual(estimate["level"], "red")
            runtime.start(transport_ready=True)
            self.assertTrue(runtime.armed)


class SchedulerTest(unittest.TestCase):
    def test_independent_rates_no_catchup_and_rate_change_isolated(self) -> None:
        now = [10.0]
        scheduler = PeriodicDbcScheduler(lambda: now[0])
        scheduler.replace(
            {
                "a": _ScheduleEntry(1, False, b"a", 1),
                "b": _ScheduleEntry(2, False, b"b", 100),
            }
        )
        sent: list[tuple[str, float]] = []
        scheduler.start()
        scheduler.service(lambda key, _frame, _payload: sent.append((key, now[0])))
        now[0] = 10.01
        scheduler.service(lambda key, _frame, _payload: sent.append((key, now[0])))
        now[0] = 12.0
        scheduler.service(lambda key, _frame, _payload: sent.append((key, now[0])))
        self.assertEqual([key for key, _ in sent], ["a", "b", "b", "a", "b"])
        scheduler.update("b", _ScheduleEntry(2, False, b"b", 50))
        now[0] = 12.01
        self.assertEqual(scheduler.service(lambda *_args: None), 0)
        now[0] = 12.02
        self.assertEqual(scheduler.service(lambda *_args: None), 1)
        scheduler.disarm()
        now[0] = 20.0
        self.assertEqual(scheduler.service(lambda *_args: None), 0)


if __name__ == "__main__":
    unittest.main()
