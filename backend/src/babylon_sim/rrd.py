"""Godot/Pinocchio RRD profile writer and contained experimental reader."""

from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any, cast

import numpy as np
import pyarrow as pa  # type: ignore[import-untyped]
import rerun as rr
from rerun.experimental import RrdReader

from .constants import ACTIVE_JOINT_NAMES
from .protocol import load_version_manifest
from .recording import BufferSnapshot, MaterializedRecording, RecordingEvent
from .replay_contract import (
    RECORDING_MAX_SAMPLES,
    RRD_PROFILE,
    RRD_RECORDING_TIMELINE,
    RRD_SAMPLE_TIMELINE,
    RRD_SDK_VERSION,
    SourceMode,
)

METADATA_ENTITY = "/godot_pinocchio/metadata"
SIMULATION_TIME_ENTITY = "/godot_pinocchio/signals/simulation_time"
SOURCE_SEQUENCE_ENTITY = "/godot_pinocchio/state/source_sequence"
LAST_INPUT_SEQUENCE_ENTITY = "/godot_pinocchio/state/last_input_sequence"
SIMULATION_EPOCH_ENTITY = "/godot_pinocchio/events/simulation_epoch"
LIFECYCLE_ENTITY = "/godot_pinocchio/events/lifecycle"
QUALITY_ENTITY = "/godot_pinocchio/events/quality"
ALLOWED_IMPLICIT_ENTITIES = frozenset({"/__properties"})
RRD_ACCEPTED_PROTOCOL_VERSIONS = frozenset({"godot-pinocchio-v2", "godot-pinocchio-v3"})


class RrdProfileError(ValueError):
    pass


@dataclass(frozen=True)
class ImportedRecording:
    data: MaterializedRecording
    profile: str
    source_mode: SourceMode
    calibration_version: str
    model_version: str

    @property
    def sample_count(self) -> int:
        return len(self.data)

    @property
    def start_ns(self) -> int:
        return int(self.data.recording_time_ns[0])

    @property
    def end_ns(self) -> int:
        return int(self.data.recording_time_ns[-1])


def joint_entity(joint_name: str, quantity: str) -> str:
    return f"/godot_pinocchio/signals/joints/{joint_name}/{quantity}"


def required_entities() -> frozenset[str]:
    joints = {
        joint_entity(joint, quantity)
        for joint in ACTIVE_JOINT_NAMES
        for quantity in ("position", "velocity", "acceleration")
    }
    return frozenset(
        {
            METADATA_ENTITY,
            SIMULATION_TIME_ENTITY,
            SOURCE_SEQUENCE_ENTITY,
            LAST_INPUT_SEQUENCE_ENTITY,
            SIMULATION_EPOCH_ENTITY,
            LIFECYCLE_ENTITY,
            QUALITY_ENTITY,
            *joints,
        }
    )


