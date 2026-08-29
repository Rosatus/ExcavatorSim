"""Strict DBC catalogs, physical-value drafts, and periodic transmission state."""

from __future__ import annotations

import hashlib
import json
import math
import os
import re
import time
import uuid
from collections.abc import Callable, Iterable, Mapping
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import cantools
from cantools.database.errors import DecodeError, EncodeError
from gateway_runtime import GatewayRuntimeError
from platformdirs import user_config_path

DEFAULT_FREQUENCY_HZ = 50
MIN_FREQUENCY_HZ = 1
MAX_FREQUENCY_HZ = 100
CAN_BITRATE = 250_000
DBC_CONFIG_SCHEMA = 2
PROTOCOL_DBC_HASHES = {
    "can3.sy135c.dbc": "c589bcaeda9b58a87e7b0ed920b7fbb55b86942341f4126d44f7f5017a7c4a44",
    "can4.sy135c.dbc": "cb71e5bec346940e84f1a24e7e3c6d6ef7191545e8f7b1dbba10a241174234f7",
}
RTK_FRAME_IDS = tuple(0x0CFDA000 + offset * 0x100 for offset in range(10))
IMU_ANGLE_FRAME_IDS = (0x18FF3A00, 0x18FF3B00, 0x18FF3C00, 0x18FF3D00)
GPS_EPOCH_UNIX_S = 315_964_800.0


@dataclass(frozen=True)
class DbcNotice:
    code: str
    detail: str
    source: str = ""

    def to_dict(self) -> dict[str, str]:
        return asdict(self)


@dataclass(frozen=True)
class DbcSignalDefinition:
    key: str
    name: str
    start: int
    length: int
    byte_order: str
    is_signed: bool
    scale: float
    offset: float
    minimum: float | None
    maximum: float | None
    unit: str
    is_multiplexer: bool
    multiplexer_signal: str | None
    multiplexer_ids: tuple[int, ...]

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


@dataclass(frozen=True)
class DbcMessageDefinition:
    key: str
    file_sha256: str
    name: str
    frame_id: int
    is_extended: bool
    length: int
    signals: tuple[DbcSignalDefinition, ...]

    @property
    def normalized_id(self) -> tuple[int, bool]:
        return self.frame_id, self.is_extended

    def to_dict(self) -> dict[str, Any]:
        data = asdict(self)
        data["frame_id_hex"] = f"0x{self.frame_id:X}"
        return data


@dataclass(frozen=True)
class DbcFileDefinition:
    sha256: str
    sources: tuple[str, ...]
    messages: tuple[DbcMessageDefinition, ...]
    parse_error: str = ""

    def to_dict(self) -> dict[str, Any]:
        return {
            "sha256": self.sha256,
            "sources": list(self.sources),
            "messages": [message.to_dict() for message in self.messages],
            "parse_error": self.parse_error,
        }


@dataclass(frozen=True)
class DbcCatalogSnapshot:
    files: tuple[DbcFileDefinition, ...]
    notices: tuple[DbcNotice, ...]

    @property
    def messages(self) -> tuple[DbcMessageDefinition, ...]:
        return tuple(message for file in self.files for message in file.messages)

    def to_dict(self) -> dict[str, Any]:
        return {
            "files": [file.to_dict() for file in self.files],
            "notices": [notice.to_dict() for notice in self.notices],
            "message_count": len(self.messages),
        }


def _finite_float(value: Any, *, field: str) -> float:
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise GatewayRuntimeError("dbc_value_invalid", f"{field} must be numeric")
    result = float(value)
    if not math.isfinite(result):
        raise GatewayRuntimeError("dbc_value_invalid", f"{field} must be finite")
    return result


def _json_number(value: Any) -> float | None:
    return None if value is None else float(value)


