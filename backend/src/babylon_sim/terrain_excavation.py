"""Deterministic visual terrain excavation, deposition, and bounded history."""

from __future__ import annotations

import hashlib
import math
import struct
import zlib
from dataclasses import dataclass
from typing import Literal

import numpy as np
from numpy.typing import NDArray

from .terrain import TerrainBaseline

TERRAIN_EDIT_HZ = 25
TERRAIN_EDIT_STRIDE = 4
MAX_DIRTY_CELLS = 4_096
MAX_PATCH_BYTES = 256 * 1024
MAX_CUT_FILL_M = 3.0
BUCKET_CAPACITY_M3 = 0.35
TERRAIN_HISTORY_BYTES = 128 * 1024 * 1024
CHECKPOINT_INTERVAL_NS = 10_000_000_000
CHECKPOINT_EVENT_INTERVAL = 250

_CUT_POSTURE_MAX = 0.45
_DUMP_POSTURE_MIN = 0.70
_CONTACT_TOLERANCE_M = 0.12
_DUMP_CLEARANCE_M = 0.15
_CUT_DEPTH_PER_EDIT_M = 0.08
_TOOTH_RADIUS_M = 0.20
_DEPOSIT_RADIUS_M = 0.75
_VOLUME_EPSILON_M3 = 1e-8
REPOSE_ANGLE_DEG = 34.0
REPOSE_HEIGHT_TOLERANCE_M = 1e-4
MAX_RELAXATION_PASSES = 64
MAX_RELAXATION_CELL_VISITS = MAX_DIRTY_CELLS * MAX_RELAXATION_PASSES
_DEPOSIT_HALO_CELLS = 8
_RELAXATION_FLUX_EPSILON_M = 1e-7
_VOLUME_CONSERVATION_TOLERANCE_M3 = 1e-6
_RELAXATION_NEIGHBORS = ((-1, 0), (0, 1), (1, 0), (0, -1))

ToothPoint = tuple[float, float, float]
ToothPoints = tuple[ToothPoint, ToothPoint, ToothPoint]
TerrainOperation = Literal["cut", "deposit"]
_LAYERED_STATE_DIGEST_VERSION = b"terrain-layer-state-v1\0"


class TerrainHistoryError(RuntimeError):
    """Raised when retained terrain history cannot remain reconstructible."""


@dataclass(frozen=True)
class TerrainEditInput:
    recording_epoch: str
    sample_sequence: int
    recording_time_ns: int
    stream_epoch: str
    previous_teeth: ToothPoints
    current_teeth: ToothPoints
    bucket_joint_normalized: float
    reset_bucket: bool = False


@dataclass(frozen=True)
class TerrainEditEvent:
    revision: int
    sample_sequence: int
    recording_time_ns: int
    stream_epoch: str
    operation: TerrainOperation
    previous_teeth: ToothPoints
    current_teeth: ToothPoints
    bucket_joint_normalized: float
    dirty_bounds: tuple[int, int, int, int]
    changed_cells: int
    cut_volume_m3: float
    deposited_volume_m3: float
    bucket_volume_after_m3: float
    relaxation_passes: int
    relaxation_touched_cells: int
    relaxation_cell_visits: int
    relaxation_converged: bool
    bucket_residual_m3: float
    snapshot_sha256: str
    layered_state_sha256: str


@dataclass(frozen=True)
class TerrainPatch:
    base_revision: int
    new_revision: int
    selected_sample_sequence: int
    indices: tuple[int, ...]
    heights_m: tuple[float, ...]
    dirty_bounds: tuple[int, int, int, int]
    snapshot_sha256: str

    @property
    def encoded_size_upper_bound(self) -> int:
        return len(self.indices) * 16 + 512

    def as_message(self, recording_epoch: str, terrain_epoch: str) -> dict[str, object]:
        return {
            "type": "terrain_patch",
            "recording_epoch": recording_epoch,
            "selected_sample_sequence": self.selected_sample_sequence,
            "terrain_epoch": terrain_epoch,
            "base_revision": self.base_revision,
            "new_revision": self.new_revision,
            "indices": list(self.indices),
            "heights_m": list(self.heights_m),
            "dirty_bounds": list(self.dirty_bounds),
            "snapshot_sha256": self.snapshot_sha256,
        }


@dataclass(frozen=True)
class TerrainState:
    stable_heights: NDArray[np.float32]
    loose_depths: NDArray[np.float32]
    heights: NDArray[np.float32]
    bucket_volume_m3: float


@dataclass(frozen=True)
class _DepositResult:
    state: TerrainState
    changed: frozenset[int]
    deposited_volume_m3: float
    relaxation_passes: int
    relaxation_touched_cells: int
    relaxation_cell_visits: int


@dataclass(frozen=True)
class TerrainEditResult:
    state: TerrainState
    event: TerrainEditEvent | None
    patch: TerrainPatch | None

    @property
    def bucket_volume_m3(self) -> float:
        return self.state.bucket_volume_m3

    @property
    def stable_heights(self) -> NDArray[np.float32]:
        return self.state.stable_heights

    @property
    def loose_depths(self) -> NDArray[np.float32]:
        return self.state.loose_depths

    @property
    def heights(self) -> NDArray[np.float32]:
        return self.state.heights


@dataclass(frozen=True)
class TerrainMaterialized:
    revision: int
    sample_sequence: int
    state: TerrainState
    snapshot_sha256: str
    layered_state_sha256: str
    height_min_m: float
    height_max_m: float

    @property
    def bucket_volume_m3(self) -> float:
        return self.state.bucket_volume_m3

    @property
    def stable_heights(self) -> NDArray[np.float32]:
        return self.state.stable_heights

    @property
    def loose_depths(self) -> NDArray[np.float32]:
        return self.state.loose_depths

    @property
    def heights(self) -> NDArray[np.float32]:
        return self.state.heights