def export_rrd(
    snapshot: BufferSnapshot,
    path: Path,
    *,
    calibration_version: str,
    source_mode: SourceMode,
    model_version: str | None = None,
) -> None:
    if snapshot.sample_count == 0:
        raise RrdProfileError("cannot export an empty recording")
    data = snapshot.materialize()
    manifest = load_version_manifest()
    metadata = {
        "profile": RRD_PROFILE,
        "protocol_version": manifest.protocol_version,
        "state_schema_version": manifest.state_schema_version,
        "model_version": model_version or manifest.model_version,
        "calibration_schema_version": manifest.calibration_version,
        "calibration_version": calibration_version,
        "software_version": manifest.software_version,
        "rerun_sdk_version": RRD_SDK_VERSION,
        "joint_order": ",".join(ACTIVE_JOINT_NAMES),
        "units": "SI:rad,rad/s,rad/s^2,s,ns",
        "sample_count": str(len(data)),
        "start_recording_time_ns": str(int(data.recording_time_ns[0])),
        "end_recording_time_ns": str(int(data.recording_time_ns[-1])),
        "start_sample_sequence": str(int(data.sample_sequence[0])),
        "end_sample_sequence": str(int(data.sample_sequence[-1])),
        "source_mode": source_mode.value,
        "simulation_epochs": json.dumps(data.simulation_epochs, separators=(",", ":")),
    }
    recording = rr.RecordingStream("godot_pinocchio", recording_id=snapshot.recording_epoch)
    with recording:
        recording.save(path)
        rr.log(
            METADATA_ENTITY,
            rr.AnyValues(**metadata),  # type: ignore[arg-type]
            static=True,
            recording=recording,
        )
        indexes = _indexes(data)
        for joint_index, joint in enumerate(ACTIVE_JOINT_NAMES):
            for quantity, values in (
                ("position", data.joint_position[:, joint_index]),
                ("velocity", data.joint_velocity[:, joint_index]),
                ("acceleration", data.joint_acceleration[:, joint_index]),
            ):
                _send_scalars(recording, joint_entity(joint, quantity), indexes, values)
        _send_scalars(recording, SIMULATION_TIME_ENTITY, indexes, data.simulation_time_s)
        rr.send_columns(
            SOURCE_SEQUENCE_ENTITY,
            indexes=indexes,
            columns=rr.AnyValues.columns(
                source_sequence=pa.array(data.source_sequence, type=pa.uint64())
            ),
            recording=recording,
        )
        last_input = pa.array(
            [
                int(value) if valid else None
                for value, valid in zip(
                    data.last_input_sequence, data.last_input_valid, strict=True
                )
            ],
            type=pa.uint64(),
        )
        rr.send_columns(
            LAST_INPUT_SEQUENCE_ENTITY,
            indexes=indexes,
            columns=rr.AnyValues.columns(last_input_sequence=last_input),
            recording=recording,
        )
        _send_state_events(
            recording,
            SIMULATION_EPOCH_ENTITY,
            _simulation_epoch_events(data),
        )
        _send_state_events(
            recording,
            LIFECYCLE_ENTITY,
            tuple(event for event in data.events if event.kind == "lifecycle"),
        )
        quality = tuple(event for event in data.events if event.kind == "quality")
        rr.send_columns(
            QUALITY_ENTITY,
            indexes=_event_indexes(quality),
            columns=rr.TextLog.columns(
                text=[event.value for event in quality],
                level=["INFO" if event.value == "[]" else "WARN" for event in quality],
            ),
            recording=recording,
        )


