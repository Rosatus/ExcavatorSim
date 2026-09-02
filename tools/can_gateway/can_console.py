"""Unified per-CAN-ID operator console and transmission authority.

DBC messages keep :class:`DbcCodec` as their encoding authority.  The two
messages which are intentionally outside the shipped DBC use thin adapters
around their existing production encoders/decoders.
"""

from __future__ import annotations

import hashlib
import json
import math
import os
import time
import uuid
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Literal

from can_channel import CanChannel
from can_special_frames import (
    TIMED_CAN_CHANNEL,
    TIMED_CAN_ID,
    TIMED_CAN_PAYLOAD,
    TRAVEL_CAN_CHANNEL,
)
from dbc_engine import (
    DEFAULT_FREQUENCY_HZ,
    MAX_FREQUENCY_HZ,
    MIN_FREQUENCY_HZ,
    OperatorDbcRuntime,
    PeriodicDbcScheduler,
    _ScheduleEntry,
    estimate_bus_load,
)
from encoders.travel_pilot import TRAVEL_CAN_ID, decode_travel, encode_travel_frame
from gateway_runtime import GatewayRuntimeError, RuntimeMode

Authority = Literal["off", "custom", "simulation"]
AUTHORITIES: tuple[Authority, ...] = ("off", "custom", "simulation")
CONSOLE_SCHEMA_VERSION = 4
PORTABLE_FORMAT = "excavatorsim-can-console"
PORTABLE_SCHEMA_VERSION = 2

# Schema-3 fingerprints for rows whose full DLC/signal layout is byte-compatible
# with the approved 2026-09-01 bundle. CAN3 rows intentionally do not appear:
# their descriptor layouts changed. CAN4 only changed comments/channel projection.
LEGACY_SCHEMA3_COMPATIBLE_FINGERPRINTS = {
    0x0CFDA000: "761bcf5e2da1529274f0a01caa3d160ec800446032e71e2d3c0ea11c20ac3419",
    0x0CFDA100: "69db71f01459f79df6c506a8192f7adac9edaeae4dd6ee7fa39f51461a8bda02",
    0x0CFDA200: "4fb86c086fc92a2992e8b7d01fc08c7df6219ff12a551191ffce22c7949fb8bf",
    0x0CFDA300: "105f5dd307d157765199a43d10ec7833f78cf62af52bbee3eb6fa9343e06db2e",
    0x0CFDA400: "032e70b69f85e15e78e5b0b121cf2d062d59bb15d24be12b339bb03ee28ae81b",
    0x0CFDA500: "2ed7c2b5ca1677d4ea5b1cb2b013673125f9829258e8f0e40ec021c65ef8eec2",
    0x0CFDA600: "6249d69d3960c1fe88f4acc44f1e011751b376d3ae1fd3fc1f66b236821d44dc",
    0x0CFDA700: "85c44557f56bfae22c526702900c27a7b79007a994a8d31f87ba9ffa1e057746",
    0x0CFDA800: "7b0aaa382e0e940d17704b55541cca0afaf86028e1e58686cfd4cf15a415261a",
    0x0CFDA900: "110d2ab8ecaec197473b0793727472ecc35980c664ed51b3848b48686af0df9d",
    0x0CFDAA00: "d08f4c263d0310e587ccec2e2b2ad7edbf334a979eb494b5864d8398b11c1ba0",
    0x5801: "8d4e8aec4a2b0e82a3c0937a32d0ccf23df9cf07aab314bfe6192f15bec7048a",
    0x5802: "c425ed1509b9208618687d2e983eddfad6c0d430a46aa4215a8cf6cb4f948097",
    0x0AFDA000: "17ca4dcdf7afa5cc8df0896dc925b796d505a68daecb0cc25c636a5da2c6f90c",
    0x0AFDA300: "6de373a7b969b9d5d64321fca59ed9377e586aae8f50dc52e58a8fc6f5d51f12",
}


