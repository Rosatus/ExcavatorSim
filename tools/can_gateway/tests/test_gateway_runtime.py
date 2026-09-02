"""Tests for Gateway command, snapshot, event, and persistence primitives."""

from __future__ import annotations

import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from gateway_runtime import (  # noqa: E402
    GatewayConfigStore,
    GatewayRuntimeCore,
    GatewayRuntimeError,
    RuntimeEventLog,
)


class GatewayRuntimeCoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.events = RuntimeEventLog(directory=root / "logs", ring_capacity=3)
        self.core = GatewayRuntimeCore(
            mode="standalone",
            platform="windows",
            transport_kind="tcp",
            tcp_host="127.0.0.1",
            tcp_port=5678,
            can_interface="can0",
            event_log=self.events,
            config_store=GatewayConfigStore(root / "config.json"),
        )

    def tearDown(self) -> None:
        self.core.close()
        self.tmp.cleanup()

    def test_submitted_command_requires_owner_completion(self) -> None:
        future = self.core.submit(
            kind="tcp_rebind",
            payload={"host": "127.0.0.1", "port": 6000},
            expected_revision=0,
            request_id="one",
        )
        self.assertFalse(future.done())
        commands = self.core.take_commands()
        self.assertEqual(len(commands), 1)
        self.assertEqual(commands[0].kind, "tcp_rebind")
        self.core.require_revision(commands[0])
        self.core.complete(commands[0], {"ok": True})
        self.assertEqual(future.result(timeout=0), {"ok": True})

    def test_web_contract_fixture_matches_status_dto(self) -> None:
        fixture_path = TOOLS_DIR / "web" / "src" / "test" / "web_contract.json"
        fixture = json.loads(fixture_path.read_text(encoding="utf-8"))
        self.assertEqual(sorted(self.core.snapshot().to_dict()), fixture["status_keys"])
        self.assertEqual(
            sorted(self.core.dbc_snapshot()),
            fixture["dbc_root_keys"],
        )

    def test_request_id_is_idempotent_and_conflict_is_rejected(self) -> None:
        first = self.core.submit(
            kind="tcp_rebind",
            payload={"host": "127.0.0.1", "port": 6000},
            expected_revision=0,
            request_id="same",
        )
        second = self.core.submit(
            kind="tcp_rebind",
            payload={"host": "127.0.0.1", "port": 6000},
            expected_revision=0,
            request_id="same",
        )
        self.assertIs(first, second)
        with self.assertRaises(GatewayRuntimeError) as ctx:
            self.core.submit(
                kind="tcp_rebind",
                payload={"host": "127.0.0.1", "port": 6001},
                expected_revision=0,
                request_id="same",
            )
        self.assertEqual(ctx.exception.code, "request_id_conflict")

    def test_stale_revision_does_not_mutate_status(self) -> None:
        self.core.publish(mutate_revision=True, tcp_port=6000)
        future = self.core.submit(
            kind="tcp_rebind",
            payload={"host": "127.0.0.1", "port": 6001},
            expected_revision=0,
            request_id="stale",
        )
        command = self.core.take_commands()[0]
        with self.assertRaises(GatewayRuntimeError) as ctx:
            self.core.require_revision(command)
        self.core.fail(command, ctx.exception)
        self.assertEqual(future.exception(timeout=0).code, "stale_revision")
        self.assertEqual(self.core.snapshot().tcp_port, 6000)

    def test_event_ring_reports_gap_and_persists_jsonl(self) -> None:
        for index in range(5):
            self.core.emit_event("state", "test", index=index)
        events, gap = self.events.events_after(0)
        self.assertTrue(gap)
        self.assertEqual([event.sequence for event in events], [3, 4, 5])
        self.core.close()
        lines = self.events.current_path.read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines), 5)
        self.assertEqual(json.loads(lines[-1])["detail"]["index"], 4)

    def test_transmission_records_are_aggregated(self) -> None:
        for _ in range(10):
            self.core.record_transmission(
                source="godot", can_id=0x123, payload=b"\x01" * 8, success=True
            )
        self.core.flush_transmission_aggregates(time.monotonic() + 1.1)
        events, gap = self.events.events_after(0)
        self.assertFalse(gap)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].kind, "transmission_aggregate")
        self.assertEqual(events[0].detail["attempted"], 10)
        self.assertEqual(events[0].detail["succeeded"], 10)

    def test_socketcan_outcomes_are_aggregated_by_source_family_and_id(self) -> None:
        for outcome in ("submitted", "submitted", "coalesced", "sent"):
            self.core.record_socketcan_outcome(
                source="godot",
                family="imu",
                can_id=0x18FF3A00,
                payload=b"\x02" * 8,
                outcome=outcome,
                reason="newer_value" if outcome == "coalesced" else "",
            )
        self.core.flush_transmission_aggregates(time.monotonic() + 1.1)
        events, _gap = self.events.events_after(0)
        self.assertEqual(len(events), 1)
        event = events[0]
        self.assertEqual(event.kind, "socketcan_transmission_aggregate")
        self.assertEqual(event.source, "godot")
        self.assertEqual(event.detail["family"], "imu")
        self.assertEqual(event.detail["can_id"], "0x18FF3A00")
        self.assertEqual(event.detail["submitted"], 2)
        self.assertEqual(event.detail["coalesced"], 1)
        self.assertEqual(event.detail["sent"], 1)

    def test_egress_tracker_uses_last_ten_successes_and_resets_rate_only(self) -> None:
        key = "eff:18FF3A00"
        for index in range(12):
            self.core.record_egress(
                key=key,
                source="godot",
                authority="simulation",
                payload=bytes([index]) * 8,
                values={"AngleX": float(index)},
                monotonic_s=10.0 + index * 0.02,
            )
        _status, snapshot = self.core.console_web_snapshot()
        # Publish a row so the tracker projection is joined at the HTTP boundary.
        self.core.publish_console_snapshot({"messages": [{"key": key}], "custom_armed": False})
        _status, snapshot = self.core.console_web_snapshot()
        runtime = snapshot["messages"][0]["runtime"]
        self.assertEqual(runtime["sample_count"], 10)
        self.assertAlmostEqual(runtime["actual_frequency_hz"], 50.0)
        self.assertEqual(runtime["last_payload_hex"], "0B" * 8)
        self.assertEqual(runtime["values"], {"AngleX": 11.0})

        self.core.reset_egress_rate(key)
        _status, reset = self.core.console_web_snapshot()
        runtime = reset["messages"][0]["runtime"]
        self.assertIsNone(runtime["actual_frequency_hz"])
        self.assertEqual(runtime["sample_count"], 0)
        self.assertEqual(runtime["last_payload_hex"], "0B" * 8)

    def test_console_runtime_events_are_coalesced_to_fifty_milliseconds(self) -> None:
        self.core.record_egress(
            key="sff:00000123",
            source="web",
            authority="custom",
            payload=b"\x01",
            monotonic_s=1.0,
        )
        self.core.flush_console_runtime(self.core._last_egress_event_s + 0.01)
        self.assertEqual(self.events.events_after(0)[0], [])
        self.core.flush_console_runtime(self.core._last_egress_event_s + 0.05)
        events, _gap = self.events.events_after(0)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].kind, "can_console_runtime")
        self.assertIn("status", events[0].detail)

    def test_console_runtime_event_carries_status_without_egress_rows(self) -> None:
        self.core.publish(pc001_dropped_frames=42)
        self.core.flush_console_runtime(self.core._last_egress_event_s + 0.05)
        events, _gap = self.events.events_after(0)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0].detail["rows"], {})
        self.assertEqual(events[0].detail["status"]["pc001_dropped_frames"], 42)

        self.core.flush_console_runtime(self.core._last_egress_event_s + 0.05)
        events, _gap = self.events.events_after(0)
        self.assertEqual(len(events), 1)