def import_rrd(path: Path, *, expected_model_version: str | None = None) -> ImportedRecording:
    try:
        reader = RrdReader(path)
        stores = reader.recordings()
        if len(stores) != 1:
            raise RrdProfileError("RRD must contain exactly one recording store")
        chunks = reader.stream(store=stores[0]).to_chunks()
    except RrdProfileError:
        raise
    except Exception as exc:
        raise RrdProfileError(f"RRD could not be read: {exc}") from exc

    batches: dict[str, list[pa.RecordBatch]] = {}
    static: dict[str, bool] = {}
    for chunk in chunks:
        entity = str(chunk.entity_path)
        if entity in ALLOWED_IMPLICIT_ENTITIES:
            continue
        batches.setdefault(entity, []).append(chunk.to_record_batch())
        static[entity] = bool(chunk.is_static)
    actual = frozenset(batches)
    expected = required_entities()
    if actual != expected:
        missing = sorted(expected - actual)
        unexpected = sorted(actual - expected)
        raise RrdProfileError(
            f"RRD entity profile mismatch; missing={missing}, unexpected={unexpected}"
        )
    if not static.get(METADATA_ENTITY) or any(
        static.get(entity) for entity in expected - {METADATA_ENTITY}
    ):
        raise RrdProfileError("RRD static/temporal entity profile is invalid")

    metadata = _read_metadata(batches[METADATA_ENTITY])
    source_mode, calibration_version = _validate_metadata(
        metadata, expected_model_version=expected_model_version
    )
    times, sequences, simulation_time = _read_scalars(
        batches[SIMULATION_TIME_ENTITY], SIMULATION_TIME_ENTITY
    )
    count = len(times)
    if not 1 <= count <= RECORDING_MAX_SAMPLES:
        raise RrdProfileError(f"RRD sample count must be between 1 and {RECORDING_MAX_SAMPLES}")
    positions = np.empty((count, len(ACTIVE_JOINT_NAMES)), dtype=np.float64)
    velocities = np.empty_like(positions)
    accelerations = np.empty_like(positions)
    for joint_index, joint in enumerate(ACTIVE_JOINT_NAMES):
        for quantity, target in (
            ("position", positions),
            ("velocity", velocities),
            ("acceleration", accelerations),
        ):
            entity = joint_entity(joint, quantity)
            entity_times, entity_sequences, values = _read_scalars(batches[entity], entity)
            _require_same_keys(times, sequences, entity_times, entity_sequences, entity)
            target[:, joint_index] = values

    source_times, source_sequences, source_values = _read_any_values(
        batches[SOURCE_SEQUENCE_ENTITY], "source_sequence", allow_null=False
    )
    input_times, input_sequences, input_values = _read_any_values(
        batches[LAST_INPUT_SEQUENCE_ENTITY], "last_input_sequence", allow_null=True
    )
    _require_same_keys(times, sequences, source_times, source_sequences, SOURCE_SEQUENCE_ENTITY)
    _require_same_keys(times, sequences, input_times, input_sequences, LAST_INPUT_SEQUENCE_ENTITY)

    simulation_epochs = tuple(cast(list[str], json.loads(metadata["simulation_epochs"])))
    epoch_events = _read_state_events(batches[SIMULATION_EPOCH_ENTITY], "simulation_epoch")
    lifecycle_events = _read_state_events(batches[LIFECYCLE_ENTITY], "lifecycle")
    quality_events = _read_quality_events(batches[QUALITY_ENTITY])
    simulation_epoch_id = _forward_fill_strings(
        sequences, epoch_events, simulation_epochs, "simulation epoch"
    )
    lifecycle_names = ("stopped", "running", "paused", "fault")
    lifecycle_code = _forward_fill_strings(
        sequences, lifecycle_events, lifecycle_names, "lifecycle"
    ).astype(np.uint8)
    last_input_valid = np.asarray([value is not None for value in input_values], dtype=np.bool_)
    last_input_sequence = np.asarray(
        [0 if value is None else value for value in input_values], dtype=np.uint64
    )
    events = tuple(
        sorted(
            (
                *(
                    RecordingEvent(sequence, time_ns, "lifecycle", value)
                    for time_ns, sequence, value in lifecycle_events
                ),
                *(
                    RecordingEvent(sequence, time_ns, "quality", value)
                    for time_ns, sequence, value in quality_events
                ),
            ),
            key=lambda event: (event.sample_sequence, event.kind),
        )
    )
    data = MaterializedRecording(
        recording_time_ns=times,
        simulation_time_s=simulation_time,
        source_sequence=np.asarray(source_values, dtype=np.uint64),
        simulation_epoch_id=simulation_epoch_id.astype(np.uint32),
        lifecycle_code=lifecycle_code,
        joint_position=positions,
        joint_velocity=velocities,
        joint_acceleration=accelerations,
        last_input_sequence=last_input_sequence,
        last_input_valid=last_input_valid,
        sample_sequence=sequences.astype(np.uint64),
        simulation_epochs=simulation_epochs,
        events=events,
    )
    _validate_materialized_profile(data, metadata)
    return ImportedRecording(
        data,
        RRD_PROFILE,
        source_mode,
        calibration_version,
        metadata["model_version"],
    )


def _indexes(data: MaterializedRecording) -> list[Any]:
    return [
        rr.TimeColumn(
            RRD_RECORDING_TIMELINE,
            duration=data.recording_time_ns.astype("timedelta64[ns]"),
        ),
        rr.TimeColumn(RRD_SAMPLE_TIMELINE, sequence=data.sample_sequence.astype(np.int64)),
    ]