@dataclass(frozen=True)
class TerrainRevisionInfo:
    revision: int
    sample_sequence: int
    bucket_volume_m3: float
    snapshot_sha256: str
    layered_state_sha256: str
    height_min_m: float
    height_max_m: float


@dataclass(frozen=True)
class _Checkpoint:
    revision: int
    sample_sequence: int
    recording_time_ns: int
    compressed_stable_heights: bytes
    compressed_loose_depths: bytes
    bucket_volume_m3: float
    snapshot_sha256: str
    layered_state_sha256: str


@dataclass(frozen=True)
class _RevisionMarker:
    sample_sequence: int
    revision: int
    bucket_volume_m3: float
    snapshot_sha256: str
    layered_state_sha256: str
    height_min_m: float
    height_max_m: float


def point_from_matrix(matrix: tuple[tuple[float, float, float, float], ...]) -> ToothPoint:
    """Extract the Z-up world translation from an authoritative homogeneous matrix."""

    return (float(matrix[0][3]), float(matrix[1][3]), float(matrix[2][3]))


def normalized_joint(position: float, minimum: float, maximum: float) -> float:
    finite = all(math.isfinite(value) for value in (position, minimum, maximum))
    if not finite or minimum >= maximum:
        raise ValueError("joint normalization requires finite ordered limits")
    return min(1.0, max(0.0, (position - minimum) / (maximum - minimum)))


def snapshot_digest(heights: NDArray[np.float32]) -> str:
    return hashlib.sha256(heights.astype("<f4", copy=False).tobytes(order="C")).hexdigest()


def layered_state_digest(state: TerrainState) -> str:
    digest = hashlib.sha256()
    digest.update(_LAYERED_STATE_DIGEST_VERSION)
    digest.update(state.stable_heights.astype("<f4", copy=False).tobytes(order="C"))
    digest.update(state.loose_depths.astype("<f4", copy=False).tobytes(order="C"))
    digest.update(struct.pack("<d", state.bucket_volume_m3))
    return digest.hexdigest()


def initial_terrain_state(
    heights: NDArray[np.float32], bucket_volume_m3: float = 0.0
) -> TerrainState:
    loose = np.zeros(heights.shape, dtype="<f4")
    return _make_terrain_state(heights, loose, bucket_volume_m3)


