"""Session-bound terrain preview staging and authoritative static terrain history."""

from __future__ import annotations

import threading
import time
import uuid
from collections import defaultdict
from collections.abc import Callable
from concurrent.futures import Future, ThreadPoolExecutor
from dataclasses import dataclass, replace
from typing import Literal

from .recording import BufferSnapshot, ChunkedRecordingBuffer
from .replay_contract import SourceMode
from .terrain import TerrainBaseline, default_terrain_spec, generate_terrain
from .terrain_excavation import (
    TerrainEditEvent,
    TerrainEditInput,
    TerrainHistoryError,
    TerrainMaterialized,
    TerrainPatch,
    TerrainRevisionInfo,
    TerrainTimeline,
)

TerrainAction = Literal["apply_preview", "reset_terrain"]
PREVIEW_TTL_SECONDS = 300.0
PREVIEWS_PER_SESSION = 4
TERRAIN_WORKERS = 2
TERRAIN_PENDING_LIMIT = 8


class TerrainCommandError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class TerrainView:
    recording_epoch: str
    selected_sample_sequence: int
    terrain_epoch: str
    terrain_config_id: str
    terrain_algorithm_version: str
    terrain_revision: int
    rows: int
    columns: int
    origin_xy_m: tuple[float, float]
    spacing_m: float
    height_min_m: float
    height_max_m: float
    snapshot_sha256: str
    bucket_soil_volume_m3: float
    read_only: bool
    snapshot_required: bool

    def as_message(self) -> dict[str, object]:
        return {
            "type": "terrain_view",
            "recording_epoch": self.recording_epoch,
            "selected_sample_sequence": self.selected_sample_sequence,
            "terrain_epoch": self.terrain_epoch,
            "terrain_config_id": self.terrain_config_id,
            "terrain_algorithm_version": self.terrain_algorithm_version,
            "terrain_revision": self.terrain_revision,
            "rows": self.rows,
            "columns": self.columns,
            "origin_xy_m": list(self.origin_xy_m),
            "spacing_m": self.spacing_m,
            "height_min_m": self.height_min_m,
            "height_max_m": self.height_max_m,
            "snapshot_sha256": self.snapshot_sha256,
            "bucket_soil_volume_m3": self.bucket_soil_volume_m3,
            "read_only": self.read_only,
            "snapshot_required": self.snapshot_required,
        }


@dataclass(frozen=True)
class TerrainApplied:
    id: str
    action: TerrainAction
    recording_epoch: str
    terrain_epoch: str
    terrain_config_id: str
    terrain_revision: int
    selected_sample_sequence: int

    def as_message(self) -> dict[str, object]:
        return {
            "type": "terrain_applied",
            "id": self.id,
            "action": self.action,
            "recording_epoch": self.recording_epoch,
            "terrain_epoch": self.terrain_epoch,
            "terrain_config_id": self.terrain_config_id,
            "terrain_revision": self.terrain_revision,
            "selected_sample_sequence": self.selected_sample_sequence,
        }


@dataclass(frozen=True)
class TerrainPreview:
    token: str
    session_id: str
    source_recording_epoch: str
    source_terrain_epoch: str
    expires_at: float
    baseline: TerrainBaseline

    def public_metadata(self) -> dict[str, object]:
        return {
            "token": self.token,
            "expires_in_seconds": max(0, int(self.expires_at - time.monotonic())),
            **self.baseline.metadata(),
        }


@dataclass(frozen=True)
class _TerrainBoundary:
    sample_sequence: int
    terrain_epoch: str
    baseline: TerrainBaseline
    timeline: TerrainTimeline
    read_only: bool