def _event_indexes(events: tuple[RecordingEvent, ...]) -> list[Any]:
    return [
        rr.TimeColumn(
            RRD_RECORDING_TIMELINE,
            duration=np.asarray(
                [event.recording_time_ns for event in events], dtype="timedelta64[ns]"
            ),
        ),
        rr.TimeColumn(
            RRD_SAMPLE_TIMELINE,
            sequence=np.asarray([event.sample_sequence for event in events], dtype=np.int64),
        ),
    ]


def _send_scalars(
    recording: Any, entity: str, indexes: list[Any], values: np.ndarray[Any, Any]
) -> None:
    rr.send_columns(
        entity,
        indexes=indexes,
        columns=rr.Scalars.columns(scalars=values),
        recording=recording,
    )


def _send_state_events(recording: Any, entity: str, events: tuple[RecordingEvent, ...]) -> None:
    if not events:
        raise RrdProfileError(f"required event stream is empty: {entity}")
    rr.send_columns(
        entity,
        indexes=_event_indexes(events),
        columns=rr.StateChange.columns(state=[event.value for event in events]),
        recording=recording,
    )


def _simulation_epoch_events(data: MaterializedRecording) -> tuple[RecordingEvent, ...]:
    events: list[RecordingEvent] = []
    previous: int | None = None
    for index, epoch_id_value in enumerate(data.simulation_epoch_id):
        epoch_id = int(epoch_id_value)
        if epoch_id == previous:
            continue
        events.append(
            RecordingEvent(
                int(data.sample_sequence[index]),
                int(data.recording_time_ns[index]),
                "simulation_epoch",
                data.simulation_epochs[epoch_id],
            )
        )
        previous = epoch_id
    return tuple(events)


def _read_metadata(batches: list[pa.RecordBatch]) -> dict[str, str]:
    if sum(batch.num_rows for batch in batches) != 1:
        raise RrdProfileError("metadata entity must contain exactly one row")
    result: dict[str, str] = {}
    for batch in batches:
        for name in batch.schema.names:
            if name.startswith("rerun.controls."):
                continue
            values = batch.column(name).to_pylist()
            if len(values) != 1 or not isinstance(values[0], list) or len(values[0]) != 1:
                raise RrdProfileError(f"metadata field has invalid cardinality: {name}")
            value = values[0][0]
            if not isinstance(value, str):
                raise RrdProfileError(f"metadata field must be a string: {name}")
            result[name] = value
    return result


def _validate_metadata(
    metadata: dict[str, str], *, expected_model_version: str | None = None
) -> tuple[SourceMode, str]:
    manifest = load_version_manifest()
    expected = {
        "profile": RRD_PROFILE,
        "state_schema_version": manifest.state_schema_version,
        "model_version": expected_model_version or manifest.model_version,
        "calibration_schema_version": manifest.calibration_version,
        "software_version": manifest.software_version,
        "rerun_sdk_version": RRD_SDK_VERSION,
        "joint_order": ",".join(ACTIVE_JOINT_NAMES),
        "units": "SI:rad,rad/s,rad/s^2,s,ns",
    }
    required = {
        *expected,
        "protocol_version",
        "calibration_version",
        "sample_count",
        "start_recording_time_ns",
        "end_recording_time_ns",
        "start_sample_sequence",
        "end_sample_sequence",
        "source_mode",
        "simulation_epochs",
    }
    if set(metadata) != required:
        raise RrdProfileError("RRD metadata field set is incompatible")
    if metadata["protocol_version"] not in RRD_ACCEPTED_PROTOCOL_VERSIONS:
        raise RrdProfileError("RRD metadata mismatch for protocol_version")
    for name, value in expected.items():
        if metadata[name] != value:
            raise RrdProfileError(f"RRD metadata mismatch for {name}")
    try:
        source_mode = SourceMode(metadata["source_mode"])
    except ValueError as exc:
        raise RrdProfileError("RRD source mode is invalid") from exc
    if not metadata["calibration_version"]:
        raise RrdProfileError("RRD calibration version is empty")
    return source_mode, metadata["calibration_version"]