def apply_terrain_edit(
    baseline: TerrainBaseline,
    state: TerrainState,
    revision: int,
    edit: TerrainEditInput,
    *,
    operation: TerrainOperation | None = None,
) -> TerrainEditResult:
    """Apply one fixed-cadence visual edit without consulting wall or render time."""

    _validate_edit_input(baseline, state, edit)
    selected_operation = operation or _classify_operation(
        baseline, state.heights, state.bucket_volume_m3, edit
    )
    if selected_operation is None:
        return TerrainEditResult(state, None, None)

    deposit_result: _DepositResult | None = None
    if selected_operation == "cut":
        writable = np.array(state.heights, dtype="<f4", copy=True, order="C")
        candidates, _, _ = _cut(baseline, writable, state.bucket_volume_m3, edit)
        if not candidates:
            return TerrainEditResult(state, None, None)
        next_state = _apply_surface_delta(state, writable, candidates)
        changed = {
            index
            for index in candidates
            if float(next_state.heights.flat[index]) != float(state.heights.flat[index])
        }
        relaxation_passes = 0
        relaxation_touched_cells = 0
        relaxation_cell_visits = 0
    else:
        deposit_result = _deposit(baseline, state, edit)
        if deposit_result is None:
            return TerrainEditResult(state, None, None)
        next_state = deposit_result.state
        changed = set(deposit_result.changed)
        relaxation_passes = deposit_result.relaxation_passes
        relaxation_touched_cells = deposit_result.relaxation_touched_cells
        relaxation_cell_visits = deposit_result.relaxation_cell_visits

    if not changed:
        return TerrainEditResult(state, None, None)
    if len(changed) > MAX_DIRTY_CELLS:
        raise ValueError("terrain edit exceeds the dirty-cell limit")
    indices = tuple(sorted(changed))
    cell_area = baseline.domain.spacing_m * baseline.domain.spacing_m
    if selected_operation == "cut":
        cut_volume = float(
            np.sum(
                [
                    float(state.heights.flat[index]) - float(next_state.heights.flat[index])
                    for index in indices
                ],
                dtype=np.float64,
            )
            * cell_area
        )
        cut_volume = min(cut_volume, BUCKET_CAPACITY_M3 - state.bucket_volume_m3)
        deposited_volume = 0.0
        next_bucket = min(BUCKET_CAPACITY_M3, state.bucket_volume_m3 + cut_volume)
    else:
        assert deposit_result is not None
        cut_volume = 0.0
        deposited_volume = deposit_result.deposited_volume_m3
        next_bucket = deposit_result.state.bucket_volume_m3
    next_state = _make_terrain_state(
        next_state.stable_heights, next_state.loose_depths, next_bucket
    )
    digest = snapshot_digest(next_state.heights)
    layered_digest = layered_state_digest(next_state)
    rows = [index // baseline.domain.columns for index in indices]
    columns = [index % baseline.domain.columns for index in indices]
    bounds = (min(rows), max(rows), min(columns), max(columns))
    patch = TerrainPatch(
        base_revision=revision,
        new_revision=revision + 1,
        selected_sample_sequence=edit.sample_sequence,
        indices=indices,
        heights_m=tuple(float(next_state.heights.flat[index]) for index in indices),
        dirty_bounds=bounds,
        snapshot_sha256=digest,
    )
    if patch.encoded_size_upper_bound > MAX_PATCH_BYTES:
        raise ValueError("terrain patch exceeds the encoded-size limit")
    event = TerrainEditEvent(
        revision=revision + 1,
        sample_sequence=edit.sample_sequence,
        recording_time_ns=edit.recording_time_ns,
        stream_epoch=edit.stream_epoch,
        operation=selected_operation,
        previous_teeth=edit.previous_teeth,
        current_teeth=edit.current_teeth,
        bucket_joint_normalized=edit.bucket_joint_normalized,
        dirty_bounds=bounds,
        changed_cells=len(indices),
        cut_volume_m3=cut_volume,
        deposited_volume_m3=deposited_volume,
        bucket_volume_after_m3=next_bucket,
        relaxation_passes=relaxation_passes,
        relaxation_touched_cells=relaxation_touched_cells,
        relaxation_cell_visits=relaxation_cell_visits,
        relaxation_converged=True,
        bucket_residual_m3=next_bucket,
        snapshot_sha256=digest,
        layered_state_sha256=layered_digest,
    )
    return TerrainEditResult(next_state, event, patch)


class TerrainTimeline:
    """One terrain epoch's deterministic events and compressed reconstruction checkpoints."""

    def __init__(
        self,
        baseline: TerrainBaseline,
        *,
        start_sample_sequence: int,
        history_limit_bytes: int = TERRAIN_HISTORY_BYTES,
    ) -> None:
        if history_limit_bytes <= 0:
            raise ValueError("terrain history limit must be positive")
        self.baseline = baseline
        self._history_limit_bytes = history_limit_bytes
        self._events: list[TerrainEditEvent] = []
        self._current = initial_terrain_state(baseline.heights)
        initial_digest = snapshot_digest(self._current.heights)
        initial_layered_digest = layered_state_digest(self._current)
        self._checkpoints: list[_Checkpoint] = [self._make_checkpoint(0, start_sample_sequence, 0)]
        self._markers: list[_RevisionMarker] = [
            _RevisionMarker(
                start_sample_sequence,
                0,
                0.0,
                initial_digest,
                initial_layered_digest,
                baseline.height_min_m,
                baseline.height_max_m,
            )
        ]
        self._last_checkpoint_event_count = 0

    @property
    def current_revision(self) -> int:
        return self._markers[-1].revision

    @property
    def current_bucket_volume_m3(self) -> float:
        return self._current.bucket_volume_m3

    @property
    def event_count(self) -> int:
        return len(self._events)

    @property
    def latest_event(self) -> TerrainEditEvent | None:
        return None if not self._events else self._events[-1]

    @property
    def checkpoint_count(self) -> int:
        return len(self._checkpoints)

    @property
    def checkpoint_bytes(self) -> int:
        return sum(
            len(item.compressed_stable_heights) + len(item.compressed_loose_depths) + 192
            for item in self._checkpoints
        )

    @property
    def canonical_state_bytes(self) -> int:
        return self._current.stable_heights.nbytes + self._current.loose_depths.nbytes

    @property
    def history_bytes(self) -> int:
        event_bytes = sum(_event_size_upper_bound(item) for item in self._events)
        return self.checkpoint_bytes + event_bytes + len(self._markers) * 192

    def apply(self, edit: TerrainEditInput) -> TerrainPatch | None:
        result = apply_terrain_edit(
            self.baseline,
            self._current,
            self.current_revision,
            edit,
        )
        if result.event is None:
            return None
        previous_current = self._current
        previous_event_count = len(self._events)
        previous_marker_count = len(self._markers)
        previous_checkpoint_count = len(self._checkpoints)
        previous_checkpoint_event_count = self._last_checkpoint_event_count
        try:
            self._current = result.state
            self._events.append(result.event)
            self._markers.append(
                _RevisionMarker(
                    edit.sample_sequence,
                    result.event.revision,
                    result.bucket_volume_m3,
                    result.event.snapshot_sha256,
                    result.event.layered_state_sha256,
                    float(np.min(result.heights)),
                    float(np.max(result.heights)),
                )
            )
            last = self._checkpoints[-1]
            if (
                len(self._events) - self._last_checkpoint_event_count >= CHECKPOINT_EVENT_INTERVAL
                or edit.recording_time_ns - last.recording_time_ns >= CHECKPOINT_INTERVAL_NS
            ):
                self._checkpoints.append(
                    self._make_checkpoint(
                        result.event.revision, edit.sample_sequence, edit.recording_time_ns
                    )
                )
                self._last_checkpoint_event_count = len(self._events)
            self._ensure_budget()
        except Exception:
            self._current = previous_current
            del self._events[previous_event_count:]
            del self._markers[previous_marker_count:]
            del self._checkpoints[previous_checkpoint_count:]
            self._last_checkpoint_event_count = previous_checkpoint_event_count
            raise
        return result.patch

    def clear_bucket(self, sample_sequence: int, recording_time_ns: int) -> None:
        if self._current.bucket_volume_m3 <= _VOLUME_EPSILON_M3:
            return
        previous_current = self._current
        previous_marker_count = len(self._markers)
        previous_checkpoint_count = len(self._checkpoints)
        previous_checkpoint_event_count = self._last_checkpoint_event_count
        try:
            self._current = _make_terrain_state(
                self._current.stable_heights, self._current.loose_depths, 0.0
            )
            self._markers.append(
                _RevisionMarker(
                    sample_sequence,
                    self.current_revision + 1,
                    0.0,
                    snapshot_digest(self._current.heights),
                    layered_state_digest(self._current),
                    float(np.min(self._current.heights)),
                    float(np.max(self._current.heights)),
                )
            )
            self._checkpoints.append(
                self._make_checkpoint(self.current_revision, sample_sequence, recording_time_ns)
            )
            self._last_checkpoint_event_count = len(self._events)
            self._ensure_budget()
        except Exception:
            self._current = previous_current
            del self._markers[previous_marker_count:]
            del self._checkpoints[previous_checkpoint_count:]
            self._last_checkpoint_event_count = previous_checkpoint_event_count
            raise

    def reset(self, sample_sequence: int, recording_time_ns: int) -> None:
        previous_current = self._current
        previous_marker_count = len(self._markers)
        previous_checkpoint_count = len(self._checkpoints)
        previous_checkpoint_event_count = self._last_checkpoint_event_count
        reset_state = initial_terrain_state(self.baseline.heights)
        try:
            self._current = reset_state
            self._markers.append(
                _RevisionMarker(
                    sample_sequence,
                    self.current_revision + 1,
                    0.0,
                    self.baseline.snapshot_sha256,
                    layered_state_digest(reset_state),
                    self.baseline.height_min_m,
                    self.baseline.height_max_m,
                )
            )
            self._checkpoints.append(
                self._make_checkpoint(self.current_revision, sample_sequence, recording_time_ns)
            )
            self._last_checkpoint_event_count = len(self._events)
            self._ensure_budget()
        except Exception:
            self._current = previous_current
            del self._markers[previous_marker_count:]
            del self._checkpoints[previous_checkpoint_count:]
            self._last_checkpoint_event_count = previous_checkpoint_event_count
            raise

    def revision_at(self, sample_sequence: int) -> int:
        return self.info_at(sample_sequence).revision

    def info_at(self, sample_sequence: int) -> TerrainRevisionInfo:
        selected = self._markers[0]
        for marker in self._markers:
            if marker.sample_sequence > sample_sequence:
                break
            selected = marker
        return TerrainRevisionInfo(
            revision=selected.revision,
            sample_sequence=selected.sample_sequence,
            bucket_volume_m3=selected.bucket_volume_m3,
            snapshot_sha256=selected.snapshot_sha256,
            layered_state_sha256=selected.layered_state_sha256,
            height_min_m=selected.height_min_m,
            height_max_m=selected.height_max_m,
        )

    def materialize_revision(self, revision: int) -> TerrainMaterialized:
        if revision < 0 or revision > self.current_revision:
            raise TerrainHistoryError("terrain revision is unavailable")
        if revision == self.current_revision:
            digest = snapshot_digest(self._current.heights)
            return TerrainMaterialized(
                revision=revision,
                sample_sequence=self._markers[-1].sample_sequence,
                state=self._current,
                snapshot_sha256=digest,
                layered_state_sha256=layered_state_digest(self._current),
                height_min_m=float(np.min(self._current.heights)),
                height_max_m=float(np.max(self._current.heights)),
            )
        checkpoint = next(item for item in reversed(self._checkpoints) if item.revision <= revision)
        shape = (self.baseline.domain.rows, self.baseline.domain.columns)
        stable = np.frombuffer(
            zlib.decompress(checkpoint.compressed_stable_heights), dtype="<f4"
        ).reshape(shape)
        loose = np.frombuffer(
            zlib.decompress(checkpoint.compressed_loose_depths), dtype="<f4"
        ).reshape(shape)
        state = _make_terrain_state(stable, loose, checkpoint.bucket_volume_m3)
        if (
            snapshot_digest(state.heights) != checkpoint.snapshot_sha256
            or layered_state_digest(state) != checkpoint.layered_state_sha256
        ):
            raise TerrainHistoryError("terrain checkpoint digest mismatch")
        sample_sequence = checkpoint.sample_sequence
        replayed = 0
        for event in self._events:
            if event.revision <= checkpoint.revision:
                continue
            if event.revision > revision:
                break
            edit = TerrainEditInput(
                recording_epoch="replay",
                sample_sequence=event.sample_sequence,
                recording_time_ns=event.recording_time_ns,
                stream_epoch=event.stream_epoch,
                previous_teeth=event.previous_teeth,
                current_teeth=event.current_teeth,
                bucket_joint_normalized=event.bucket_joint_normalized,
            )
            result = apply_terrain_edit(
                self.baseline,
                state,
                event.revision - 1,
                edit,
                operation=event.operation,
            )
            if result.event is None or result.event != event:
                raise TerrainHistoryError("terrain event replay digest mismatch")
            state = result.state
            sample_sequence = event.sample_sequence
            replayed += 1
        if replayed > CHECKPOINT_EVENT_INTERVAL:
            raise TerrainHistoryError("terrain materialization exceeded the replay bound")
        digest = snapshot_digest(state.heights)
        return TerrainMaterialized(
            revision=revision,
            sample_sequence=sample_sequence,
            state=state,
            snapshot_sha256=digest,
            layered_state_sha256=layered_state_digest(state),
            height_min_m=float(np.min(state.heights)),
            height_max_m=float(np.max(state.heights)),
        )

    def materialize_sample(self, sample_sequence: int) -> TerrainMaterialized:
        return self.materialize_revision(self.revision_at(sample_sequence))

    def prune_before(self, retained_start_sample: int) -> None:
        keep_checkpoint = next(
            (
                index
                for index in range(len(self._checkpoints) - 1, -1, -1)
                if self._checkpoints[index].sample_sequence <= retained_start_sample
            ),
            0,
        )
        floor_revision = self._checkpoints[keep_checkpoint].revision
        if keep_checkpoint == 0 and self._markers[0].sample_sequence >= retained_start_sample:
            return
        self._checkpoints = self._checkpoints[keep_checkpoint:]
        self._events = [event for event in self._events if event.revision > floor_revision]
        floor_marker = next(
            (
                marker
                for marker in reversed(self._markers)
                if marker.sample_sequence <= retained_start_sample
            ),
            self._markers[0],
        )
        self._markers = [floor_marker] + [
            marker for marker in self._markers if marker.sample_sequence > retained_start_sample
        ]
        latest_checkpoint_revision = self._checkpoints[-1].revision
        self._last_checkpoint_event_count = sum(
            event.revision <= latest_checkpoint_revision for event in self._events
        )

    def _make_checkpoint(
        self, revision: int, sample_sequence: int, recording_time_ns: int
    ) -> _Checkpoint:
        stable_raw = self._current.stable_heights.astype("<f4", copy=False).tobytes(order="C")
        loose_raw = self._current.loose_depths.astype("<f4", copy=False).tobytes(order="C")
        return _Checkpoint(
            revision=revision,
            sample_sequence=sample_sequence,
            recording_time_ns=recording_time_ns,
            compressed_stable_heights=zlib.compress(stable_raw, level=6),
            compressed_loose_depths=zlib.compress(loose_raw, level=6),
            bucket_volume_m3=self._current.bucket_volume_m3,
            snapshot_sha256=snapshot_digest(self._current.heights),
            layered_state_sha256=layered_state_digest(self._current),
        )

    def _ensure_budget(self) -> None:
        if self.history_bytes > self._history_limit_bytes:
            raise TerrainHistoryError("terrain history exceeds its memory budget")


def _make_terrain_state(
    stable_heights: NDArray[np.float32],
    loose_depths: NDArray[np.float32],
    bucket_volume_m3: float,
) -> TerrainState:
    stable = np.array(stable_heights, dtype="<f4", copy=True, order="C")
    loose = np.array(loose_depths, dtype="<f4", copy=True, order="C")
    if stable.shape != loose.shape:
        raise ValueError("terrain layers must have matching shapes")
    if not np.isfinite(stable).all() or not np.isfinite(loose).all():
        raise ValueError("terrain layers must be finite")
    if bool(np.any(loose < np.float32(0.0))):
        raise ValueError("loose terrain depth must be non-negative")
    if not math.isfinite(bucket_volume_m3) or not (
        0.0 <= bucket_volume_m3 <= BUCKET_CAPACITY_M3 + _VOLUME_EPSILON_M3
    ):
        raise ValueError("bucket volume is outside its capacity")
    with np.errstate(over="ignore", invalid="ignore"):
        surface = np.add(stable, loose, dtype=np.float32)
    if not np.isfinite(surface).all():
        raise ValueError("terrain surface must be finite")
    stable.flags.writeable = False
    loose.flags.writeable = False
    surface.flags.writeable = False
    return TerrainState(stable, loose, surface, bucket_volume_m3)


def _apply_surface_delta(
    state: TerrainState,
    target_surface: NDArray[np.float32],
    candidates: set[int],
) -> TerrainState:
    stable = np.array(state.stable_heights, dtype="<f4", copy=True, order="C")
    loose = np.array(state.loose_depths, dtype="<f4", copy=True, order="C")
    for index in candidates:
        current = float(state.heights.flat[index])
        target = float(target_surface.flat[index])
        if target < current:
            reduction = current - target
            loose_reduction = min(float(loose.flat[index]), reduction)
            loose.flat[index] = float(loose.flat[index]) - loose_reduction
            stable.flat[index] = float(stable.flat[index]) - (reduction - loose_reduction)
        elif target > current:
            loose.flat[index] = float(loose.flat[index]) + (target - current)
    return _make_terrain_state(stable, loose, state.bucket_volume_m3)


def _validate_edit_input(
    baseline: TerrainBaseline,
    state: TerrainState,
    edit: TerrainEditInput,
) -> None:
    arrays = (state.stable_heights, state.loose_depths, state.heights)
    if any(
        array.shape != baseline.heights.shape or array.dtype != np.dtype("<f4") for array in arrays
    ):
        raise ValueError("terrain edit heightfield does not match its baseline")
    if any(not np.isfinite(array).all() for array in arrays):
        raise ValueError("terrain edit heightfield must be finite")
    if bool(np.any(state.loose_depths < np.float32(0.0))):
        raise ValueError("loose terrain depth must be non-negative")
    derived_surface = np.add(state.stable_heights, state.loose_depths, dtype=np.float32)
    if not np.array_equal(state.heights, derived_surface):
        raise ValueError("terrain surface does not match its canonical layers")
    if not 0.0 <= state.bucket_volume_m3 <= BUCKET_CAPACITY_M3 + _VOLUME_EPSILON_M3:
        raise ValueError("bucket volume is outside its capacity")
    values = (
        edit.bucket_joint_normalized,
        *(coordinate for point in edit.previous_teeth for coordinate in point),
        *(coordinate for point in edit.current_teeth for coordinate in point),
    )
    if any(not math.isfinite(value) for value in values):
        raise ValueError("terrain edit inputs must be finite")
    if not 0.0 <= edit.bucket_joint_normalized <= 1.0:
        raise ValueError("bucket posture must be normalized")


def _classify_operation(
    baseline: TerrainBaseline,
    heights: NDArray[np.float32],
    bucket_volume_m3: float,
    edit: TerrainEditInput,
) -> TerrainOperation | None:
    surface = _sample_height(baseline, heights, edit.current_teeth[1][0], edit.current_teeth[1][1])
    lowest_tooth = min(point[2] for point in (*edit.previous_teeth, *edit.current_teeth))
    if (
        edit.bucket_joint_normalized <= _CUT_POSTURE_MAX
        and bucket_volume_m3 < BUCKET_CAPACITY_M3 - _VOLUME_EPSILON_M3
        and lowest_tooth <= surface + _CONTACT_TOLERANCE_M
    ):
        return "cut"
    average_z = sum(point[2] for point in edit.current_teeth) / 3.0
    if (
        edit.bucket_joint_normalized >= _DUMP_POSTURE_MIN
        and bucket_volume_m3 > _VOLUME_EPSILON_M3
        and average_z >= surface + _DUMP_CLEARANCE_M
    ):
        return "deposit"
    return None


def _cut(
    baseline: TerrainBaseline,
    heights: NDArray[np.float32],
    bucket_volume_m3: float,
    edit: TerrainEditInput,
) -> tuple[set[int], float, float]:
    domain = baseline.domain
    radius = max(_TOOTH_RADIUS_M, domain.spacing_m * 0.75)
    row_min, row_max, column_min, column_max = _candidate_bounds(
        baseline, (*edit.previous_teeth, *edit.current_teeth), radius
    )
    candidates: list[tuple[int, float]] = []
    for row in range(row_min, row_max + 1):
        y = domain.origin_y_m + row * domain.spacing_m
        for column in range(column_min, column_max + 1):
            x = domain.origin_x_m + column * domain.spacing_m
            if (
                min(
                    _distance_to_segment_xy(x, y, previous, current)
                    for previous, current in zip(
                        edit.previous_teeth, edit.current_teeth, strict=True
                    )
                )
                > radius
            ):
                continue
            index = row * domain.columns + column
            current_height = float(heights[row, column])
            minimum_height = float(baseline.heights[row, column]) - MAX_CUT_FILL_M
            tooth_floor = min(
                min(previous[2], current[2])
                for previous, current in zip(edit.previous_teeth, edit.current_teeth, strict=True)
            )
            target = max(minimum_height, tooth_floor - 0.02)
            reduction = min(_CUT_DEPTH_PER_EDIT_M, max(0.0, current_height - target))
            if reduction > 0.0:
                candidates.append((index, reduction))
    if not candidates:
        return set(), 0.0, 0.0
    if len(candidates) > MAX_DIRTY_CELLS:
        candidates = candidates[:MAX_DIRTY_CELLS]
    cell_area = domain.spacing_m * domain.spacing_m
    proposed_volume = sum(reduction for _, reduction in candidates) * cell_area
    scale = min(1.0, (BUCKET_CAPACITY_M3 - bucket_volume_m3) / proposed_volume)
    before = np.array([float(heights.flat[index]) for index, _ in candidates])
    for index, reduction in candidates:
        heights.flat[index] = float(heights.flat[index]) - reduction * scale
    after = np.array([float(heights.flat[index]) for index, _ in candidates])
    actual_volume = float(np.sum(before - after, dtype=np.float64) * cell_area)
    changed = {
        index
        for (index, _), previous, current in zip(candidates, before, after, strict=True)
        if previous != current
    }
    return changed, min(actual_volume, BUCKET_CAPACITY_M3 - bucket_volume_m3), 0.0


def _deposit(
    baseline: TerrainBaseline,
    state: TerrainState,
    edit: TerrainEditInput,
) -> _DepositResult | None:
    domain = baseline.domain
    center = edit.current_teeth[1]
    row_min, row_max, column_min, column_max = _candidate_bounds(
        baseline, (center,), _DEPOSIT_RADIUS_M
    )
    weighted: list[tuple[int, float]] = []
    for row in range(row_min, row_max + 1):
        y = domain.origin_y_m + row * domain.spacing_m
        for column in range(column_min, column_max + 1):
            x = domain.origin_x_m + column * domain.spacing_m
            distance = math.hypot(x - center[0], y - center[1])
            weight = 1.0 - distance / _DEPOSIT_RADIUS_M
            if weight > 0.0:
                weighted.append((row * domain.columns + column, weight))
    if not weighted:
        return None
    relax_bounds = (
        max(0, row_min - _DEPOSIT_HALO_CELLS),
        min(domain.rows - 1, row_max + _DEPOSIT_HALO_CELLS),
        max(0, column_min - _DEPOSIT_HALO_CELLS),
        min(domain.columns - 1, column_max + _DEPOSIT_HALO_CELLS),
    )
    relax_cell_count = (relax_bounds[1] - relax_bounds[0] + 1) * (
        relax_bounds[3] - relax_bounds[2] + 1
    )
    if relax_cell_count > MAX_DIRTY_CELLS:
        return None

    cell_area = domain.spacing_m * domain.spacing_m
    loose = np.array(state.loose_depths, dtype="<f4", copy=True, order="C")
    remaining = state.bucket_volume_m3
    active = weighted
    for _ in range(len(weighted) + 1):
        if remaining <= _VOLUME_EPSILON_M3 or not active:
            break
        weight_sum = sum(weight for _, weight in active)
        next_active: list[tuple[int, float]] = []
        used = 0.0
        for index, weight in active:
            ceiling = float(baseline.heights.flat[index]) + MAX_CUT_FILL_M
            current_surface = float(state.stable_heights.flat[index]) + float(loose.flat[index])
            available_height = max(0.0, ceiling - current_surface)
            requested_height = remaining * (weight / weight_sum) / cell_area
            applied_height = min(available_height, requested_height)
            old = float(loose.flat[index])
            loose.flat[index] = old + applied_height
            actual_height = float(loose.flat[index]) - old
            used += actual_height * cell_area
            if available_height - actual_height > 1e-7:
                next_active.append((index, weight))
        remaining = max(0.0, remaining - used)
        active = next_active
    source_volume = state.bucket_volume_m3 - remaining
    if source_volume <= _VOLUME_EPSILON_M3:
        return None

    relaxed = _relax_loose(baseline, state.stable_heights, loose, relax_bounds)
    if relaxed is None:
        return None
    relaxed_loose, passes, touched, cell_visits = relaxed
    net_volume = float(np.sum(relaxed_loose - state.loose_depths, dtype=np.float64) * cell_area)
    if (
        net_volume <= _VOLUME_EPSILON_M3
        or abs(net_volume - source_volume) > _VOLUME_CONSERVATION_TOLERANCE_M3
    ):
        return None
    deposited_volume = min(state.bucket_volume_m3, net_volume)
    next_state = _make_terrain_state(
        state.stable_heights,
        relaxed_loose,
        max(0.0, state.bucket_volume_m3 - deposited_volume),
    )
    changed = frozenset(
        index
        for index in _indices_in_bounds(domain.columns, relax_bounds)
        if float(next_state.heights.flat[index]) != float(state.heights.flat[index])
    )
    if not changed or len(changed) > MAX_DIRTY_CELLS:
        return None
    return _DepositResult(
        state=next_state,
        changed=changed,
        deposited_volume_m3=deposited_volume,
        relaxation_passes=passes,
        relaxation_touched_cells=len(touched),
        relaxation_cell_visits=cell_visits,
    )


def _relax_loose(
    baseline: TerrainBaseline,
    stable_heights: NDArray[np.float32],
    loose_depths: NDArray[np.float32],
    bounds: tuple[int, int, int, int],
) -> tuple[NDArray[np.float32], int, set[int], int] | None:
    domain = baseline.domain
    working = np.array(loose_depths, dtype="<f4", copy=True, order="C")
    domain_indices = tuple(_indices_in_bounds(domain.columns, bounds))
    row_min, row_max, column_min, column_max = bounds
    surface_row_min = max(0, row_min - 1)
    surface_row_max = min(domain.rows - 1, row_max + 1)
    surface_column_min = max(0, column_min - 1)
    surface_column_max = min(domain.columns - 1, column_max + 1)
    local_shape = (row_max - row_min + 1, column_max - column_min + 1)
    local_cell_count = local_shape[0] * local_shape[1]
    surface_columns = surface_column_max - surface_column_min + 1
    edge_sources_list: list[int] = []
    edge_neighbors_list: list[int] = []
    edge_neighbors_inside_list: list[bool] = []
    for index in domain_indices:
        row, column = divmod(index, domain.columns)
        for row_delta, column_delta in _RELAXATION_NEIGHBORS:
            neighbor_row = row + row_delta
            neighbor_column = column + column_delta
            if not (0 <= neighbor_row < domain.rows and 0 <= neighbor_column < domain.columns):
                continue
            neighbor = neighbor_row * domain.columns + neighbor_column
            inside = _index_in_bounds(neighbor_row, neighbor_column, bounds)
            if inside and neighbor < index:
                continue
            edge_sources_list.append(index)
            edge_neighbors_list.append(neighbor)
            edge_neighbors_inside_list.append(inside)
    edge_sources = np.asarray(edge_sources_list, dtype=np.intp)
    edge_neighbors = np.asarray(edge_neighbors_list, dtype=np.intp)
    edge_neighbors_inside = np.asarray(edge_neighbors_inside_list, dtype=np.bool_)
    source_rows, source_columns = np.divmod(edge_sources, domain.columns)
    neighbor_rows, neighbor_columns = np.divmod(edge_neighbors, domain.columns)
    source_surface_offsets = (
        (source_rows - surface_row_min) * surface_columns + source_columns - surface_column_min
    )
    neighbor_surface_offsets = (
        (neighbor_rows - surface_row_min) * surface_columns + neighbor_columns - surface_column_min
    )
    threshold = (
        math.tan(math.radians(REPOSE_ANGLE_DEG)) * domain.spacing_m + REPOSE_HEIGHT_TOLERANCE_M
    )
    passes = 0
    cell_visits = 0
    touched: set[int] = set()
    while True:
        if cell_visits + len(domain_indices) > MAX_RELAXATION_CELL_VISITS:
            return None
        cell_visits += len(domain_indices)
        surface = np.add(
            stable_heights[
                surface_row_min : surface_row_max + 1,
                surface_column_min : surface_column_max + 1,
            ],
            working[
                surface_row_min : surface_row_max + 1,
                surface_column_min : surface_column_max + 1,
            ],
            dtype=np.float32,
        )
        surface_flat = surface.reshape(-1)
        difference = (
            surface_flat[source_surface_offsets] - surface_flat[neighbor_surface_offsets]
        ).astype(np.float64)
        positive = difference > threshold
        negative = difference < -threshold
        donors = np.where(positive, edge_sources, edge_neighbors)
        receivers = np.where(positive, edge_neighbors, edge_sources)
        receiver_surface_offsets = np.where(
            positive, neighbor_surface_offsets, source_surface_offsets
        )
        valid = np.logical_or(positive, negative)
        valid &= np.logical_or(edge_neighbors_inside, donors == edge_sources)
        donor_loose = working.reshape(-1)[donors].astype(np.float64)
        receiver_capacity = np.maximum(
            0.0,
            baseline.heights.reshape(-1)[receivers].astype(np.float64)
            + MAX_CUT_FILL_M
            - surface_flat[receiver_surface_offsets].astype(np.float64),
        )
        flux = np.minimum.reduce(
            (
                0.5 * (np.abs(difference) - threshold),
                donor_loose,
                receiver_capacity,
            )
        )
        valid &= donor_loose > _RELAXATION_FLUX_EPSILON_M
        valid &= flux > _RELAXATION_FLUX_EPSILON_M
        if bool(np.any(valid & ~edge_neighbors_inside)):
            return None
        valid &= edge_neighbors_inside
        if not bool(np.any(valid)):
            working.flags.writeable = False
            return working, passes, touched, cell_visits
        if passes >= MAX_RELAXATION_PASSES:
            return None

        proposal_donors = donors[valid]
        proposal_receivers = receivers[valid]
        proposal_flux = flux[valid]
        proposal_capacity = receiver_capacity[valid]
        proposal_donor_rows, proposal_donor_columns = np.divmod(proposal_donors, domain.columns)
        proposal_receiver_rows, proposal_receiver_columns = np.divmod(
            proposal_receivers, domain.columns
        )
        donor_local = (
            (proposal_donor_rows - row_min) * local_shape[1] + proposal_donor_columns - column_min
        )
        receiver_local = (
            (proposal_receiver_rows - row_min) * local_shape[1]
            + proposal_receiver_columns
            - column_min
        )
        donor_totals = np.bincount(donor_local, weights=proposal_flux, minlength=local_cell_count)
        donor_scale = np.minimum(
            1.0,
            working.reshape(-1)[proposal_donors].astype(np.float64) / donor_totals[donor_local],
        )
        donor_scaled = proposal_flux * donor_scale
        receiver_totals = np.bincount(
            receiver_local, weights=donor_scaled, minlength=local_cell_count
        )
        actual = donor_scaled * np.minimum(1.0, proposal_capacity / receiver_totals[receiver_local])
        applied = actual > _RELAXATION_FLUX_EPSILON_M
        if not bool(np.any(applied)):
            return None
        proposal_donors = proposal_donors[applied]
        proposal_receivers = proposal_receivers[applied]
        donor_local = donor_local[applied]
        receiver_local = receiver_local[applied]
        actual = actual[applied]
        delta = np.zeros(local_cell_count, dtype=np.float64)
        np.add.at(delta, donor_local, -actual)
        np.add.at(delta, receiver_local, actual)
        local_working = working[row_min : row_max + 1, column_min : column_max + 1]
        values = local_working.astype(np.float64) + delta.reshape(local_shape)
        if bool(np.any(values < -_RELAXATION_FLUX_EPSILON_M)):
            return None
        local_working[...] = np.maximum(0.0, values)
        touched.update(int(index) for index in proposal_donors)
        touched.update(int(index) for index in proposal_receivers)
        passes += 1


def _indices_in_bounds(columns: int, bounds: tuple[int, int, int, int]) -> range | tuple[int, ...]:
    row_min, row_max, column_min, column_max = bounds
    if column_min == 0 and column_max == columns - 1:
        return range(row_min * columns, (row_max + 1) * columns)
    return tuple(
        row * columns + column
        for row in range(row_min, row_max + 1)
        for column in range(column_min, column_max + 1)
    )


def _index_in_bounds(row: int, column: int, bounds: tuple[int, int, int, int]) -> bool:
    return bounds[0] <= row <= bounds[1] and bounds[2] <= column <= bounds[3]


def _candidate_bounds(
    baseline: TerrainBaseline, points: tuple[ToothPoint, ...], radius: float
) -> tuple[int, int, int, int]:
    domain = baseline.domain
    x_min = min(point[0] for point in points) - radius
    x_max = max(point[0] for point in points) + radius
    y_min = min(point[1] for point in points) - radius
    y_max = max(point[1] for point in points) + radius
    column_min = max(0, math.floor((x_min - domain.origin_x_m) / domain.spacing_m))
    column_max = min(domain.columns - 1, math.ceil((x_max - domain.origin_x_m) / domain.spacing_m))
    row_min = max(0, math.floor((y_min - domain.origin_y_m) / domain.spacing_m))
    row_max = min(domain.rows - 1, math.ceil((y_max - domain.origin_y_m) / domain.spacing_m))
    return row_min, row_max, column_min, column_max


def _sample_height(
    baseline: TerrainBaseline,
    heights: NDArray[np.float32],
    x: float,
    y: float,
) -> float:
    domain = baseline.domain
    column = min(
        domain.columns - 1.0,
        max(0.0, (x - domain.origin_x_m) / domain.spacing_m),
    )
    row = min(
        domain.rows - 1.0,
        max(0.0, (y - domain.origin_y_m) / domain.spacing_m),
    )
    column0 = math.floor(column)
    row0 = math.floor(row)
    column1 = min(domain.columns - 1, column0 + 1)
    row1 = min(domain.rows - 1, row0 + 1)
    tx = column - column0
    ty = row - row0
    bottom = float(heights[row0, column0]) * (1.0 - tx) + float(heights[row0, column1]) * tx
    top = float(heights[row1, column0]) * (1.0 - tx) + float(heights[row1, column1]) * tx
    return bottom * (1.0 - ty) + top * ty


def _distance_to_segment_xy(x: float, y: float, start: ToothPoint, end: ToothPoint) -> float:
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    length_squared = dx * dx + dy * dy
    if length_squared <= 1e-18:
        return math.hypot(x - start[0], y - start[1])
    ratio = min(1.0, max(0.0, ((x - start[0]) * dx + (y - start[1]) * dy) / length_squared))
    return math.hypot(x - (start[0] + ratio * dx), y - (start[1] + ratio * dy))


def _event_size_upper_bound(event: TerrainEditEvent) -> int:
    return 768 + event.changed_cells * 2
