"""Bounded RRD import staging and export lifecycle management."""

from __future__ import annotations

import hashlib
import tempfile
import threading
import time
import uuid
from collections.abc import Callable
from concurrent.futures import Future
from dataclasses import dataclass
from pathlib import Path
from typing import TYPE_CHECKING

from .recording import ChunkedRecordingBuffer
from .replay import PlaybackApplied, ReplayCommandError, ReplayWorker
from .replay_contract import IMPORT_TOKEN_TTL_SECONDS, SourceMode

if TYPE_CHECKING:
	from .rrd import ImportedRecording


class ExchangeError(RuntimeError):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class ImportSummary:
    token: str
    digest_sha256: str
    profile: str
    sample_count: int
    start_ns: int
    end_ns: int
    source_mode: SourceMode
    expires_in_seconds: int


@dataclass
class _StagedImport:
    token: str
    path: Path
    digest_sha256: str
    imported: ImportedRecording
    source_recording_epoch: str
    session_id: str
    expires_at: float


class RecordingExchange:
    def __init__(
        self,
        recording: ChunkedRecordingBuffer,
        replay: ReplayWorker,
        *,
        calibration_version: str,
        model_version: str,
        clock: Callable[[], float] = time.monotonic,
    ) -> None:
        self.recording = recording
        self.replay = replay
        self.calibration_version = calibration_version
        self.model_version = model_version
        self._clock = clock
        self._temporary = tempfile.TemporaryDirectory(prefix="babylon-sim-rrd-")
        self.root = Path(self._temporary.name)
        self._operation_lock = threading.Lock()
        self._staging_lock = threading.Lock()
        self._staged: dict[str, _StagedImport] = {}
        self._closed = False

    def upload_path(self) -> Path:
        if self._closed:
            raise ExchangeError("server_shutting_down", "recording exchange is closed")
        return self.root / f"upload-{uuid.uuid4().hex}.rrd"

    def stage_import(
        self,
        path: Path,
        *,
        expected_recording_epoch: str,
        session_id: str,
    ) -> ImportSummary:
        self._begin_operation()
        try:
            self._cleanup_expired()
            if self.recording.recording_epoch != expected_recording_epoch:
                raise ExchangeError(
                    "stale_recording_epoch", "recording changed before import validation"
                )
            digest = _sha256(path)
            try:
                from .rrd import RrdProfileError, import_rrd

                imported = import_rrd(path, expected_model_version=self.model_version)
            except RrdProfileError as exc:
                raise ExchangeError("invalid_rrd", str(exc)) from exc
            if imported.calibration_version != self.calibration_version:
                raise ExchangeError(
                    "incompatible_calibration",
                    "RRD calibration revision does not match this BabylonSim build",
                )
            token = uuid.uuid4().hex
            staged = _StagedImport(
                token=token,
                path=path,
                digest_sha256=digest,
                imported=imported,
                source_recording_epoch=expected_recording_epoch,
                session_id=session_id,
                expires_at=self._clock() + IMPORT_TOKEN_TTL_SECONDS,
            )
            with self._staging_lock:
                self._staged[token] = staged
            return ImportSummary(
                token=token,
                digest_sha256=digest,
                profile=imported.profile,
                sample_count=imported.sample_count,
                start_ns=imported.start_ns,
                end_ns=imported.end_ns,
                source_mode=imported.source_mode,
                expires_in_seconds=IMPORT_TOKEN_TTL_SECONDS,
            )
        except Exception:
            path.unlink(missing_ok=True)
            raise
        finally:
            self._end_operation()

    def commit_import(
        self,
        token: str,
        *,
        expected_recording_epoch: str,
        session_id: str,
    ) -> Future[PlaybackApplied]:
        self._cleanup_expired()
        with self._staging_lock:
            staged = self._staged.pop(token, None)
        if staged is None:
            raise ExchangeError("invalid_import_token", "import token is missing, used, or expired")
        try:
            if staged.session_id != session_id:
                raise ExchangeError(
                    "invalid_import_token", "import token belongs to another session"
                )
            if (
                staged.source_recording_epoch != expected_recording_epoch
                or self.recording.recording_epoch != expected_recording_epoch
            ):
                raise ExchangeError(
                    "stale_recording_epoch", "recording changed before import confirmation"
                )
            return self.replay.install_imported(
                f"import-{token}", expected_recording_epoch, staged.imported.data
            )
        except ReplayCommandError as exc:
            raise ExchangeError(exc.code, str(exc)) from exc
        finally:
            staged.path.unlink(missing_ok=True)

    def cancel(self, token: str, *, session_id: str) -> bool:
        with self._staging_lock:
            staged = self._staged.get(token)
            if staged is None or staged.session_id != session_id:
                return False
            self._staged.pop(token)
        staged.path.unlink(missing_ok=True)
        return True

    def cancel_session(self, session_id: str) -> None:
        with self._staging_lock:
            cancelled = [
                staged for staged in self._staged.values() if staged.session_id == session_id
            ]
            for staged in cancelled:
                self._staged.pop(staged.token, None)
        for staged in cancelled:
            staged.path.unlink(missing_ok=True)

    def begin_export(self, *, source_mode: SourceMode) -> Path:
        self._begin_operation()
        path = self.root / f"export-{uuid.uuid4().hex}.rrd"
        try:
            from .rrd import RrdProfileError, export_rrd

            export_rrd(
                self.recording.snapshot(),
                path,
                calibration_version=self.calibration_version,
                source_mode=source_mode,
                model_version=self.model_version,
            )
            return path
        except RrdProfileError as exc:
            path.unlink(missing_ok=True)
            self._end_operation()
            raise ExchangeError("export_failed", str(exc)) from exc
        except Exception:
            path.unlink(missing_ok=True)
            self._end_operation()
            raise

    def finish_export(self, path: Path) -> None:
        path.unlink(missing_ok=True)
        self._end_operation()

    def close(self) -> None:
        self._closed = True
        with self._staging_lock:
            staged = list(self._staged.values())
            self._staged.clear()
        for item in staged:
            item.path.unlink(missing_ok=True)
        self._temporary.cleanup()

    def _begin_operation(self) -> None:
        if self._closed:
            raise ExchangeError("server_shutting_down", "recording exchange is closed")
        if not self._operation_lock.acquire(blocking=False):
            raise ExchangeError("recording_operation_busy", "another RRD operation is running")

    def _end_operation(self) -> None:
        self._operation_lock.release()

    def _cleanup_expired(self) -> None:
        now = self._clock()
        with self._staging_lock:
            expired = [item for item in self._staged.values() if item.expires_at <= now]
            for item in expired:
                self._staged.pop(item.token, None)
        for item in expired:
            item.path.unlink(missing_ok=True)


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()