def _signal_definition(signal: Any) -> DbcSignalDefinition:
    identity = json.dumps(
        {
            "name": signal.name,
            "start": signal.start,
            "length": signal.length,
            "byte_order": signal.byte_order,
            "signed": signal.is_signed,
            "scale": float(signal.scale),
            "offset": float(signal.offset),
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    return DbcSignalDefinition(
        key=hashlib.sha256(identity.encode("utf-8")).hexdigest(),
        name=signal.name,
        start=signal.start,
        length=signal.length,
        byte_order=signal.byte_order,
        is_signed=signal.is_signed,
        scale=float(signal.scale),
        offset=float(signal.offset),
        minimum=_json_number(signal.minimum),
        maximum=_json_number(signal.maximum),
        unit=signal.unit or "",
        is_multiplexer=signal.is_multiplexer,
        multiplexer_signal=signal.multiplexer_signal,
        multiplexer_ids=tuple(signal.multiplexer_ids or ()),
    )


def _message_definition(message: Any, content_hash: str) -> DbcMessageDefinition:
    signals = tuple(_signal_definition(signal) for signal in message.signals)
    layout = json.dumps(
        {
            "name": message.name,
            "frame_id": message.frame_id,
            "extended": message.is_extended_frame,
            "length": message.length,
            "signals": [signal.key for signal in signals],
        },
        sort_keys=True,
        separators=(",", ":"),
    )
    layout_hash = hashlib.sha256(layout.encode("utf-8")).hexdigest()
    key = f"{content_hash}:{message.frame_id:X}:{int(message.is_extended_frame)}:{layout_hash}"
    return DbcMessageDefinition(
        key=key,
        file_sha256=content_hash,
        name=message.name,
        frame_id=message.frame_id,
        is_extended=message.is_extended_frame,
        length=message.length,
        signals=signals,
    )


def _decode_dbc_text(data: bytes) -> tuple[str, str]:
    """Decode one DBC without cantools' replacement-character fallback."""
    try:
        return data.decode("utf-8-sig", errors="strict"), "utf-8"
    except UnicodeDecodeError as utf8_error:
        try:
            return data.decode("cp1252", errors="strict"), "cp1252"
        except UnicodeDecodeError as cp1252_error:
            raise UnicodeDecodeError(
                "utf-8/cp1252",
                data,
                min(utf8_error.start, cp1252_error.start),
                max(utf8_error.end, cp1252_error.end),
                "DBC bytes are neither strict UTF-8 nor strict CP1252",
            ) from cp1252_error


class DbcCatalog:
    """Deterministic direct-child discovery with content deduplication."""

    def __init__(self, snapshot: DbcCatalogSnapshot, native_messages: Mapping[str, Any]) -> None:
        self.snapshot = snapshot
        self.native_messages = dict(native_messages)

    @classmethod
    def discover(cls, roots: Iterable[Path]) -> DbcCatalog:
        normalized_roots: list[Path] = []
        seen_roots: set[str] = set()
        for root in roots:
            resolved = root.expanduser().resolve()
            key = os.path.normcase(str(resolved))
            if key not in seen_roots:
                seen_roots.add(key)
                normalized_roots.append(resolved)

        content_sources: dict[str, list[Path]] = {}
        content_bytes: dict[str, bytes] = {}
        notices: list[DbcNotice] = []
        for root in normalized_roots:
            if not root.is_dir():
                notices.append(
                    DbcNotice("dbc_root_missing", "DBC directory does not exist", str(root))
                )
                continue
            candidates = sorted(
                (
                    path
                    for path in root.iterdir()
                    if path.is_file() and path.suffix.lower() == ".dbc"
                ),
                key=lambda path: (path.name.casefold(), os.path.normcase(str(path))),
            )
            for path in candidates:
                try:
                    raw = path.read_bytes()
                    digest = hashlib.sha256(raw).hexdigest()
                except OSError as exc:
                    notices.append(DbcNotice("dbc_read_failed", str(exc), str(path)))
                    continue
                content_sources.setdefault(digest, []).append(path)
                content_bytes.setdefault(digest, raw)

        files: list[DbcFileDefinition] = []
        natives: dict[str, Any] = {}
        for digest, paths in sorted(
            content_sources.items(), key=lambda item: os.path.normcase(str(item[1][0]))
        ):
            sources = tuple(sorted((str(path) for path in paths), key=os.path.normcase))
            try:
                text, encoding = _decode_dbc_text(content_bytes[digest])
                database = cantools.database.load_string(text, database_format="dbc", strict=True)
                message_pairs = [
                    (_message_definition(message, digest), message) for message in database.messages
                ]
                message_pairs.sort(
                    key=lambda pair: (
                        pair[0].frame_id,
                        not pair[0].is_extended,
                        pair[0].name.casefold(),
                        pair[0].key,
                    )
                )
                definitions = tuple(pair[0] for pair in message_pairs)
                natives.update({definition.key: native for definition, native in message_pairs})
                files.append(DbcFileDefinition(digest, sources, definitions))
                if encoding == "cp1252":
                    notices.append(
                        DbcNotice(
                            "dbc_encoding_fallback",
                            "decoded as CP1252 after strict UTF-8 decoding failed",
                            sources[0],
                        )
                    )
            except Exception as exc:
                detail = f"{type(exc).__name__}: {exc}"
                files.append(DbcFileDefinition(digest, sources, (), detail))
                notices.append(DbcNotice("dbc_parse_failed", detail, sources[0]))
        return cls(DbcCatalogSnapshot(tuple(files), tuple(notices)), natives)


class DbcCodec:
    """Cached strict encoder/decoder over one immutable catalog snapshot."""

    def __init__(self, catalog: DbcCatalog) -> None:
        self.catalog = catalog
        self.messages = {message.key: message for message in catalog.snapshot.messages}
        self._by_frame: dict[tuple[int, bool], list[DbcMessageDefinition]] = {}
        for message in self.messages.values():
            self._by_frame.setdefault(message.normalized_id, []).append(message)

    def unique_message_by_frame(
        self, frame_id: int, *, is_extended: bool = True
    ) -> DbcMessageDefinition:
        matches = self._by_frame.get((frame_id, is_extended), [])
        if len(matches) != 1:
            raise GatewayRuntimeError(
                "dbc_frame_ambiguous",
                f"expected one DBC definition for 0x{frame_id:X}, found {len(matches)}",
                status=409,
            )
        return matches[0]

    def generated_defaults(self, message_key: str) -> dict[str, float]:
        self._definition(message_key)
        native = self.catalog.native_messages[message_key]
        values: dict[str, float] = {}
        multiplexers: dict[str, int] = {}
        for signal in native.signals:
            if signal.is_multiplexer:
                default_value = self._default_value(signal)
                values[signal.name] = default_value
                multiplexers[signal.name] = self._multiplexer_raw(signal, default_value)
        for signal in native.signals:
            if signal.is_multiplexer:
                continue
            if signal.multiplexer_signal is not None:
                selected = multiplexers.get(signal.multiplexer_signal)
                if selected not in (signal.multiplexer_ids or []):
                    continue
            values[signal.name] = self._default_value(signal)
        self.encode(message_key, values)
        return values

    def encode(self, message_key: str, physical_values: Mapping[str, Any]) -> bytes:
        definition = self._definition(message_key)
        native = self.catalog.native_messages[message_key]
        known = {signal.name: signal for signal in native.signals}
        values: dict[str, float] = {}
        for name, raw_value in physical_values.items():
            signal = known.get(name)
            if signal is None:
                raise GatewayRuntimeError(
                    "dbc_signal_unknown", f"{definition.name} has no signal {name!r}"
                )
            value = _finite_float(raw_value, field=name)
            if signal.minimum is not None and value < float(signal.minimum) - 1e-12:
                raise GatewayRuntimeError(
                    "dbc_value_out_of_range", f"{name} is below {float(signal.minimum):g}"
                )
            if signal.maximum is not None and value > float(signal.maximum) + 1e-12:
                raise GatewayRuntimeError(
                    "dbc_value_out_of_range", f"{name} is above {float(signal.maximum):g}"
                )
            values[name] = value
        try:
            encoded = native.encode(values, scaling=True, padding=False, strict=True)
        except (EncodeError, DecodeError, ValueError, TypeError, OverflowError) as exc:
            raise GatewayRuntimeError("dbc_encode_failed", str(exc)) from exc
        if len(encoded) != definition.length:
            raise GatewayRuntimeError("dbc_dlc_mismatch", "DBC encoder returned an invalid DLC")
        return encoded

    def decode(self, message_key: str, payload: bytes) -> dict[str, float]:
        definition = self._definition(message_key)
        if len(payload) != definition.length:
            raise GatewayRuntimeError(
                "dbc_dlc_mismatch",
                f"payload must contain exactly {definition.length} bytes",
            )
        native = self.catalog.native_messages[message_key]
        try:
            decoded = native.decode(
                payload,
                decode_choices=False,
                scaling=True,
                allow_truncated=False,
                allow_excess=False,
            )
        except (DecodeError, ValueError, TypeError, OverflowError) as exc:
            raise GatewayRuntimeError("dbc_decode_failed", str(exc)) from exc
        if not isinstance(decoded, Mapping):
            raise GatewayRuntimeError("dbc_decode_failed", "DBC decoder returned invalid data")
        values: dict[str, float] = {}
        for name, raw_value in decoded.items():
            try:
                values[str(name)] = _finite_float(raw_value, field=str(name))
            except GatewayRuntimeError as exc:
                raise GatewayRuntimeError("dbc_decode_failed", str(exc)) from exc
        return values

    def parse_payload_hex(self, message_key: str, payload_hex: Any) -> bytes:
        definition = self._definition(message_key)
        if not isinstance(payload_hex, str):
            raise GatewayRuntimeError("dbc_payload_invalid", "payload_hex must be a string")
        stripped = payload_hex.strip()
        if not stripped or "0x" in stripped.lower():
            raise GatewayRuntimeError(
                "dbc_payload_invalid", "payload must be hexadecimal bytes without a prefix"
            )
        if re.search(r"\s", stripped):
            tokens = stripped.split()
            if any(re.fullmatch(r"[0-9A-Fa-f]{2}", token) is None for token in tokens):
                raise GatewayRuntimeError(
                    "dbc_payload_invalid", "spaced payload must contain two hex digits per byte"
                )
            compact = "".join(tokens)
        else:
            compact = stripped
            if len(compact) % 2 or re.fullmatch(r"[0-9A-Fa-f]+", compact) is None:
                raise GatewayRuntimeError(
                    "dbc_payload_invalid", "payload must contain an even number of hex digits"
                )
        try:
            payload = bytes.fromhex(compact)
        except ValueError as exc:
            raise GatewayRuntimeError(
                "dbc_payload_invalid", "payload contains invalid hex"
            ) from exc
        if len(payload) != definition.length:
            raise GatewayRuntimeError(
                "dbc_dlc_mismatch",
                f"payload must contain exactly {definition.length} bytes",
            )
        return payload

    def merge_values(
        self,
        message_key: str,
        base_payload: bytes,
        edits: Mapping[str, Any],
    ) -> tuple[bytes, dict[str, float]]:
        if not isinstance(edits, Mapping):
            raise GatewayRuntimeError("dbc_values_invalid", "values must be an object")
        current = self.decode(message_key, base_payload)
        combined: dict[str, Any] = {**current, **edits}
        active = self._active_values(message_key, combined)
        encoded = self.encode(message_key, active)
        signal_names = set(active)
        native = self.catalog.native_messages[message_key]
        changed_multiplexers = {
            signal.name
            for signal in native.signals
            if signal.is_multiplexer
            and signal.name in current
            and signal.name in active
            and self._multiplexer_raw(signal, current[signal.name])
            != self._multiplexer_raw(signal, active[signal.name])
        }
        if changed_multiplexers:
            signal_names.update(
                signal.name
                for signal in native.signals
                if signal.multiplexer_signal in changed_multiplexers
            )
        mask = self._signal_mask(message_key, signal_names)
        merged = bytes(
            (old & (~owned & 0xFF)) | (new & owned)
            for old, new, owned in zip(base_payload, encoded, mask, strict=True)
        )
        return merged, self.decode(message_key, merged)

    def normalize_payload(
        self, message_key: str, payload_hex: Any
    ) -> tuple[bytes, dict[str, float]]:
        payload = self.parse_payload_hex(message_key, payload_hex)
        return payload, self.decode(message_key, payload)

    @staticmethod
    def format_payload(payload: bytes) -> str:
        return " ".join(f"{byte:02X}" for byte in payload)

    def encode_frame(
        self, frame_id: int, physical_values: Mapping[str, Any], *, is_extended: bool = True
    ) -> bytes:
        return self.encode(
            self.unique_message_by_frame(frame_id, is_extended=is_extended).key,
            physical_values,
        )

    def _definition(self, message_key: str) -> DbcMessageDefinition:
        try:
            return self.messages[message_key]
        except KeyError as exc:
            raise GatewayRuntimeError(
                "dbc_message_unknown", "DBC message key is not active"
            ) from exc

    def _active_values(self, message_key: str, supplied: Mapping[str, Any]) -> dict[str, float]:
        definition = self._definition(message_key)
        native = self.catalog.native_messages[message_key]
        known = {signal.name: signal for signal in native.signals}
        unknown = sorted(set(supplied) - set(known))
        if unknown:
            raise GatewayRuntimeError(
                "dbc_signal_unknown", f"{definition.name} has no signal {unknown[0]!r}"
            )
        multiplexers: dict[str, int] = {}
        for signal in native.signals:
            if not signal.is_multiplexer:
                continue
            raw_value = supplied.get(signal.name, self._default_value(signal))
            value = _finite_float(raw_value, field=signal.name)
            multiplexers[signal.name] = self._multiplexer_raw(signal, value)
        active: dict[str, Any] = {}
        for signal in native.signals:
            if signal.multiplexer_signal is not None:
                selected = multiplexers.get(signal.multiplexer_signal)
                if selected not in (signal.multiplexer_ids or []):
                    continue
            active[signal.name] = supplied.get(signal.name, self._default_value(signal))
        # Reuse encode validation to normalize numeric types and enforce ranges.
        encoded = self.encode(message_key, active)
        return self.decode(message_key, encoded)

    def _signal_mask(self, message_key: str, signal_names: set[str]) -> bytes:
        definition = self._definition(message_key)
        mask = bytearray(definition.length)
        for signal in definition.signals:
            if signal.name not in signal_names:
                continue
            bit = signal.start
            for _ in range(signal.length):
                byte_index = bit // 8
                if byte_index < 0 or byte_index >= definition.length:
                    raise GatewayRuntimeError(
                        "dbc_signal_layout_invalid", f"{signal.name} lies outside the payload"
                    )
                mask[byte_index] |= 1 << (bit % 8)
                if signal.byte_order == "little_endian":
                    bit += 1
                else:
                    bit = bit + 15 if bit % 8 == 0 else bit - 1
        return bytes(mask)

    @staticmethod
    def _multiplexer_raw(signal: Any, physical_value: float) -> int:
        try:
            raw_value = signal.scaled_to_raw(physical_value)
            normalized = _finite_float(
                signal.raw_to_scaled(raw_value, decode_choices=False),
                field=signal.name,
            )
            raw_number = _finite_float(raw_value, field=signal.name)
        except (TypeError, ValueError, OverflowError) as exc:
            raise GatewayRuntimeError(
                "dbc_value_invalid",
                f"{signal.name} must map to an integer multiplexer selector",
            ) from exc
        if not raw_number.is_integer() or not math.isclose(
            normalized,
            physical_value,
            rel_tol=1e-12,
            abs_tol=1e-12,
        ):
            raise GatewayRuntimeError(
                "dbc_value_invalid",
                f"{signal.name} must map exactly to an integer multiplexer selector",
            )
        return int(raw_number)

    @staticmethod
    def _default_value(signal: Any) -> float:
        minimum = float(signal.minimum) if signal.minimum is not None else None
        maximum = float(signal.maximum) if signal.maximum is not None else None
        if (minimum is None or minimum <= 0.0) and (maximum is None or maximum >= 0.0):
            return 0.0
        if minimum is not None and minimum > 0.0:
            return minimum
        if maximum is not None:
            return maximum
        return 0.0


@dataclass
class DbcDraft:
    payload: bytes
    enabled: bool = False
    frequency_hz: int = DEFAULT_FREQUENCY_HZ
    generated_default: bool = True

    def to_dict(
        self,
        definition: DbcMessageDefinition,
        values: Mapping[str, float],
    ) -> dict[str, Any]:
        return {
            "message": definition.to_dict(),
            "values": dict(values),
            "enabled": self.enabled,
            "frequency_hz": self.frequency_hz,
            "generated_default": self.generated_default,
            "payload_hex": DbcCodec.format_payload(self.payload),
        }


class DbcConfigStore:
    def __init__(self, path: Path | None = None) -> None:
        self.path = path or (
            user_config_path("ExcavatorSim", "Rosatus") / "can_gateway" / "dbc-config.json"
        )

    def load(self) -> dict[str, Any]:
        try:
            decoded = json.loads(self.path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return {}
        if not isinstance(decoded, dict) or decoded.get("schema_version") not in (
            1,
            DBC_CONFIG_SCHEMA,
        ):
            return {}
        return decoded

    def save(self, drafts: Mapping[str, DbcDraft]) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        body = {
            "schema_version": DBC_CONFIG_SCHEMA,
            "messages": {
                key: {
                    "payload_hex": draft.payload.hex().upper(),
                    "enabled": draft.enabled,
                    "frequency_hz": draft.frequency_hz,
                }
                for key, draft in sorted(drafts.items())
            },
        }
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


@dataclass
class _ScheduleEntry:
    frame_id: int
    is_extended: bool
    payload: bytes
    frequency_hz: int
    next_due_s: float | None = None


class PeriodicDbcScheduler:
    """Independent monotonic schedules; a late tick emits at most one frame each."""

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._entries: dict[str, _ScheduleEntry] = {}
        self.armed = False

    def replace(self, entries: Mapping[str, _ScheduleEntry]) -> None:
        self._entries = dict(entries)
        self.disarm()

    def update(self, key: str, entry: _ScheduleEntry | None) -> None:
        if entry is None:
            self._entries.pop(key, None)
            return
        previous = self._entries.get(key)
        if self.armed:
            entry.next_due_s = (
                self._clock() if previous is None else self._clock() + 1.0 / entry.frequency_hz
            )
        self._entries[key] = entry

    def start(self) -> None:
        if not self._entries:
            raise GatewayRuntimeError("dbc_no_messages_enabled", "no DBC messages are enabled")
        now = self._clock()
        for entry in self._entries.values():
            entry.next_due_s = now
        self.armed = True

    def disarm(self) -> None:
        self.armed = False
        for entry in self._entries.values():
            entry.next_due_s = None

    def service(self, send: Callable[[str, int, bytes], None], now_s: float | None = None) -> int:
        if not self.armed:
            return 0
        now = self._clock() if now_s is None else now_s
        sent = 0
        for key, entry in sorted(self._entries.items()):
            if entry.next_due_s is None or now + 1e-9 < entry.next_due_s:
                continue
            send(key, entry.frame_id, entry.payload)
            entry.next_due_s = now + 1.0 / entry.frequency_hz
            sent += 1
        return sent

    def timeout_s(self, maximum_s: float = 0.05) -> float:
        if not self.armed:
            return maximum_s
        now = self._clock()
        deadlines = [entry.next_due_s for entry in self._entries.values() if entry.next_due_s]
        return max(0.0, min(maximum_s, min(deadlines, default=now + maximum_s) - now))


def estimate_bus_load(drafts: Mapping[str, DbcDraft], codec: DbcCodec) -> dict[str, Any]:
    bits_per_second = 0
    for key, draft in drafts.items():
        if not draft.enabled:
            continue
        message = codec.messages[key]
        stuffed_region = (54 if message.is_extended else 34) + 8 * message.length
        worst_stuff = max(0, (stuffed_region - 1) // 4)
        fixed_tail = 13
        bits_per_second += (stuffed_region + worst_stuff + fixed_tail) * draft.frequency_hz
    percent = bits_per_second / CAN_BITRATE * 100.0
    level = "red" if percent >= 90.0 else "yellow" if percent >= 70.0 else "normal"
    return {
        "bitrate": CAN_BITRATE,
        "estimated_bits_per_second": bits_per_second,
        "percent": round(percent, 2),
        "level": level,
        "warning": percent >= 70.0,
        "caveat": "worst-case classical CAN stuffing estimate; informational only",
    }


class OperatorDbcRuntime:
    """Reloadable operator catalog, drafts, persistence, and Web scheduler."""

    def __init__(
        self,
        roots: Iterable[Path],
        *,
        store: DbcConfigStore | None = None,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.roots = tuple(roots)
        self.store = store or DbcConfigStore()
        self.scheduler = PeriodicDbcScheduler(clock)
        self.catalog = DbcCatalog.discover(self.roots)
        self.codec = DbcCodec(self.catalog)
        self.drafts: dict[str, DbcDraft] = {}
        self.restore_notices: list[DbcNotice] = []
        self._build_drafts(self.store.load())

    @property
    def armed(self) -> bool:
        return self.scheduler.armed

    def reload(self) -> None:
        self.scheduler.disarm()
        persisted = self.store.load()
        self.catalog = DbcCatalog.discover(self.roots)
        self.codec = DbcCodec(self.catalog)
        self._build_drafts(persisted)

    def update_message(
        self,
        message_key: str,
        *,
        values: Mapping[str, Any] | None = None,
        payload_hex: str | None = None,
        enabled: bool | None = None,
        frequency_hz: int | None = None,
    ) -> dict[str, Any]:
        if message_key not in self.drafts:
            raise GatewayRuntimeError("dbc_message_unknown", "DBC message key is not active")
        if values is not None and payload_hex is not None:
            raise GatewayRuntimeError(
                "dbc_edit_source_conflict", "provide values or payload_hex, not both"
            )
        current = self.drafts[message_key]
        if enabled is not None and not isinstance(enabled, bool):
            raise GatewayRuntimeError("dbc_enabled_invalid", "enabled must be boolean")
        new_frequency = current.frequency_hz if frequency_hz is None else frequency_hz
        if (
            not isinstance(new_frequency, int)
            or isinstance(new_frequency, bool)
            or not MIN_FREQUENCY_HZ <= new_frequency <= MAX_FREQUENCY_HZ
        ):
            raise GatewayRuntimeError(
                "dbc_frequency_invalid", "frequency_hz must be 1..100 integer"
            )
        if values is not None:
            payload, normalized_values = self.codec.merge_values(
                message_key, current.payload, values
            )
        elif payload_hex is not None:
            payload, normalized_values = self.codec.normalize_payload(message_key, payload_hex)
        else:
            payload = current.payload
            normalized_values = self.codec.decode(message_key, payload)
        new_enabled = current.enabled if enabled is None else enabled
        if new_enabled:
            definition = self.codec.messages[message_key]
            conflict = next(
                (
                    key
                    for key, draft in self.drafts.items()
                    if key != message_key
                    and draft.enabled
                    and self.codec.messages[key].normalized_id == definition.normalized_id
                ),
                None,
            )
            if conflict is not None:
                raise GatewayRuntimeError(
                    "dbc_can_id_conflict",
                    f"CAN ID conflicts with enabled message {self.codec.messages[conflict].name}",
                    status=409,
                )
        draft = DbcDraft(
            payload=payload,
            enabled=new_enabled,
            frequency_hz=new_frequency,
            generated_default=(
                False
                if values is not None or payload_hex is not None
                else current.generated_default
            ),
        )
        definition = self.codec.messages[message_key]
        candidate_drafts = dict(self.drafts)
        candidate_drafts[message_key] = draft
        try:
            self.store.save(candidate_drafts)
        except OSError as exc:
            raise GatewayRuntimeError(
                "dbc_config_write_failed", "DBC configuration could not be persisted", status=500
            ) from exc
        self.drafts = candidate_drafts
        self.scheduler.update(
            message_key,
            _ScheduleEntry(
                definition.frame_id,
                definition.is_extended,
                payload,
                new_frequency,
            )
            if new_enabled
            else None,
        )
        return draft.to_dict(definition, normalized_values)

    def preview_message(
        self,
        message_key: str,
        *,
        values: Mapping[str, Any] | None = None,
        payload_hex: str | None = None,
    ) -> dict[str, Any]:
        if message_key not in self.drafts:
            raise GatewayRuntimeError("dbc_message_unknown", "DBC message key is not active")
        if (values is None) == (payload_hex is None):
            raise GatewayRuntimeError(
                "dbc_edit_source_invalid", "provide exactly one of values or payload_hex"
            )
        current = self.drafts[message_key]
        if values is not None:
            payload, normalized_values = self.codec.merge_values(
                message_key, current.payload, values
            )
        else:
            payload, normalized_values = self.codec.normalize_payload(message_key, payload_hex)
        return {
            "values": normalized_values,
            "payload_hex": self.codec.format_payload(payload),
        }

    def start(self, *, transport_ready: bool) -> None:
        if not transport_ready:
            raise GatewayRuntimeError(
                "transport_not_ready", "platform transport is not ready for DBC sending", status=409
            )
        self.scheduler.start()

    def stop(self) -> None:
        self.scheduler.disarm()

    def snapshot(self) -> dict[str, Any]:
        messages = []
        for key, definition in sorted(
            self.codec.messages.items(), key=lambda item: (item[1].frame_id, item[1].name, item[0])
        ):
            draft = self.drafts[key]
            try:
                values = self.codec.decode(key, draft.payload)
            except GatewayRuntimeError:
                values = {}
            messages.append(draft.to_dict(definition, values))
        return {
            "armed": self.armed,
            "catalog": self.catalog.snapshot.to_dict(),
            "messages": messages,
            "notices": [notice.to_dict() for notice in self.restore_notices],
            "load": estimate_bus_load(self.drafts, self.codec),
        }

    def _build_drafts(self, persisted: Mapping[str, Any]) -> None:
        self.restore_notices = []
        persisted_messages = persisted.get("messages", {}) if isinstance(persisted, Mapping) else {}
        if not isinstance(persisted_messages, Mapping):
            persisted_messages = {}
        drafts: dict[str, DbcDraft] = {}
        schema_version = persisted.get("schema_version") if isinstance(persisted, Mapping) else None
        for key in self.codec.messages:
            defaults = self.codec.generated_defaults(key)
            draft = DbcDraft(payload=self.codec.encode(key, defaults))
            record = persisted_messages.get(key)
            if isinstance(record, Mapping):
                try:
                    if schema_version == 1:
                        values = record.get("values", defaults)
                        if not isinstance(values, Mapping):
                            raise GatewayRuntimeError(
                                "dbc_values_invalid", "stored values are not an object"
                            )
                        payload = self.codec.encode(key, values)
                        self.codec.decode(key, payload)
                    else:
                        payload, _values = self.codec.normalize_payload(
                            key, record.get("payload_hex")
                        )
                    frequency = record.get("frequency_hz", DEFAULT_FREQUENCY_HZ)
                    if (
                        not isinstance(frequency, int)
                        or isinstance(frequency, bool)
                        or not MIN_FREQUENCY_HZ <= frequency <= MAX_FREQUENCY_HZ
                    ):
                        raise GatewayRuntimeError(
                            "dbc_frequency_invalid", "stored frequency is invalid"
                        )
                    restored_enabled = record.get("enabled", False)
                    if not isinstance(restored_enabled, bool):
                        raise GatewayRuntimeError(
                            "dbc_enabled_invalid", "stored enabled flag is invalid"
                        )
                    draft = DbcDraft(
                        payload=payload,
                        enabled=restored_enabled,
                        frequency_hz=frequency,
                        generated_default=False,
                    )
                except GatewayRuntimeError as exc:
                    self.restore_notices.append(DbcNotice("dbc_restore_ignored", str(exc), key))
            drafts[key] = draft
        enabled_ids: dict[tuple[int, bool], str] = {}
        entries: dict[str, _ScheduleEntry] = {}
        for key, draft in drafts.items():
            definition = self.codec.messages[key]
            if draft.enabled and definition.normalized_id in enabled_ids:
                draft.enabled = False
                self.restore_notices.append(
                    DbcNotice("dbc_restore_conflict_disabled", "duplicate enabled CAN ID", key)
                )
            if draft.enabled:
                enabled_ids[definition.normalized_id] = key
                entries[key] = _ScheduleEntry(
                    definition.frame_id,
                    definition.is_extended,
                    draft.payload,
                    draft.frequency_hz,
                )
        self.drafts = drafts
        self.scheduler.replace(entries)


def load_protocol_codec(bundled_root: Path) -> DbcCodec:
    """Load only the approved bundled files and reject any protocol drift."""
    for name, expected_hash in PROTOCOL_DBC_HASHES.items():
        path = bundled_root / name
        try:
            actual_hash = hashlib.sha256(path.read_bytes()).hexdigest()
        except OSError as exc:
            raise GatewayRuntimeError(
                "protocol_dbc_missing", f"approved protocol DBC is unavailable: {path}", status=500
            ) from exc
        if actual_hash != expected_hash:
            raise GatewayRuntimeError(
                "protocol_dbc_hash_mismatch", f"approved protocol DBC changed: {path}", status=500
            )
    catalog = DbcCatalog.discover([bundled_root])
    if any(file.parse_error for file in catalog.snapshot.files):
        raise GatewayRuntimeError(
            "protocol_dbc_invalid", "approved protocol DBC failed to parse", status=500
        )
    codec = DbcCodec(catalog)
    for frame_id in (*RTK_FRAME_IDS, *IMU_ANGLE_FRAME_IDS):
        codec.unique_message_by_frame(frame_id)
    return codec


def _bounded_physical(value: float, minimum: float, maximum: float) -> float:
    return min(max(float(value), minimum), maximum)


def encode_godot_imu(codec: DbcCodec, frame_id: int, slot_counts: Iterable[int]) -> bytes:
    counts = [max(1, min(int(count), 65_535)) for count in slot_counts]
    if len(counts) != 3:
        raise GatewayRuntimeError("imu_slot_count_invalid", "IMU angle frame needs three slots")
    values = {
        "Pitch_Angle": counts[0] * 0.01 - 180.0,
        "Roll_Angle": counts[1] * 0.01 - 180.0,
        "Yaw_Angle": counts[2] * 0.01 - 180.0,
        "reversed": -75.0,
        "reversed_56": 0.0,
    }
    return codec.encode_frame(frame_id, values)


def encode_godot_rtk(
    codec: DbcCodec,
    state: Any,
    *,
    satellite_status: int = 0,
    wall_clock_unix_s: float | None = None,
) -> dict[int, bytes]:
    now_unix_s = (
        float(wall_clock_unix_s)
        if wall_clock_unix_s is not None
        else float(state.wall_clock_unix_s())
        if hasattr(state, "wall_clock_unix_s")
        else time.time()
    )
    gps_s = max(0.0, now_unix_s - GPS_EPOCH_UNIX_S)
    week = int(gps_s // 604_800)
    seconds = gps_s - week * 604_800
    lat, lon, alt = state.geodetic()
    vice_lat, vice_lon, vice_alt = state.vice_antenna_geodetic()
    ve, vn, vu, speed = state.velocity_enu()
    values_by_id: dict[int, dict[str, float]] = {
        0x0CFDA000: {"WeekTime": week, "GpsTime": seconds},
        0x0CFDA100: {
            "System_state": 2,
            "GpsNumStatsUsed": 18,
            "Satellite_status": satellite_status,
            "GpsNumSats2Used": 18,
            "GpsAge": 0.12,
            "GpsNumSats": 24,
            "GpsNumSats2": 24,
        },
        0x0CFDA200: {"Longitude": lon},
        0x0CFDA300: {"Latitude": lat},
        0x0CFDA400: {"Alt": alt, "Undulation": 0.0},
        0x0CFDA500: {"Longitude1": vice_lon},
        0x0CFDA600: {"Latitude1": vice_lat},
        0x0CFDA700: {"Alt1": vice_alt},
        0x0CFDA800: {
            "VelE": _bounded_physical(ve, -327.68, 327.67),
            "VelN": _bounded_physical(vn, -327.68, 327.67),
            "VelU": _bounded_physical(vu, -327.68, 327.67),
            "Vel": _bounded_physical(speed, -327.68, 327.67),
        },
        0x0CFDA900: {"Heading": state.heading_degrees() % 360.0},
    }
    return {
        frame_id: codec.encode_frame(frame_id, values_by_id[frame_id]) for frame_id in RTK_FRAME_IDS
    }