def _read_scalars(
    batches: list[pa.RecordBatch], entity: str
) -> tuple[
    np.ndarray[Any, np.dtype[np.int64]],
    np.ndarray[Any, np.dtype[np.int64]],
    np.ndarray[Any, np.dtype[np.float64]],
]:
    times, sequences, values = _read_rows(batches, "Scalars:scalars", entity)
    numeric = np.asarray([_single_float(value, entity) for value in values], dtype=np.float64)
    return _sort_rows(times, sequences, numeric, entity)


def _read_any_values(
    batches: list[pa.RecordBatch], component: str, *, allow_null: bool
) -> tuple[
    np.ndarray[Any, np.dtype[np.int64]], np.ndarray[Any, np.dtype[np.int64]], list[int | None]
]:
    times, sequences, values = _read_rows(batches, component, component)
    decoded: list[int | None] = []
    for value in values:
        item = _single_value(value, component)
        if item is None and allow_null:
            decoded.append(None)
        elif isinstance(item, int) and not isinstance(item, bool) and item >= 0:
            decoded.append(item)
        else:
            raise RrdProfileError(f"{component} contains an invalid integer")
    order = np.lexsort((times, sequences))
    sorted_times = times[order]
    sorted_sequences = sequences[order]
    return sorted_times, sorted_sequences, [decoded[int(index)] for index in order]


def _read_state_events(
    batches: list[pa.RecordBatch], label: str
) -> tuple[tuple[int, int, str], ...]:
    times, sequences, values = _read_rows(batches, "StateChange:state", label)
    decoded = [_single_value(value, label) for value in values]
    if any(not isinstance(value, str) or not value for value in decoded):
        raise RrdProfileError(f"{label} contains an invalid state")
    order = np.lexsort((times, sequences))
    return tuple(
        (int(times[index]), int(sequences[index]), cast(str, decoded[index])) for index in order
    )


def _read_quality_events(
    batches: list[pa.RecordBatch],
) -> tuple[tuple[int, int, str], ...]:
    times, sequences, values = _read_rows(
        batches,
        "TextLog:text",
        "quality",
        extra_components=frozenset({"TextLog:level"}),
    )
    decoded = [_single_value(value, "quality") for value in values]
    for value in decoded:
        try:
            flags = json.loads(cast(str, value))
        except (TypeError, json.JSONDecodeError) as exc:
            raise RrdProfileError("quality event is not valid JSON") from exc
        if not isinstance(flags, list) or any(not isinstance(flag, str) for flag in flags):
            raise RrdProfileError("quality event must be a JSON string array")
    order = np.lexsort((times, sequences))
    return tuple(
        (int(times[index]), int(sequences[index]), cast(str, decoded[index])) for index in order
    )


def _read_rows(
    batches: list[pa.RecordBatch],
    component: str,
    label: str,
    *,
    extra_components: frozenset[str] = frozenset(),
) -> tuple[np.ndarray[Any, np.dtype[np.int64]], np.ndarray[Any, np.dtype[np.int64]], list[Any]]:
    times: list[np.ndarray[Any, Any]] = []
    sequences: list[np.ndarray[Any, Any]] = []
    values: list[Any] = []
    required = {RRD_RECORDING_TIMELINE, RRD_SAMPLE_TIMELINE, component, *extra_components}
    for batch in batches:
        names = set(batch.schema.names)
        data_names = {name for name in names if not name.startswith("rerun.controls.")}
        if data_names != required:
            raise RrdProfileError(f"{label} has an incompatible Arrow component set")
        times.append(
            batch.column(RRD_RECORDING_TIMELINE)
            .to_numpy(zero_copy_only=False)
            .astype("timedelta64[ns]")
            .astype(np.int64)
        )
        sequences.append(
            batch.column(RRD_SAMPLE_TIMELINE).to_numpy(zero_copy_only=False).astype(np.int64)
        )
        values.extend(batch.column(component).to_pylist())
    return np.concatenate(times), np.concatenate(sequences), values


