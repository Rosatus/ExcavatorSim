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
 SG_ ChoiceB m1 : 40|8@1+ (1,0) [0|255] "" ECU
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