class TerrainController:
    def __init__(
        self,
        recording: ChunkedRecordingBuffer,
        *,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.recording = recording
        self._clock = clock
        self._lock = threading.Lock()
        self._executor = ThreadPoolExecutor(
            max_workers=TERRAIN_WORKERS, thread_name_prefix="babylon-sim-terrain"
        )
        self._closed = False
        self._default = generate_terrain(default_terrain_spec())
        self._recording_epoch = recording.recording_epoch
        self._source_mode = SourceMode.LIVE
        default_timeline = TerrainTimeline(self._default, start_sample_sequence=0)
        self._boundaries: list[_TerrainBoundary] = [
            _TerrainBoundary(0, uuid.uuid4().hex, self._default, default_timeline, False)
        ]
        self._previews: dict[str, TerrainPreview] = {}
        self._session_tokens: dict[str, set[str]] = defaultdict(set)
        self._pending_jobs: dict[str, set[Future[TerrainBaseline]]] = defaultdict(set)
        self._session_generation: dict[str, int] = defaultdict(int)
        self._preview_generation = 0
        self._edit_condition = threading.Condition()
        self._pending_edit: TerrainEditInput | None = None
        self._pending_reset: TerrainEditInput | None = None
        self._edit_stopping = False
        self._previous_edit: tuple[str, str, TerrainEditInput] | None = None
        self._latest_patches: dict[tuple[str, int], TerrainPatch] = {}
        self._dropped_edit_inputs = 0
        self._processed_edit_inputs = 0
        self._edit_fault: str | None = None
        self._edit_thread = threading.Thread(
            target=self._edit_loop,
            name="babylon-sim-terrain-edit",
            daemon=False,
        )
        self._edit_thread.start()

    def close(self) -> None:
        with self._edit_condition:
            self._edit_stopping = True
            self._edit_condition.notify_all()
        if self._edit_thread is not threading.current_thread():
            self._edit_thread.join(timeout=3.0)
        with self._lock:
            self._closed = True
            self._preview_generation += 1
            pending = tuple(job for jobs in self._pending_jobs.values() for job in jobs)
            self._previews.clear()
            self._session_tokens.clear()
        for job in pending:
            job.cancel()
        self._executor.shutdown(wait=True, cancel_futures=True)

    def submit_live_edit(self, edit: TerrainEditInput) -> None:
        """Publish one immutable newest-wins input without terrain work on the caller."""

        with self._edit_condition:
            if self._edit_stopping:
                return
            if edit.reset_bucket:
                if self._pending_edit is not None:
                    self._dropped_edit_inputs += 1
                if self._pending_reset is not None:
                    self._dropped_edit_inputs += 1
                self._pending_edit = None
                self._pending_reset = edit
            else:
                if self._pending_edit is not None:
                    self._dropped_edit_inputs += 1
                self._pending_edit = edit
            self._edit_condition.notify()

    def stage_preview(
        self,
        session_id: str,
        spec: object,
        *,
        expected_recording_epoch: str,
        expected_terrain_epoch: str,
    ) -> Future[TerrainPreview]:
        with self._lock:
            self._ensure_open_locked()
            self._cleanup_expired_locked()
            current = self._boundaries[-1]
            if expected_recording_epoch != self._recording_epoch:
                raise TerrainCommandError(
                    "stale_recording_epoch", "recording changed before preview"
                )
            if expected_terrain_epoch != current.terrain_epoch:
                raise TerrainCommandError("stale_terrain_epoch", "terrain changed before preview")
            if self._source_mode is SourceMode.IMPORTED:
                raise TerrainCommandError("terrain_read_only", "imported terrain is read-only")
            pending = self._pending_jobs.get(session_id)
            pending_count = 0 if pending is None else len(pending)
            if len(self._session_tokens[session_id]) + pending_count >= PREVIEWS_PER_SESSION:
                raise TerrainCommandError(
                    "too_many_terrain_previews", "session preview limit reached"
                )
            if sum(len(jobs) for jobs in self._pending_jobs.values()) >= TERRAIN_PENDING_LIMIT:
                raise TerrainCommandError("terrain_worker_busy", "terrain generation queue is full")
            session_generation = self._session_generation[session_id]
            preview_generation = self._preview_generation
            result: Future[TerrainPreview] = Future()
            try:
                generated = self._executor.submit(generate_terrain, spec)
            except RuntimeError as exc:
                raise TerrainCommandError(
                    "server_shutting_down", "terrain worker is unavailable"
                ) from exc
            self._pending_jobs[session_id].add(generated)

        def finish(source: Future[TerrainBaseline]) -> None:
            published_token: str | None = None
            try:
                baseline = source.result()
                recording_epoch = self.recording.snapshot().recording_epoch
                with self._lock:
                    self._release_pending_locked(session_id, source)
                    self._ensure_open_locked()
                    self._cleanup_expired_locked()
                    if (
                        result.cancelled()
                        or self._session_generation[session_id] != session_generation
                        or self._preview_generation != preview_generation
                        or recording_epoch != expected_recording_epoch
                        or self._source_mode is SourceMode.IMPORTED
                    ):
                        raise TerrainCommandError(
                            "invalid_terrain_preview", "terrain preview was cancelled"
                        )
                    token = uuid.uuid4().hex
                    preview = TerrainPreview(
                        token=token,
                        session_id=session_id,
                        source_recording_epoch=expected_recording_epoch,
                        source_terrain_epoch=expected_terrain_epoch,
                        expires_at=self._clock() + PREVIEW_TTL_SECONDS,
                        baseline=baseline,
                    )
                    self._previews[token] = preview
                    self._session_tokens[session_id].add(token)
                    published_token = token
                result.set_result(preview)
            except Exception as exc:
                with self._lock:
                    self._release_pending_locked(session_id, source)
                    if published_token is not None:
                        self._remove_preview_locked(published_token)
                if not result.done():
                    result.set_exception(exc)

        generated.add_done_callback(finish)
        return result

    def preview(self, session_id: str, token: str) -> TerrainPreview:
        with self._lock:
            self._cleanup_expired_locked()
            preview = self._previews.get(token)
            if preview is None or preview.session_id != session_id:
                raise TerrainCommandError(
                    "invalid_terrain_preview", "terrain preview is unavailable"
                )
            return preview

    def cancel_preview(self, session_id: str, token: str) -> bool:
        with self._lock:
            preview = self._previews.get(token)
            if preview is None or preview.session_id != session_id:
                return False
            self._remove_preview_locked(token)
            return True

    def cancel_session(self, session_id: str) -> None:
        with self._lock:
            self._session_generation[session_id] += 1
            pending = tuple(self._pending_jobs.get(session_id, ()))
            for token in tuple(self._session_tokens.get(session_id, ())):
                self._remove_preview_locked(token)
        for job in pending:
            job.cancel()

    def apply_preview(
        self,
        session_id: str,
        request_id: str,
        token: str,
        *,
        expected_recording_epoch: str,
        expected_terrain_epoch: str,
        selected_sample_sequence: int,
    ) -> TerrainApplied:
        snapshot = self.recording.snapshot()
        with self._lock:
            self._sync_recording_locked(snapshot.recording_epoch, self._source_mode)
            self._cleanup_expired_locked()
            preview = self._previews.get(token)
            current = self._boundaries[-1]
            if preview is None or preview.session_id != session_id:
                raise TerrainCommandError(
                    "invalid_terrain_preview", "terrain preview is unavailable"
                )
            if self._source_mode is SourceMode.IMPORTED:
                raise TerrainCommandError("terrain_read_only", "imported terrain is read-only")
            if expected_recording_epoch != snapshot.recording_epoch or (
                preview.source_recording_epoch != snapshot.recording_epoch
            ):
                raise TerrainCommandError("stale_recording_epoch", "recording changed before apply")
            if expected_terrain_epoch != current.terrain_epoch or (
                preview.source_terrain_epoch != current.terrain_epoch
            ):
                raise TerrainCommandError("stale_terrain_epoch", "terrain changed before apply")
            self._remove_preview_locked(token)
            timeline = TerrainTimeline(
                preview.baseline,
                start_sample_sequence=max(0, selected_sample_sequence),
            )
            boundary = _TerrainBoundary(
                sample_sequence=max(0, selected_sample_sequence),
                terrain_epoch=uuid.uuid4().hex,
                baseline=preview.baseline,
                timeline=timeline,
                read_only=False,
            )
            self._boundaries.append(boundary)
            return self._applied(request_id, "apply_preview", snapshot.recording_epoch, boundary)

    def reset(
        self,
        request_id: str,
        *,
        expected_recording_epoch: str,
        expected_terrain_epoch: str,
        selected_sample_sequence: int,
    ) -> TerrainApplied:
        snapshot = self.recording.snapshot()
        with self._lock:
            self._sync_recording_locked(snapshot.recording_epoch, self._source_mode)
            current = self._boundaries[-1]
            if self._source_mode is SourceMode.IMPORTED:
                raise TerrainCommandError("terrain_read_only", "imported terrain is read-only")
            if expected_recording_epoch != snapshot.recording_epoch:
                raise TerrainCommandError("stale_recording_epoch", "recording changed before reset")
            if expected_terrain_epoch != current.terrain_epoch:
                raise TerrainCommandError("stale_terrain_epoch", "terrain changed before reset")
            current.timeline.reset(
                max(0, selected_sample_sequence),
                self._recording_time_for_sample(snapshot, selected_sample_sequence),
            )
            boundary = _TerrainBoundary(
                sample_sequence=max(0, selected_sample_sequence),
                terrain_epoch=current.terrain_epoch,
                baseline=current.baseline,
                timeline=current.timeline,
                read_only=False,
            )
            self._boundaries.append(boundary)
            return self._applied(request_id, "reset_terrain", snapshot.recording_epoch, boundary)

    def view_for(
        self,
        recording_epoch: str,
        selected_sample_sequence: int,
        source_mode: SourceMode,
    ) -> TerrainView:
        with self._lock:
            self._sync_recording_locked(recording_epoch, source_mode)
            boundary = self._boundaries[0]
            for candidate in self._boundaries:
                if candidate.sample_sequence > selected_sample_sequence:
                    break
                boundary = candidate
            materialized = boundary.timeline.info_at(selected_sample_sequence)
            return self._view(
                recording_epoch,
                selected_sample_sequence,
                boundary,
                materialized,
                snapshot_required=(
                    (boundary.terrain_epoch, materialized.revision) not in self._latest_patches
                ),
            )

    def snapshot_for(
        self,
        recording_epoch: str,
        terrain_epoch: str,
        terrain_revision: int,
    ) -> tuple[TerrainView, bytes]:
        with self._lock:
            if recording_epoch != self._recording_epoch:
                raise TerrainCommandError(
                    "terrain_snapshot_unavailable", "recording terrain is unavailable"
                )
            boundary = next(
                (
                    item
                    for item in reversed(self._boundaries)
                    if item.terrain_epoch == terrain_epoch
                    and terrain_revision <= item.timeline.current_revision
                ),
                None,
            )
            if boundary is None:
                raise TerrainCommandError(
                    "terrain_snapshot_unavailable", "terrain revision is unavailable"
                )
            materialized = boundary.timeline.materialize_revision(terrain_revision)
            view = self._view(
                recording_epoch,
                materialized.sample_sequence,
                boundary,
                materialized,
                snapshot_required=True,
            )
            return view, materialized.heights.tobytes(order="C")

    def sync_source(self, recording_epoch: str, source_mode: SourceMode) -> None:
        with self._lock:
            self._sync_recording_locked(recording_epoch, source_mode)

    def patch_for(self, terrain_epoch: str, new_revision: int) -> TerrainPatch | None:
        with self._lock:
            return self._latest_patches.get((terrain_epoch, new_revision))

    @property
    def dropped_edit_inputs(self) -> int:
        with self._edit_condition:
            return self._dropped_edit_inputs

    @property
    def processed_edit_inputs(self) -> int:
        with self._edit_condition:
            return self._processed_edit_inputs

    @property
    def edit_fault(self) -> str | None:
        with self._edit_condition:
            return self._edit_fault

    @property
    def latest_edit_event(self) -> TerrainEditEvent | None:
        with self._lock:
            return self._boundaries[-1].timeline.latest_event

    def _edit_loop(self) -> None:
        while True:
            edit: TerrainEditInput | None
            with self._edit_condition:
                self._edit_condition.wait_for(
                    lambda: (
                        self._edit_stopping
                        or self._pending_reset is not None
                        or self._pending_edit is not None
                    )
                )
                if self._edit_stopping:
                    return
                if self._pending_reset is not None:
                    edit = self._pending_reset
                    self._pending_reset = None
                else:
                    edit = self._pending_edit
                    self._pending_edit = None
            assert edit is not None
            snapshot = self.recording.snapshot()
            retained_start_sample = (
                None if not snapshot.chunks else int(snapshot.chunks[0].sample_sequence[0])
            )
            with self._lock:
                if (
                    self._closed
                    or self._source_mode is SourceMode.IMPORTED
                    or edit.recording_epoch != self._recording_epoch
                    or snapshot.recording_epoch != self._recording_epoch
                ):
                    self._previous_edit = None
                    with self._edit_condition:
                        self._processed_edit_inputs += 1
                    continue
                boundary = self._boundaries[-1]
                try:
                    if retained_start_sample is not None:
                        boundary.timeline.prune_before(retained_start_sample)
                    if edit.reset_bucket:
                        boundary.timeline.clear_bucket(edit.sample_sequence, edit.recording_time_ns)
                        self._previous_edit = None
                    else:
                        previous = self._previous_edit
                        key = (self._recording_epoch, boundary.terrain_epoch)
                        if (
                            previous is None
                            or previous[:2] != key
                            or previous[2].stream_epoch != edit.stream_epoch
                            or previous[2].sample_sequence >= edit.sample_sequence
                        ):
                            self._previous_edit = (*key, edit)
                        else:
                            effective = replace(edit, previous_teeth=previous[2].current_teeth)
                            patch = boundary.timeline.apply(effective)
                            self._previous_edit = (*key, edit)
                            if patch is not None:
                                self._latest_patches[
                                    (boundary.terrain_epoch, patch.new_revision)
                                ] = patch
                                while len(self._latest_patches) > 128:
                                    self._latest_patches.pop(next(iter(self._latest_patches)))
                except TerrainHistoryError as exc:
                    self._previous_edit = None
                    with self._edit_condition:
                        self._edit_fault = f"terrain_history_unavailable: {exc}"
                finally:
                    with self._edit_condition:
                        self._processed_edit_inputs += 1

    def _sync_recording_locked(self, recording_epoch: str, source_mode: SourceMode) -> None:
        if recording_epoch == self._recording_epoch and source_mode is self._source_mode:
            return
        self._preview_generation += 1
        if recording_epoch != self._recording_epoch:
            self._recording_epoch = recording_epoch
            self._previews.clear()
            self._session_tokens.clear()
            default_timeline = TerrainTimeline(self._default, start_sample_sequence=0)
            self._boundaries = [
                _TerrainBoundary(
                    0,
                    uuid.uuid4().hex,
                    self._default,
                    default_timeline,
                    source_mode is SourceMode.IMPORTED,
                )
            ]
            self._latest_patches.clear()
            with self._edit_condition:
                self._edit_fault = None
        elif source_mode is not self._source_mode:
            current = self._boundaries[-1]
            self._boundaries.append(
                _TerrainBoundary(
                    current.sample_sequence,
                    current.terrain_epoch,
                    current.baseline,
                    current.timeline,
                    source_mode is SourceMode.IMPORTED,
                )
            )
        self._source_mode = source_mode

    def _cleanup_expired_locked(self) -> None:
        now = self._clock()
        for token, preview in tuple(self._previews.items()):
            if preview.expires_at <= now:
                self._remove_preview_locked(token)

    def _remove_preview_locked(self, token: str) -> None:
        preview = self._previews.pop(token, None)
        if preview is None:
            return
        tokens = self._session_tokens.get(preview.session_id)
        if tokens is not None:
            tokens.discard(token)
            if not tokens:
                self._session_tokens.pop(preview.session_id, None)

    def _release_pending_locked(self, session_id: str, source: Future[TerrainBaseline]) -> None:
        pending = self._pending_jobs.get(session_id)
        if pending is None:
            return
        pending.discard(source)
        if not pending:
            self._pending_jobs.pop(session_id, None)

    def _ensure_open_locked(self) -> None:
        if self._closed:
            raise TerrainCommandError("server_shutting_down", "terrain controller is closed")

    @staticmethod
    def _recording_time_for_sample(snapshot: BufferSnapshot, sample_sequence: int) -> int:
        for chunk in snapshot.chunks:
            matches = chunk.sample_sequence == max(0, sample_sequence)
            if matches.any():
                return int(chunk.recording_time_ns[matches][0])
        return 0

    @staticmethod
    def _view(
        recording_epoch: str,
        selected_sample_sequence: int,
        boundary: _TerrainBoundary,
        materialized: TerrainMaterialized | TerrainRevisionInfo,
        *,
        snapshot_required: bool,
    ) -> TerrainView:
        baseline = boundary.baseline
        return TerrainView(
            recording_epoch=recording_epoch,
            selected_sample_sequence=selected_sample_sequence,
            terrain_epoch=boundary.terrain_epoch,
            terrain_config_id=baseline.config_id,
            terrain_algorithm_version=baseline.algorithm_version,
            terrain_revision=materialized.revision,
            rows=baseline.domain.rows,
            columns=baseline.domain.columns,
            origin_xy_m=(baseline.domain.origin_x_m, baseline.domain.origin_y_m),
            spacing_m=baseline.domain.spacing_m,
            height_min_m=materialized.height_min_m,
            height_max_m=materialized.height_max_m,
            snapshot_sha256=materialized.snapshot_sha256,
            bucket_soil_volume_m3=materialized.bucket_volume_m3,
            read_only=boundary.read_only,
            snapshot_required=snapshot_required,
        )

    @staticmethod
    def _applied(
        request_id: str,
        action: TerrainAction,
        recording_epoch: str,
        boundary: _TerrainBoundary,
    ) -> TerrainApplied:
        return TerrainApplied(
            id=request_id,
            action=action,
            recording_epoch=recording_epoch,
            terrain_epoch=boundary.terrain_epoch,
            terrain_config_id=boundary.baseline.config_id,
            terrain_revision=boundary.timeline.current_revision,
            selected_sample_sequence=boundary.sample_sequence,
        )