class GatewayConfigStoreTest(unittest.TestCase):
    def test_atomic_roundtrip_and_invalid_fallback(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "config.json"
            store = GatewayConfigStore(path)
            self.assertEqual(store.load_tcp_endpoint("0.0.0.0", 5678), ("0.0.0.0", 5678))
            store.save_tcp_endpoint("127.0.0.1", 6123)
            self.assertEqual(store.load_tcp_endpoint("0.0.0.0", 5678), ("127.0.0.1", 6123))
            path.write_text('{"schema_version":1,"tcp":{"port":"bad"}}', encoding="utf-8")
            self.assertEqual(store.load_tcp_endpoint("0.0.0.0", 5678), ("0.0.0.0", 5678))


class RuntimeEventLogRotationTest(unittest.TestCase):
    def test_rotation_stays_within_declared_file_count(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            log = RuntimeEventLog(
                directory=Path(tmp),
                max_file_bytes=220,
                file_count=3,
                writer_capacity=128,
            )
            for index in range(30):
                log.append("state", "test", {"index": index, "padding": "x" * 40})
            log.close()
            paths = log.retained_paths()
            self.assertLessEqual(len(paths), 3)
            self.assertTrue(paths)
            self.assertFalse(Path(f"{log.current_path}.3").exists())

    def test_slow_writer_never_blocks_producer_and_counts_overflow(self) -> None:
        entered = threading.Event()
        release = threading.Event()

        def blocked_writer(_log: RuntimeEventLog) -> None:
            entered.set()
            release.wait(timeout=2.0)

        with (
            tempfile.TemporaryDirectory() as tmp,
            patch.object(RuntimeEventLog, "_writer_loop", blocked_writer),
        ):
            log = RuntimeEventLog(directory=Path(tmp), writer_capacity=2)
            self.assertTrue(entered.wait(timeout=1.0))
            started = time.monotonic()
            for index in range(10):
                log.append("state", "stress", {"index": index})
            self.assertLess(time.monotonic() - started, 0.2)
            self.assertEqual(log.dropped_records, 8)
            release.set()
            log.close()


if __name__ == "__main__":
    unittest.main()