def _sort_rows(
    times: np.ndarray[Any, np.dtype[np.int64]],
    sequences: np.ndarray[Any, np.dtype[np.int64]],
    values: np.ndarray[Any, np.dtype[np.float64]],
    label: str,
) -> tuple[
    np.ndarray[Any, np.dtype[np.int64]],
    np.ndarray[Any, np.dtype[np.int64]],
    np.ndarray[Any, np.dtype[np.float64]],
]:
    order = np.lexsort((times, sequences))
    times = times[order]
    sequences = sequences[order]
    values = values[order]
    if len(sequences) > 1 and np.any(np.diff(sequences) <= 0):
        raise RrdProfileError(f"{label} sample sequence is duplicate or unordered")
    return times, sequences, values


def _single_value(value: Any, label: str) -> Any:
    if not isinstance(value, list) or len(value) != 1:
        raise RrdProfileError(f"{label} component batch must contain one value per row")
    return value[0]


def _single_float(value: Any, label: str) -> float:
    item = _single_value(value, label)
    if isinstance(item, bool) or not isinstance(item, (int, float)):
        raise RrdProfileError(f"{label} contains a non-numeric scalar")
    result = float(item)
    if not np.isfinite(result):
        raise RrdProfileError(f"{label} contains a non-finite scalar")
    return result


def _require_same_keys(
    expected_times: np.ndarray[Any, Any],
    expected_sequences: np.ndarray[Any, Any],
    actual_times: np.ndarray[Any, Any],
    actual_sequences: np.ndarray[Any, Any],
    label: str,
) -> None:
    if not np.array_equal(expected_times, actual_times) or not np.array_equal(
        expected_sequences, actual_sequences
    ):
        raise RrdProfileError(f"{label} does not share the canonical dual indexes")


def _forward_fill_strings(
    sequences: np.ndarray[Any, np.dtype[np.int64]],
    events: tuple[tuple[int, int, str], ...],
    values: tuple[str, ...],
    label: str,
) -> np.ndarray[Any, np.dtype[np.int64]]:
    if not events or events[0][1] != int(sequences[0]):
        raise RrdProfileError(f"{label} events must start at the first retained sample")
    value_ids = {value: index for index, value in enumerate(values)}
    result = np.empty(len(sequences), dtype=np.int64)
    event_index = 0
    current = -1
    for row, sequence in enumerate(sequences):
        while event_index < len(events) and events[event_index][1] <= int(sequence):
            event_value = events[event_index][2]
            if event_value not in value_ids:
                raise RrdProfileError(f"{label} contains an unknown value")
            current = value_ids[event_value]
            event_index += 1
        result[row] = current
    if np.any(result < 0):
        raise RrdProfileError(f"{label} could not be reconstructed")
    return result


def _validate_materialized_profile(data: MaterializedRecording, metadata: dict[str, str]) -> None:
    if np.any(np.diff(data.recording_time_ns) <= 0):
        raise RrdProfileError("recording_time must be strictly increasing")
    if np.any(np.diff(data.sample_sequence) != 1):
        raise RrdProfileError("sample_sequence must be contiguous")
    checks = {
        "sample_count": len(data),
        "start_recording_time_ns": int(data.recording_time_ns[0]),
        "end_recording_time_ns": int(data.recording_time_ns[-1]),
        "start_sample_sequence": int(data.sample_sequence[0]),
        "end_sample_sequence": int(data.sample_sequence[-1]),
    }
    for field, value in checks.items():
        if metadata[field] != str(value):
            raise RrdProfileError(f"RRD metadata summary mismatch for {field}")