def canonical_can_key(can_id: int, is_extended: bool | None = None) -> str:
    extended = can_id > 0x7FF if is_extended is None else is_extended
    return f"{'eff' if extended else 'sff'}:{can_id:08X}"


@dataclass
class _ConsoleEntry:
    key: str
    can_id: int
    is_extended: bool
    name: str
    length: int
    channel: CanChannel
    signals: list[dict[str, Any]]
    descriptor_fingerprint: str
    simulation_capable: bool
    simulation_frequency_hz: float | None
    authority: Authority
    payload: bytes
    frequency_hz: int = DEFAULT_FREQUENCY_HZ
    dbc_key: str | None = None

    def definition_dict(self) -> dict[str, Any]:
        return {
            "key": self.key,
            "name": self.name,
            "frame_id": self.can_id,
            "frame_id_hex": f"0x{self.can_id:X}",
            "is_extended": self.is_extended,
            "length": self.length,
            "channel": self.channel,
            "signals": self.signals,
            "descriptor_fingerprint": self.descriptor_fingerprint,
            "kind": "dbc" if self.dbc_key is not None else "native",
            "dbc_key": self.dbc_key,
        }


class CanConsoleStore:
    """Atomic schema-4 console profile stored beside the legacy DBC config."""

    def __init__(self, path: Path) -> None:
        self.path = path

    def load(self) -> dict[str, Any]:
        try:
            value = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        return value if isinstance(value, dict) else {}

    def save(self, catalog_fingerprint: str, entries: Mapping[str, _ConsoleEntry]) -> None:
        body = {
            "schema_version": CONSOLE_SCHEMA_VERSION,
            "catalog_fingerprint": catalog_fingerprint,
            "messages": {
                key: {
                    "descriptor_fingerprint": entry.descriptor_fingerprint,
                    "authority": entry.authority if entry.authority != "simulation" else "off",
                    "payload_hex": entry.payload.hex().upper(),
                    "frequency_hz": entry.frequency_hz,
                }
                for key, entry in sorted(entries.items())
            },
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        encoded = json.dumps(body, ensure_ascii=False, indent=2, allow_nan=False) + "\n"
        temporary = self.path.with_name(f".{self.path.name}.{os.getpid()}.{uuid.uuid4().hex}.tmp")
        try:
            with temporary.open("w", encoding="utf-8", newline="\n") as handle:
                handle.write(encoded)
                handle.flush()
                os.fsync(handle.fileno())
            temporary.replace(self.path)
        finally:
            if temporary.exists():
                temporary.unlink()


class CanConsoleRuntime:
    """Owner-loop-only authority, drafts, scheduler, and portable profile."""

    def __init__(
        self,
        operator: OperatorDbcRuntime,
        *,
        mode: RuntimeMode,
        simulation_rates: Mapping[int, float],
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.operator = operator
        self.mode = mode
        self.scheduler = PeriodicDbcScheduler(clock)
        self._clock = clock
        self.store = CanConsoleStore(operator.store.path.with_name("can-console.json"))
        self.entries: dict[str, _ConsoleEntry] = {}
        self.migration_notices: list[dict[str, Any]] = []
        self._build_entries(simulation_rates)
        self.catalog_fingerprint = self._catalog_fingerprint()
        if mode == "standalone":
            self._restore(self.store.load())
        self._replace_schedule()

    @property
    def armed(self) -> bool:
        return self.scheduler.armed

    def _build_entries(self, simulation_rates: Mapping[int, float]) -> None:
        for dbc_key, definition in sorted(
            self.operator.codec.messages.items(),
            key=lambda item: (item[1].frame_id, item[1].name, item[0]),
        ):
            key = canonical_can_key(definition.frame_id, definition.is_extended)
            if key in self.entries:
                continue
            draft = self.operator.drafts[dbc_key]
            fingerprint = hashlib.sha256(
                f"dbc:{definition.file_sha256}:{definition.key}:{definition.channel}".encode()
            ).hexdigest()
            capable = definition.frame_id in simulation_rates
            self.entries[key] = _ConsoleEntry(
                key=key,
                can_id=definition.frame_id,
                is_extended=definition.is_extended,
                name=definition.name,
                length=definition.length,
                channel=definition.channel,
                signals=[signal.to_dict() for signal in definition.signals],
                descriptor_fingerprint=fingerprint,
                simulation_capable=capable,
                simulation_frequency_hz=simulation_rates.get(definition.frame_id),
                authority="simulation"
                if self.mode == "godot-managed" and capable
                else ("custom" if draft.enabled else "off"),
                payload=draft.payload,
                frequency_hz=draft.frequency_hz,
                dbc_key=dbc_key,
            )
        self._add_native(
            can_id=TIMED_CAN_ID,
            channel=TIMED_CAN_CHANNEL,
            name="TimedCanTrigger",
            signals=[],
            payload=TIMED_CAN_PAYLOAD,
            simulation_rates=simulation_rates,
            version="timed-can-v1",
        )
        self._add_native(
            can_id=TRAVEL_CAN_ID,
            channel=TRAVEL_CAN_CHANNEL,
            name="TravelPilotPressure",
            signals=[
                self._native_signal(
                    "left_pressure", "左行走先导压力", "kg", 0.0, 50.0, integer_only=True
                ),
                self._native_signal(
                    "right_pressure", "右行走先导压力", "kg", 0.0, 50.0, integer_only=True
                ),
            ],
            payload=encode_travel_frame(0, 0),
            simulation_rates=simulation_rates,
            version="travel-pilot-v1",
        )

    @staticmethod
    def _native_signal(
        key: str,
        name: str,
        unit: str,
        minimum: float,
        maximum: float,
        *,
        integer_only: bool = False,
    ) -> dict[str, Any]:
        return {
            "key": key,
            "name": key,
            "display_name": name,
            "start": 0,
            "length": 0,
            "byte_order": "little_endian",
            "is_signed": False,
            "scale": 1,
            "offset": 0,
            "minimum": minimum,
            "maximum": maximum,
            "unit": unit,
            "is_multiplexer": False,
            "multiplexer_signal": None,
            "multiplexer_ids": [],
            "integer_only": integer_only,
        }

    def _add_native(
        self,
        *,
        can_id: int,
        channel: CanChannel,
        name: str,
        signals: list[dict[str, Any]],
        payload: bytes,
        simulation_rates: Mapping[int, float],
        version: str,
    ) -> None:
        key = canonical_can_key(can_id)
        capable = can_id in simulation_rates
        self.entries[key] = _ConsoleEntry(
            key=key,
            can_id=can_id,
            is_extended=can_id > 0x7FF,
            name=name,
            length=len(payload),
            channel=channel,
            signals=signals,
            descriptor_fingerprint=hashlib.sha256(
                f"{version}:{channel}".encode("ascii")
            ).hexdigest(),
            simulation_capable=capable,
            simulation_frequency_hz=simulation_rates.get(can_id),
            authority="simulation" if self.mode == "godot-managed" and capable else "off",
            payload=payload,
        )

    def _catalog_fingerprint(self) -> str:
        material = "\n".join(
            f"{key}:{entry.descriptor_fingerprint}" for key, entry in sorted(self.entries.items())
        )
        return hashlib.sha256(material.encode("ascii")).hexdigest()

    def _restore(self, persisted: Mapping[str, Any]) -> None:
        # Schema 1/2 were restored by OperatorDbcRuntime. Schema 3 had no
        # channel identity and therefore resets safely after the DHC remap.
        schema = persisted.get("schema_version")
        if schema not in (3, CONSOLE_SCHEMA_VERSION):
            return
        records = persisted.get("messages")
        if not isinstance(records, Mapping):
            return
        migrated = 0
        reset: list[str] = []
        for key, entry in self.entries.items():
            record = records.get(key)
            if not isinstance(record, Mapping):
                reset.append(key)
                continue
            try:
                self._apply_record(entry, self._migration_record(entry, record, schema))
                self._sync_operator(entry)
                migrated += 1
            except GatewayRuntimeError:
                reset.append(key)
                continue
        removed = sorted(set(records) - set(self.entries))
        if schema == 3 or reset or removed:
            self.migration_notices.append(
                {
                    "code": "console_profile_migrated",
                    "migrated": migrated,
                    "reset": len(reset),
                    "added": sum(1 for key in reset if key not in records),
                    "removed": len(removed),
                    "reset_keys": reset,
                }
            )
            try:
                self.store.save(self.catalog_fingerprint, self.entries)
            except OSError:
                self.migration_notices.append(
                    {"code": "console_profile_migration_write_failed"}
                )

    @staticmethod
    def _migration_record(
        entry: _ConsoleEntry, record: Mapping[str, Any], schema: object
    ) -> Mapping[str, Any]:
        """Admit the one schema-3 native descriptor whose wire contract is unchanged."""
        if (
            schema in (1, 3)
            and record.get("descriptor_fingerprint")
            in {
                hashlib.sha256(b"travel-pilot-v1").hexdigest()
                if entry.can_id == TRAVEL_CAN_ID
                else "",
                LEGACY_SCHEMA3_COMPATIBLE_FINGERPRINTS.get(entry.can_id, ""),
            }
        ):
            migrated = dict(record)
            migrated["descriptor_fingerprint"] = entry.descriptor_fingerprint
            return migrated
        return record

    def _apply_record(self, entry: _ConsoleEntry, record: Mapping[str, Any]) -> None:
        allowed = {
            "descriptor_fingerprint",
            "authority",
            "payload_hex",
            "frequency_hz",
        }
        if set(record) != allowed:
            raise GatewayRuntimeError(
                "console_profile_invalid", "profile message fields are incomplete or unknown"
            )
        if record.get("descriptor_fingerprint") != entry.descriptor_fingerprint:
            raise GatewayRuntimeError(
                "console_profile_incompatible", "message fingerprint mismatch"
            )
        authority = record.get("authority")
        if authority not in ("off", "custom"):
            raise GatewayRuntimeError(
                "console_authority_invalid", "stored authority must be off/custom"
            )
        frequency = record.get("frequency_hz")
        self._validate_frequency(frequency)
        payload_hex = record.get("payload_hex")
        payload, _values = self._normalize(entry, payload_hex=payload_hex)
        entry.authority = authority
        entry.frequency_hz = frequency
        entry.payload = payload

    @staticmethod
    def _validate_frequency(value: object) -> None:
        if (
            not isinstance(value, int)
            or isinstance(value, bool)
            or not MIN_FREQUENCY_HZ <= value <= MAX_FREQUENCY_HZ
        ):
            raise GatewayRuntimeError(
                "dbc_frequency_invalid", "frequency_hz must be 1..100 integer"
            )

    def _entry(self, key: str) -> _ConsoleEntry:
        try:
            return self.entries[key]
        except KeyError as exc:
            raise GatewayRuntimeError(
                "console_message_unknown", "CAN console message is not active"
            ) from exc

    def _values(self, entry: _ConsoleEntry, payload: bytes | None = None) -> dict[str, float]:
        value = entry.payload if payload is None else payload
        if entry.dbc_key is not None:
            return self.operator.codec.decode(entry.dbc_key, value)
        if entry.can_id == TIMED_CAN_ID:
            return {}
        left, right = decode_travel(value)
        return {"left_pressure": float(left), "right_pressure": float(right)}

    def _normalize(
        self,
        entry: _ConsoleEntry,
        *,
        values: Mapping[str, Any] | None = None,
        payload_hex: object = None,
    ) -> tuple[bytes, dict[str, float]]:
        if (values is None) == (payload_hex is None):
            raise GatewayRuntimeError(
                "dbc_edit_source_invalid", "provide exactly one of values or payload_hex"
            )
        if entry.dbc_key is not None:
            if values is not None:
                return self.operator.codec.merge_values(entry.dbc_key, entry.payload, values)
            return self.operator.codec.normalize_payload(entry.dbc_key, payload_hex)
        if values is not None:
            if entry.can_id == TIMED_CAN_ID:
                if values:
                    raise GatewayRuntimeError(
                        "dbc_signal_unknown", "timed CAN has no physical signal definition"
                    )
                return entry.payload, {}
            current = self._values(entry)
            unknown = set(values) - set(current)
            if unknown:
                raise GatewayRuntimeError(
                    "dbc_signal_unknown", f"unknown signal {sorted(unknown)[0]!r}"
                )
            merged = {**current, **values}
            for name, value in merged.items():
                if (
                    not isinstance(value, (int, float))
                    or isinstance(value, bool)
                    or not math.isfinite(value)
                ):
                    raise GatewayRuntimeError("dbc_value_invalid", f"{name} must be finite")
            integer_fields = {"left_pressure", "right_pressure"}
            for name in integer_fields:
                if not float(merged[name]).is_integer():
                    raise GatewayRuntimeError(
                        "dbc_value_invalid", f"{name} must be an integer"
                    )
            left, right = int(merged["left_pressure"]), int(merged["right_pressure"])
            if not 0 <= left <= 50 or not 0 <= right <= 50:
                raise GatewayRuntimeError(
                    "dbc_value_out_of_range", "native value is outside its range"
                )
            payload = encode_travel_frame(left, right)
            return payload, self._values(entry, payload)
        if not isinstance(payload_hex, str):
            raise GatewayRuntimeError("dbc_payload_invalid", "payload_hex must be a string")
        compact = "".join(payload_hex.split())
        try:
            payload = bytes.fromhex(compact)
        except ValueError as exc:
            raise GatewayRuntimeError("dbc_payload_invalid", "payload is not hexadecimal") from exc
        if len(payload) != entry.length:
            raise GatewayRuntimeError(
                "dbc_payload_invalid", f"payload must be exactly {entry.length} bytes"
            )
        return payload, self._values(entry, payload)

    def preview(
        self,
        key: str,
        *,
        values: Mapping[str, Any] | None = None,
        payload_hex: object = None,
    ) -> dict[str, Any]:
        entry = self._entry(key)
        if entry.authority != "custom":
            raise GatewayRuntimeError(
                "console_message_not_custom",
                "message must use custom authority before editing",
                status=409,
            )
        payload, normalized = self._normalize(entry, values=values, payload_hex=payload_hex)
        return {"values": normalized, "payload_hex": " ".join(f"{byte:02X}" for byte in payload)}

    def update(
        self,
        key: str,
        *,
        values: Mapping[str, Any] | None = None,
        payload_hex: object = None,
        frequency_hz: object = None,
    ) -> dict[str, Any]:
        entry = self._entry(key)
        if entry.authority != "custom":
            raise GatewayRuntimeError(
                "console_message_not_custom",
                "message must use custom authority before editing",
                status=409,
            )
        frequency = entry.frequency_hz if frequency_hz is None else frequency_hz
        self._validate_frequency(frequency)
        if values is None and payload_hex is None:
            payload, normalized = entry.payload, self._values(entry)
        else:
            payload, normalized = self._normalize(entry, values=values, payload_hex=payload_hex)
        old_payload, old_frequency = entry.payload, entry.frequency_hz
        old_operator = self._operator_state(entry)
        entry.payload, entry.frequency_hz = payload, frequency
        self._sync_operator(entry)
        self._update_schedule(entry)
        try:
            self._persist()
        except OSError as exc:
            entry.payload, entry.frequency_hz = old_payload, old_frequency
            self._restore_operator(entry, old_operator)
            self._update_schedule(entry)
            raise GatewayRuntimeError(
                "dbc_config_write_failed",
                "CAN console configuration could not be persisted",
                status=500,
            ) from exc
        return self._row(entry, normalized)

    def set_authority(self, key: str, authority: object) -> dict[str, Any]:
        entry = self._entry(key)
        if authority not in AUTHORITIES:
            raise GatewayRuntimeError(
                "console_authority_invalid", "authority must be off/custom/simulation"
            )
        if authority == "simulation" and not entry.simulation_capable:
            raise GatewayRuntimeError(
                "console_simulation_unavailable", "message has no simulation producer", status=409
            )
        if self.mode == "standalone" and authority == "simulation":
            raise GatewayRuntimeError(
                "console_simulation_unavailable",
                "simulation is unavailable in standalone mode",
                status=409,
            )
        previous = entry.authority
        old_operator = self._operator_state(entry)
        entry.authority = authority
        self._sync_operator(entry)
        self._update_schedule(entry)
        try:
            self._persist()
        except OSError as exc:
            entry.authority = previous
            self._restore_operator(entry, old_operator)
            self._update_schedule(entry)
            raise GatewayRuntimeError(
                "dbc_config_write_failed",
                "CAN console configuration could not be persisted",
                status=500,
            ) from exc
        return self._row(entry)

    def set_all_authority(self, authority: object) -> dict[str, Any]:
        """Atomically apply one authority to the complete active catalog."""
        if authority not in AUTHORITIES:
            raise GatewayRuntimeError(
                "console_authority_invalid", "authority must be off/custom/simulation"
            )
        if self.mode == "standalone" and authority == "simulation":
            raise GatewayRuntimeError(
                "console_simulation_unavailable",
                "simulation is unavailable in standalone mode",
                status=409,
            )
        previous = {key: entry.authority for key, entry in self.entries.items()}
        operator_states = {
            key: self._operator_state(entry) for key, entry in self.entries.items()
        }
        forced_off: list[str] = []
        for key, entry in self.entries.items():
            if authority == "simulation" and not entry.simulation_capable:
                entry.authority = "off"
                forced_off.append(key)
            else:
                entry.authority = authority
            self._sync_operator(entry)
        self._replace_schedule()
        try:
            self._persist()
        except OSError as exc:
            for key, entry in self.entries.items():
                entry.authority = previous[key]
                self._restore_operator(entry, operator_states[key])
            self._replace_schedule()
            raise GatewayRuntimeError(
                "dbc_config_write_failed",
                "CAN console configuration could not be persisted",
                status=500,
            ) from exc
        return {
            "authority": authority,
            "forced_off": forced_off,
            "snapshot": self.snapshot(),
        }

    def _sync_operator(self, entry: _ConsoleEntry) -> None:
        if entry.dbc_key is None:
            return
        draft = self.operator.drafts[entry.dbc_key]
        draft.payload = entry.payload
        draft.frequency_hz = entry.frequency_hz
        draft.enabled = entry.authority == "custom"
        draft.generated_default = False

    def _operator_state(self, entry: _ConsoleEntry) -> tuple[bytes, int, bool, bool] | None:
        if entry.dbc_key is None:
            return None
        draft = self.operator.drafts[entry.dbc_key]
        return draft.payload, draft.frequency_hz, draft.enabled, draft.generated_default

    def _restore_operator(
        self,
        entry: _ConsoleEntry,
        state: tuple[bytes, int, bool, bool] | None,
    ) -> None:
        if entry.dbc_key is None or state is None:
            return
        draft = self.operator.drafts[entry.dbc_key]
        draft.payload, draft.frequency_hz, draft.enabled, draft.generated_default = state

    def _schedule_entry(self, entry: _ConsoleEntry) -> _ScheduleEntry:
        return _ScheduleEntry(
            entry.can_id,
            entry.is_extended,
            entry.payload,
            entry.frequency_hz,
        )

    def _replace_schedule(self) -> None:
        self.scheduler.replace(
            {
                key: self._schedule_entry(entry)
                for key, entry in self.entries.items()
                if entry.authority == "custom"
            }
        )
        if self.mode == "godot-managed" and any(
            entry.authority == "custom" for entry in self.entries.values()
        ):
            self.scheduler.start()

    def _update_schedule(self, entry: _ConsoleEntry) -> None:
        self.scheduler.update(
            entry.key,
            self._schedule_entry(entry) if entry.authority == "custom" else None,
        )
        if self.mode == "godot-managed":
            has_custom = any(item.authority == "custom" for item in self.entries.values())
            if has_custom and not self.scheduler.armed:
                self.scheduler.start()
            elif not has_custom:
                self.scheduler.disarm()

    def start(self, *, transport_ready: bool) -> None:
        if self.mode != "standalone":
            raise GatewayRuntimeError(
                "managed_command_forbidden", "global custom arm is standalone-only", status=403
            )
        if not transport_ready:
            raise GatewayRuntimeError(
                "transport_not_ready",
                "platform transport is not ready for custom sending",
                status=409,
            )
        self.scheduler.start()

    def stop(self) -> None:
        self.scheduler.disarm()

    def reset_managed_overrides(self) -> None:
        if self.mode != "godot-managed":
            self.stop()
            return
        for entry in self.entries.values():
            entry.authority = "simulation" if entry.simulation_capable else "off"
            self._sync_operator(entry)
        self._replace_schedule()

    def allows(self, source: str, can_id: int, is_extended: bool | None = None) -> bool:
        entry = self.entries.get(canonical_can_key(can_id, is_extended))
        if entry is None:
            return True
        expected: Authority = "simulation" if source in ("godot", "timed") else "custom"
        return entry.authority == expected

    def decode_egress(
        self,
        can_id: int,
        payload: bytes,
        *,
        is_extended: bool | None = None,
    ) -> dict[str, float] | None:
        entry = self.entries.get(canonical_can_key(can_id, is_extended))
        if entry is None:
            return None
        try:
            return self._values(entry, payload)
        except (GatewayRuntimeError, IndexError, ValueError):
            return None

    def service(self, send: Callable[[str, int, bytes], None], now_s: float) -> int:
        return self.scheduler.service(send, now_s)

    def timeout_s(self) -> float:
        return self.scheduler.timeout_s()

    def _persist(self) -> None:
        if self.mode == "standalone":
            self.store.save(self.catalog_fingerprint, self.entries)

    def export_profile(self) -> dict[str, Any]:
        if self.mode != "standalone":
            raise GatewayRuntimeError(
                "managed_command_forbidden", "profile export is standalone-only", status=403
            )
        return {
            "format": PORTABLE_FORMAT,
            "schema_version": PORTABLE_SCHEMA_VERSION,
            "catalog_fingerprint": self.catalog_fingerprint,
            "messages": {
                key: {
                    "descriptor_fingerprint": entry.descriptor_fingerprint,
                    "authority": entry.authority,
                    "payload_hex": entry.payload.hex().upper(),
                    "frequency_hz": entry.frequency_hz,
                }
                for key, entry in sorted(self.entries.items())
            },
        }

    def import_profile(self, profile: Mapping[str, Any]) -> None:
        if self.mode != "standalone":
            raise GatewayRuntimeError(
                "managed_command_forbidden", "profile import is standalone-only", status=403
            )
        if set(profile) != {
            "format",
            "schema_version",
            "catalog_fingerprint",
            "messages",
        }:
            raise GatewayRuntimeError(
                "console_profile_invalid", "profile fields are incomplete or unknown"
            )
        schema = profile.get("schema_version")
        if profile.get("format") != PORTABLE_FORMAT or schema not in (
            1,
            PORTABLE_SCHEMA_VERSION,
        ):
            raise GatewayRuntimeError("console_profile_invalid", "unsupported CAN console profile")
        if (
            schema == PORTABLE_SCHEMA_VERSION
            and profile.get("catalog_fingerprint") != self.catalog_fingerprint
        ):
            raise GatewayRuntimeError(
                "console_profile_incompatible",
                "profile catalog fingerprint does not match",
                status=409,
            )
        records = profile.get("messages")
        if not isinstance(records, Mapping) or (
            schema == PORTABLE_SCHEMA_VERSION and set(records) != set(self.entries)
        ):
            raise GatewayRuntimeError(
                "console_profile_invalid", "profile must contain the complete message catalog"
            )
        candidates: dict[str, _ConsoleEntry] = {}
        migrated = 0
        reset_keys: list[str] = []
        for key, entry in self.entries.items():
            record = records.get(key)
            if schema == 1 and not isinstance(record, Mapping):
                candidates[key] = _ConsoleEntry(**entry.__dict__)
                reset_keys.append(key)
                continue
            if not isinstance(record, Mapping):
                raise GatewayRuntimeError(
                    "console_profile_invalid", "profile message must be an object"
                )
            clone = _ConsoleEntry(**entry.__dict__)
            try:
                self._apply_record(clone, self._migration_record(clone, record, schema))
                migrated += 1
            except GatewayRuntimeError:
                if schema != 1:
                    raise
                reset_keys.append(key)
            candidates[key] = clone
        try:
            self.store.save(self.catalog_fingerprint, candidates)
        except OSError as exc:
            raise GatewayRuntimeError(
                "dbc_config_write_failed",
                "CAN console configuration could not be persisted",
                status=500,
            ) from exc
        for key, candidate in candidates.items():
            entry = self.entries[key]
            entry.authority = candidate.authority
            entry.frequency_hz = candidate.frequency_hz
            entry.payload = candidate.payload
            self._sync_operator(entry)
        if schema == 1:
            self.migration_notices = [
                {
                    "code": "console_profile_import_migrated",
                    "migrated": migrated,
                    "reset": len(reset_keys),
                    "added": sum(1 for key in reset_keys if key not in records),
                    "removed": len(set(records) - set(self.entries)),
                    "reset_keys": reset_keys,
                }
            ]
        # A successful full-profile replacement is deliberately disarmed;
        # validation or persistence failures above leave all live state intact.
        self._replace_schedule()

    def snapshot(self) -> dict[str, Any]:
        rows = [
            self._row(entry)
            for entry in sorted(self.entries.values(), key=lambda item: (item.can_id, item.name))
        ]
        # Reuse the existing estimator by projecting the DBC drafts; native
        # frames are added with the same conservative classical-CAN formula.
        load = estimate_bus_load(self.operator.drafts, self.operator.codec)
        native_bits = 0
        for entry in self.entries.values():
            if entry.dbc_key is not None or entry.authority != "custom":
                continue
            stuffed_region = (54 if entry.is_extended else 34) + 8 * entry.length
            native_bits += (
                stuffed_region + max(0, (stuffed_region - 1) // 4) + 13
            ) * entry.frequency_hz
        if native_bits:
            total = load["estimated_bits_per_second"] + native_bits
            percent = total / load["bitrate"] * 100.0
            load.update(
                estimated_bits_per_second=total,
                percent=round(percent, 2),
                level="red" if percent >= 90 else "yellow" if percent >= 70 else "normal",
                warning=percent >= 70,
            )
        return {
            "catalog_fingerprint": self.catalog_fingerprint,
            "custom_armed": self.armed,
            "messages": rows,
            "notices": list(self.migration_notices),
            "load": load,
        }

    def _row(
        self, entry: _ConsoleEntry, values: Mapping[str, float] | None = None
    ) -> dict[str, Any]:
        expected = (
            entry.frequency_hz
            if entry.authority == "custom"
            else entry.simulation_frequency_hz
            if entry.authority == "simulation"
            else 0
        )
        return {
            "key": entry.key,
            "message": entry.definition_dict(),
            "values": dict(values) if values is not None else self._values(entry),
            "payload_hex": " ".join(f"{byte:02X}" for byte in entry.payload),
            "frequency_hz": entry.frequency_hz,
            "authority": entry.authority,
            "expected_frequency_hz": expected,
            "simulation_capable": entry.simulation_capable,
            "simulation_available": self.mode == "godot-managed" and entry.simulation_capable,
        }
