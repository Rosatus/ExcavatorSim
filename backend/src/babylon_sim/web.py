"""Loopback aiohttp service for static assets and the realtime protocol."""

from __future__ import annotations

import asyncio
import contextlib
import json
import time
import uuid
from collections import deque
from collections.abc import Awaitable, Callable, Iterable
from concurrent.futures import Future
from pathlib import Path
from typing import cast

from aiohttp import WSMsgType, web
from aiohttp.client_exceptions import ClientConnectionResetError

from .constants import ACTIVE_JOINT_NAMES
from .exchange import ExchangeError
from .input_router import InputRouterError
from .paths import (
    FRONTEND_DIST_PATH,
    URDF_PATH,
    VISUAL_ASSETS_ROOT,
    VISUAL_MODEL_MANIFEST_PATH,
    VISUAL_MODEL_SCHEMA_PATH,
)
from .protocol import (
    CommandMessage,
    HelloMessage,
    InputMessage,
    PingMessage,
    PlaybackMessage,
    ProtocolError,
    TerrainMessage,
    decode_client_message,
    encode_server_message,
    error_message,
    load_version_manifest,
)
from .replay import AuthoritativeViewState, PlaybackApplied, ReplayCommandError
from .replay_contract import RECORDING_UPLOAD_MAX_BYTES
from .runtime import CommandResult, RuntimeCommandError, RuntimeController
from .series import SeriesQueryError, project_series
from .session_manager import ModelSelectionError, RuntimeSessionManager
from .terrain import TerrainSpecError, terrain_snapshot_bytes
from .terrain_controller import TerrainCommandError
from .visual_assets import VisualModelManifest, load_visual_model_manifest

HELLO_TIMEOUT_SECONDS = 3.0
INPUT_RATE_LIMIT = 80
COMMAND_RATE_LIMIT = 20
PING_RATE_LIMIT = 20
RATE_WINDOW_SECONDS = 1.0
MAX_PROTOCOL_VIOLATIONS = 3
# Leave headroom for strict JSON encoding/validation after each poll.
# A sender still emits only new ReplayWorker revisions, capped by DISPLAY_HZ.
VIEW_POLL_HZ = 200

RUNTIME_KEY = web.AppKey("runtime", RuntimeSessionManager)
FRONTEND_DIR_KEY = web.AppKey("frontend_dir", Path)
MODEL_PATH_KEY = web.AppKey("model_path", Path)
VISUAL_MODEL_KEY = web.AppKey("visual_model", VisualModelManifest)
ALLOWED_ORIGINS_KEY = web.AppKey("allowed_origins", frozenset[str])
ALLOW_MISSING_ORIGIN_KEY = web.AppKey("allow_missing_origin", bool)


class SlidingWindowRateLimiter:
    def __init__(self) -> None:
        self._events: dict[str, deque[float]] = {
            "input_snapshot": deque(),
            "command": deque(),
            "terrain_command": deque(),
            "ping": deque(),
        }

    def allow(self, message_type: str, now: float) -> bool:
        limits = {
            "input_snapshot": INPUT_RATE_LIMIT,
            "command": COMMAND_RATE_LIMIT,
            "terrain_command": COMMAND_RATE_LIMIT,
            "ping": PING_RATE_LIMIT,
        }
        events = self._events[message_type]
        cutoff = now - RATE_WINDOW_SECONDS
        while events and events[0] <= cutoff:
            events.popleft()
        if len(events) >= limits[message_type]:
            return False
        events.append(now)
        return True


def _state_message(
    view: AuthoritativeViewState,
    emitted_sequence: int,
    runtime: RuntimeSessionManager | RuntimeController,
) -> dict[str, object]:
    model_version = runtime.model_version
    visual_model_version = runtime.visual_model_version
    versions = load_version_manifest().for_model(
        model_version=model_version,
        visual_model_version=visual_model_version,
    )
    return {
        "type": "view_state",
        "emitted_sequence": emitted_sequence,
        "source_sequence": view.source_sequence,
        "simulation_epoch": view.simulation_epoch,
        "recording_epoch": view.recording_epoch,
        "buffer_generation": view.buffer_generation,
        "end_sample_sequence": view.end_sample_sequence,
        "view_revision": view.view_revision,
        "source_mode": view.source_mode.value,
        "playback_state": view.playback_state.value,
        "cursor_recording_time_ns": view.cursor_recording_time_ns,
        "retained_start_ns": view.retained_start_ns,
        "retained_end_ns": view.retained_end_ns,
        "selected_sample_sequence": view.selected_sample_sequence,
        "simulation_time_s": view.simulation_time_s,
        "lifecycle": view.lifecycle,
        "versions": versions.as_dict(),
        "joint_names": list(ACTIVE_JOINT_NAMES),
        "joint_position": list(view.joint_position),
        "joint_velocity": list(view.joint_velocity),
        "joint_acceleration": list(view.joint_acceleration),
        "frame_transforms": {
            name: [list(row) for row in matrix] for name, matrix in view.frame_transforms.items()
        },
        "quality_flags": list(view.quality_flags),
        "last_input_client_sequence": view.last_input_sequence,
        "server_monotonic_ms": view.server_monotonic_ms,
    }


def _status_message(runtime: RuntimeController) -> dict[str, object]:
    status = runtime.status_snapshot()
    return {
        "type": "status",
        "simulation_hz": status.simulation_hz,
        "state_hz": status.state_hz,
        "render_target_hz": status.render_target_hz,
        "overruns": status.overruns,
        "dropped_snapshots": status.dropped_snapshots,
        "controller_source": status.controller_source,
        "stale": status.stale,
    }


def _recording_status_message(runtime: RuntimeController) -> dict[str, object]:
    if runtime.recording is None or runtime.replay is None:
        raise RuntimeError("recording capability is unavailable")
    snapshot = runtime.recording.snapshot()
    view = runtime.replay.latest.read()
    return {
        "type": "recording_status",
        "recording_epoch": snapshot.recording_epoch,
        "buffer_generation": snapshot.buffer_generation,
        "end_sample_sequence": snapshot.end_sample_sequence,
        "sample_count": snapshot.sample_count,
        "retained_start_ns": snapshot.retained_start_ns,
        "retained_end_ns": snapshot.retained_end_ns,
        "evicted_samples": snapshot.evicted_samples,
        "source_mode": view.source_mode.value,
        "playback_state": view.playback_state.value,
        "cursor_recording_time_ns": view.cursor_recording_time_ns,
        "view_revision": view.view_revision,
    }


async def _send_command_result(
    send: Callable[[dict[str, object]], Awaitable[None]],
    future: Future[CommandResult],
    request_id: str,
) -> None:
    try:
        result = await asyncio.wrap_future(future)
    except RuntimeCommandError as exc:
        await send(
            error_message(
                ProtocolError(exc.code, str(exc), request_id=request_id, recoverable=True)
            )
        )
        return
    await send(
        {
            "type": "command_applied",
            "id": result.id,
            "command": result.command,
            "lifecycle": result.lifecycle,
            "state_sequence": result.state_sequence,
        }
    )


async def _send_playback_result(
    send: Callable[[dict[str, object]], Awaitable[None]],
    future: Future[PlaybackApplied],
    request_id: str,
) -> PlaybackApplied | None:
    try:
        result = await asyncio.wrap_future(future)
    except ReplayCommandError as exc:
        await send(
            error_message(
                ProtocolError(exc.code, str(exc), request_id=request_id, recoverable=True)
            )
        )
        return None
    await send(
        {
            "type": "playback_applied",
            "id": result.id,
            "action": result.action,
            "recording_epoch": result.recording_epoch,
            "buffer_generation": result.buffer_generation,
            "view_revision": result.view_revision,
            "source_mode": result.source_mode.value,
            "playback_state": result.playback_state.value,
            "cursor_recording_time_ns": result.cursor_recording_time_ns,
            "retained_start_ns": result.retained_start_ns,
            "retained_end_ns": result.retained_end_ns,
            "selected_sample_sequence": result.selected_sample_sequence,
        }
    )
    return result


def create_app(
    runtime: RuntimeController | RuntimeSessionManager,
    *,
    frontend_dir: Path = FRONTEND_DIST_PATH,
    model_path: Path = URDF_PATH,
    visual_manifest_path: Path = VISUAL_MODEL_MANIFEST_PATH,
    visual_assets_dir: Path = VISUAL_ASSETS_ROOT,
    visual_schema_path: Path = VISUAL_MODEL_SCHEMA_PATH,
    allowed_origins: Iterable[str] = (),
    allow_missing_origin: bool = False,
) -> web.Application:
    manager = (
        runtime if isinstance(runtime, RuntimeSessionManager) else RuntimeSessionManager(runtime)
    )
    app = web.Application(client_max_size=RECORDING_UPLOAD_MAX_BYTES)
    app[RUNTIME_KEY] = manager
    app[FRONTEND_DIR_KEY] = frontend_dir.resolve()
    app[MODEL_PATH_KEY] = model_path.resolve()
    app[VISUAL_MODEL_KEY] = load_visual_model_manifest(
        visual_manifest_path,
        assets_root=visual_assets_dir,
        schema_path=visual_schema_path,
    )
    app[ALLOWED_ORIGINS_KEY] = frozenset(allowed_origins)
    app[ALLOW_MISSING_ORIGIN_KEY] = allow_missing_origin

    async def on_startup(_: web.Application) -> None:
        runtime.start()

    async def on_cleanup(_: web.Application) -> None:
        runtime.stop()

    app.on_startup.append(on_startup)
    app.on_cleanup.append(on_cleanup)
    app.router.add_get("/health", _health)
    app.router.add_get("/api/model", _model)
    app.router.add_get("/api/visual-model", _visual_model)
    app.router.add_get("/api/visual-assets/{asset_id:[a-z][a-z0-9-]*}", _visual_asset)
    app.router.add_get("/api/visual-assets/{tail:.*}", _visual_asset_not_found)
    app.router.add_get("/api/recording/series", _recording_series)
    app.router.add_get("/api/recording/export", _recording_export)
    app.router.add_post("/api/recording/import/validate", _recording_import_validate)
    app.router.add_post("/api/recording/import/commit", _recording_import_commit)
    app.router.add_delete("/api/recording/import/{token}", _recording_import_cancel)
    app.router.add_post("/api/terrain/preview", _terrain_preview)
    app.router.add_get("/api/terrain/preview/{token}/snapshot", _terrain_preview_snapshot)
    app.router.add_delete("/api/terrain/preview/{token}", _terrain_preview_cancel)
    app.router.add_get("/api/terrain/snapshot", _terrain_snapshot)
    app.router.add_get("/ws", _websocket)
    app.router.add_get("/", _static)
    app.router.add_get("/{path:.*}", _static)
    return app


def _require_capability(
    runtime: RuntimeController | RuntimeSessionManager, capability: str
) -> None:
    if capability not in runtime.capabilities:
        raise web.HTTPConflict(
            text=f"capability_unavailable: {capability} is not available",
            content_type="application/problem+json",
        )


async def _health(request: web.Request) -> web.Response:
    manager = request.app[RUNTIME_KEY]
    runtime = manager.runtime
    snapshot = runtime.latest.read()
    versions = load_version_manifest().for_model(
        model_version=manager.model_version,
        visual_model_version=manager.visual_model_version,
    )
    return web.json_response(
        {
            "status": "ok" if runtime.is_running() else "starting",
            "lifecycle": snapshot.lifecycle,
            "stream_epoch": snapshot.stream_epoch,
            "model_id": manager.model_id,
            "versions": versions.as_dict(),
        }
    )


async def _model(request: web.Request) -> web.StreamResponse:
    model_path = request.app[RUNTIME_KEY].descriptor.urdf_path
    if not model_path.is_file():
        raise web.HTTPServiceUnavailable(text="vendored model is unavailable")
    return web.FileResponse(model_path, headers={"Content-Type": "application/xml; charset=utf-8"})


async def _visual_model(request: web.Request) -> web.Response:
    manager = request.app[RUNTIME_KEY]
    if manager.model_id == manager.registry.default_model_id:
        payload = request.app[VISUAL_MODEL_KEY].as_public_dict()
    else:
        # The combined SY135 contract has a different manifest shape from the
        # legacy segmented SY205 visual-assets manifest.  Never relabel the
        # latter with SY135 versions; expose the selected manifest as-is.
        try:
            raw = json.loads(manager.descriptor.visual_manifest_path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise web.HTTPServiceUnavailable(text="selected visual model is unavailable") from exc
        if not isinstance(raw, dict):
            raise web.HTTPServiceUnavailable(text="selected visual model contract is invalid")
        payload = raw
    payload.update(
        {
            "model_id": manager.model_id,
            "model_version": manager.model_version,
            "selected_visual_model_version": manager.visual_model_version,
        }
    )
    return web.json_response(payload)


async def _visual_asset(request: web.Request) -> web.StreamResponse:
    manager = request.app[RUNTIME_KEY]
    if manager.model_id != manager.registry.default_model_id:
        raise web.HTTPConflict(
            text="model_contract_mismatch: selected model has no segmented visual assets",
            content_type="application/problem+json",
        )
    result = request.app[VISUAL_MODEL_KEY].asset(request.match_info["asset_id"])
    if result is None:
        raise web.HTTPNotFound(text="unknown visual asset")
    entry, asset_path = result
    if not asset_path.is_file():
        raise web.HTTPServiceUnavailable(text="visual asset is unavailable")
    return web.FileResponse(
        asset_path,
        headers={
            "Content-Type": "model/gltf-binary",
            "Cache-Control": "public, max-age=31536000, immutable",
            "ETag": f'"sha256-{entry.sha256}"',
            "X-Content-Type-Options": "nosniff",
        },
    )


async def _visual_asset_not_found(_: web.Request) -> web.Response:
    raise web.HTTPNotFound(text="unknown visual asset")


async def _recording_series(request: web.Request) -> web.Response:
    runtime = request.app[RUNTIME_KEY]
    _require_capability(runtime, "recording")
    assert runtime.recording is not None
    try:
        fields = tuple(part for part in request.query.get("fields", "").split(",") if part)
        start_ns = int(request.query["from_ns"])
        end_ns = int(request.query["to_ns"])
        max_points = int(request.query.get("max_points", "1024"))
        result = await asyncio.to_thread(
            project_series,
            runtime.recording.snapshot(),
            fields,
            start_ns,
            end_ns,
            max_buckets=max_points,
        )
    except (KeyError, ValueError, SeriesQueryError) as exc:
        raise web.HTTPBadRequest(text=str(exc), content_type="application/problem+json") from exc
    return web.json_response(result.as_dict())


def _session_id(request: web.Request) -> str:
    session_id = request.headers.get("X-Godot-Pinocchio-Session", "")
    if not session_id or len(session_id) > 128:
        raise web.HTTPUnauthorized(
            text="a valid Godot/Pinocchio session header is required",
            content_type="application/problem+json",
        )
    return session_id


async def _recording_export(request: web.Request) -> web.StreamResponse:
    runtime = request.app[RUNTIME_KEY]
    _require_capability(runtime, "recording")
    _session_id(request)
    assert runtime.exchange is not None and runtime.replay is not None
    source_mode = runtime.replay.latest.read().source_mode
    try:
        path = await asyncio.to_thread(runtime.exchange.begin_export, source_mode=source_mode)
    except ExchangeError as exc:
        raise web.HTTPConflict(text=f"{exc.code}: {exc}") from exc
    response = web.StreamResponse(
        status=200,
        headers={
            "Content-Type": "application/octet-stream",
            "Content-Disposition": 'attachment; filename="godot-pinocchio-recording.rrd"',
            "Content-Length": str(path.stat().st_size),
        },
    )
    try:
        await response.prepare(request)
        with path.open("rb") as handle:
            while block := await asyncio.to_thread(handle.read, 1024 * 1024):
                await response.write(block)
        await response.write_eof()
        return response
    finally:
        runtime.exchange.finish_export(path)


async def _recording_import_validate(request: web.Request) -> web.Response:
    runtime = request.app[RUNTIME_KEY]
    _require_capability(runtime, "recording")
    assert runtime.exchange is not None
    session_id = _session_id(request)
    expected_epoch = request.query.get("expected_recording_epoch", "")
    if not expected_epoch:
        raise web.HTTPBadRequest(text="expected_recording_epoch is required")
    path = runtime.exchange.upload_path()
    total = 0
    try:
        with path.open("xb") as handle:
            async for block in request.content.iter_chunked(1024 * 1024):
                total += len(block)
                if total > RECORDING_UPLOAD_MAX_BYTES:
                    raise web.HTTPRequestEntityTooLarge(
                        max_size=RECORDING_UPLOAD_MAX_BYTES, actual_size=total
                    )
                handle.write(block)
        if total == 0:
            raise web.HTTPBadRequest(text="RRD upload is empty")
        summary = await asyncio.to_thread(
            runtime.exchange.stage_import,
            path,
            expected_recording_epoch=expected_epoch,
            session_id=session_id,
        )
    except ExchangeError as exc:
        path.unlink(missing_ok=True)
        raise web.HTTPBadRequest(text=f"{exc.code}: {exc}") from exc
    except BaseException:
        path.unlink(missing_ok=True)
        raise
    return web.json_response(
        {
            "token": summary.token,
            "digest_sha256": summary.digest_sha256,
            "profile": summary.profile,
            "sample_count": summary.sample_count,
            "start_ns": summary.start_ns,
            "end_ns": summary.end_ns,
            "source_mode": summary.source_mode.value,
            "expires_in_seconds": summary.expires_in_seconds,
        }
    )


async def _recording_import_commit(request: web.Request) -> web.Response:
    runtime = request.app[RUNTIME_KEY]
    _require_capability(runtime, "recording")
    assert runtime.exchange is not None and runtime.terrain is not None
    session_id = _session_id(request)
    try:
        payload = await request.json()
        if not isinstance(payload, dict) or set(payload) != {
            "token",
            "expected_recording_epoch",
        }:
            raise ValueError("commit body has an invalid field set")
        token = payload["token"]
        expected_epoch = payload["expected_recording_epoch"]
        if not isinstance(token, str) or not isinstance(expected_epoch, str):
            raise ValueError("commit fields must be strings")
        future = runtime.exchange.commit_import(
            token, expected_recording_epoch=expected_epoch, session_id=session_id
        )
        result = await asyncio.wrap_future(future)
        runtime.terrain.sync_source(result.recording_epoch, result.source_mode)
    except (ValueError, ExchangeError, ReplayCommandError) as exc:
        code = (
            exc.code if isinstance(exc, (ExchangeError, ReplayCommandError)) else "invalid_request"
        )
        raise web.HTTPConflict(text=f"{code}: {exc}") from exc
    return web.json_response(
        {
            "recording_epoch": result.recording_epoch,
            "source_mode": result.source_mode.value,
            "playback_state": result.playback_state.value,
            "cursor_recording_time_ns": result.cursor_recording_time_ns,
            "view_revision": result.view_revision,
        }
    )


async def _recording_import_cancel(request: web.Request) -> web.Response:
    runtime = request.app[RUNTIME_KEY]
    _require_capability(runtime, "recording")
    assert runtime.exchange is not None
    session_id = _session_id(request)
    if not runtime.exchange.cancel(request.match_info["token"], session_id=session_id):
        raise web.HTTPNotFound(text="import token is missing or belongs to another session")
    return web.json_response({"cancelled": True})


def _terrain_http_error(error: TerrainCommandError) -> web.HTTPException:
    if error.code in {"invalid_terrain_preview", "terrain_snapshot_unavailable"}:
        return web.HTTPNotFound(
            text=f"{error.code}: {error}", content_type="application/problem+json"
        )
    return web.HTTPConflict(text=f"{error.code}: {error}", content_type="application/problem+json")


async def _terrain_preview(request: web.Request) -> web.Response:
    runtime = request.app[RUNTIME_KEY]
    _require_capability(runtime, "terrain")
    assert runtime.terrain is not None and runtime.replay is not None
    session_id = _session_id(request)
    try:
        payload = await request.json()
        if not isinstance(payload, dict) or set(payload) != {
            "expected_recording_epoch",
            "expected_terrain_epoch",
            "spec",
        }:
            raise ValueError("preview body has an invalid field set")
        recording_epoch = payload["expected_recording_epoch"]
        terrain_epoch = payload["expected_terrain_epoch"]
        if not isinstance(recording_epoch, str) or not isinstance(terrain_epoch, str):
            raise ValueError("preview epoch fields must be strings")
        current_view = runtime.replay.latest.read()
        runtime.terrain.sync_source(current_view.recording_epoch, current_view.source_mode)
        future = runtime.terrain.stage_preview(
            session_id,
            payload["spec"],
            expected_recording_epoch=recording_epoch,
            expected_terrain_epoch=terrain_epoch,
        )
        preview = await asyncio.wrap_future(future)
    except (ValueError, TerrainSpecError) as exc:
        raise web.HTTPBadRequest(
            text=f"invalid_terrain_spec: {exc}", content_type="application/problem+json"
        ) from exc
    except TerrainCommandError as exc:
        raise _terrain_http_error(exc) from exc
    return web.json_response(preview.public_metadata())


async def _terrain_preview_snapshot(request: web.Request) -> web.Response:
    runtime = request.app[RUNTIME_KEY]
    _require_capability(runtime, "terrain")
    assert runtime.terrain is not None
    session_id = _session_id(request)
    try:
        preview = runtime.terrain.preview(session_id, request.match_info["token"])
        payload = await asyncio.to_thread(terrain_snapshot_bytes, preview.baseline)
    except TerrainCommandError as exc:
        raise _terrain_http_error(exc) from exc
    return web.Response(
        body=payload,
        headers={
            "Content-Type": "application/vnd.godot-pinocchio.terrain-f32le",
            "Cache-Control": "no-store",
            "X-Terrain-Rows": str(preview.baseline.domain.rows),
            "X-Terrain-Columns": str(preview.baseline.domain.columns),
            "X-Terrain-SHA256": preview.baseline.snapshot_sha256,
            "X-Content-Type-Options": "nosniff",
        },
    )


async def _terrain_preview_cancel(request: web.Request) -> web.Response:
    runtime = request.app[RUNTIME_KEY]
    _require_capability(runtime, "terrain")
    assert runtime.terrain is not None
    session_id = _session_id(request)
    if not runtime.terrain.cancel_preview(session_id, request.match_info["token"]):
        raise web.HTTPNotFound(text="terrain preview is unavailable")
    return web.json_response({"cancelled": True})


async def _terrain_snapshot(request: web.Request) -> web.Response:
    runtime = request.app[RUNTIME_KEY]
    _require_capability(runtime, "terrain")
    assert runtime.terrain is not None
    _session_id(request)
    try:
        recording_epoch = request.query["recording_epoch"]
        terrain_epoch = request.query["terrain_epoch"]
        terrain_revision = int(request.query["terrain_revision"])
        request_id = request.query["request_id"]
        if not request_id or terrain_revision < 0:
            raise ValueError("snapshot identity is invalid")
        view, payload = await asyncio.to_thread(
            runtime.terrain.snapshot_for,
            recording_epoch,
            terrain_epoch,
            terrain_revision,
        )
    except (KeyError, ValueError) as exc:
        raise web.HTTPBadRequest(text=f"invalid_request: {exc}") from exc
    except TerrainCommandError as exc:
        raise _terrain_http_error(exc) from exc
    return web.Response(
        body=payload,
        headers={
            "Content-Type": "application/vnd.godot-pinocchio.terrain-f32le",
            "Cache-Control": "no-store",
            "X-Terrain-Recording-Epoch": view.recording_epoch,
            "X-Terrain-Epoch": view.terrain_epoch,
            "X-Terrain-Revision": str(view.terrain_revision),
            "X-Terrain-Rows": str(view.rows),
            "X-Terrain-Columns": str(view.columns),
            "X-Terrain-SHA256": view.snapshot_sha256,
            "X-Content-Type-Options": "nosniff",
        },
    )


def _origin_allowed(request: web.Request) -> bool:
    origin = request.headers.get("Origin")
    if origin is None:
        return request.app[ALLOW_MISSING_ORIGIN_KEY]
    own_origin = f"{request.scheme}://{request.host}"
    allowed = request.app[ALLOWED_ORIGINS_KEY]
    return origin == own_origin or origin in allowed


async def _websocket(request: web.Request) -> web.StreamResponse:
    if not _origin_allowed(request):
        raise web.HTTPForbidden(text="WebSocket origin is not allowed")
    manager = request.app[RUNTIME_KEY]
    runtime: RuntimeController | None = None
    session_id = uuid.uuid4().hex
    ws = web.WebSocketResponse(max_msg_size=64 * 1024, heartbeat=10.0, autoping=True)
    await ws.prepare(request)
    send_lock = asyncio.Lock()
    authority_lock = asyncio.Lock()

    async def send(message: dict[str, object]) -> None:
        encoded = encode_server_message(message)
        async with send_lock:
            if ws.closed:
                return
            try:
                await ws.send_str(encoded)
            except (ClientConnectionResetError, ConnectionResetError, RuntimeError):
                return

    sender_task: asyncio.Task[None] | None = None
    status_task: asyncio.Task[None] | None = None
    close_tasks: set[asyncio.Task[bool]] = set()
    violations = 0
    limiter = SlidingWindowRateLimiter()
    try:
        first = await asyncio.wait_for(ws.receive(), timeout=HELLO_TIMEOUT_SECONDS)
        if first.type is WSMsgType.BINARY:
            await send(
                error_message(
                    ProtocolError(
                        "binary_not_supported",
                        "binary messages are not supported",
                        recoverable=False,
                    )
                )
            )
            await ws.close(code=1003)
            return ws
        if first.type is not WSMsgType.TEXT:
            raise ProtocolError(
                "hello_required", "first WebSocket message must be a text hello", recoverable=False
            )
        hello = decode_client_message(cast(str, first.data))
        if not isinstance(hello, HelloMessage):
            raise ProtocolError(
                "hello_required", "first WebSocket message must be hello", recoverable=False
            )
        try:

            def session_is_closed() -> bool:
                transport = request.transport
                return ws.closed or transport is None or transport.is_closing()

            runtime = manager.acquire(
                session_id,
                hello.requested_model_id,
                session_is_closed=session_is_closed,
            )
        except ModelSelectionError as exc:
            await send(error_message(ProtocolError(exc.code, str(exc), recoverable=False)))
            await ws.close(code=1008, message=exc.code.encode("ascii", "replace"))
            return ws
        assert runtime is not None
        versions = load_version_manifest().for_model(
            model_version=manager.model_version,
            visual_model_version=manager.visual_model_version,
        )
        await send(
            {
                "type": "hello_ack",
                "session_id": session_id,
                "model_id": manager.model_id,
                "simulation_epoch": runtime.latest.read().stream_epoch,
                "recording_epoch": runtime.recording_epoch,
                "versions": versions.as_dict(),
                "model_url": "/api/model",
                "lifecycle": runtime.latest.read().lifecycle,
                "capabilities": sorted(set(hello.capabilities) & runtime.capabilities),
            }
        )
        sender_task = asyncio.create_task(
            _state_sender(runtime, ws, send, authority_lock), name=f"state-{session_id}"
        )
        status_task = asyncio.create_task(
            _status_sender(runtime, ws, send), name=f"status-{session_id}"
        )

        def close_failed_session(task: asyncio.Task[None]) -> None:
            if task.cancelled() or ws.closed:
                return
            if task.exception() is not None:
                close_task = asyncio.create_task(
                    ws.close(code=1011, message=b"session sender failed"),
                    name=f"close-{session_id}",
                )
                close_tasks.add(close_task)
                close_task.add_done_callback(close_tasks.discard)

        sender_task.add_done_callback(close_failed_session)
        status_task.add_done_callback(close_failed_session)

        async for ws_message in ws:
            if ws_message.type is WSMsgType.TEXT:
                try:
                    message = decode_client_message(cast(str, ws_message.data))
                    if isinstance(message, HelloMessage):
                        raise ProtocolError("duplicate_hello", "hello may only be sent once")
                    kind = (
                        "input_snapshot"
                        if isinstance(message, InputMessage)
                        else "command"
                        if isinstance(message, CommandMessage)
                        else "command"
                        if isinstance(message, PlaybackMessage)
                        else "terrain_command"
                        if isinstance(message, TerrainMessage)
                        else "ping"
                    )
                    if not limiter.allow(kind, time.monotonic()):
                        raise ProtocolError("rate_limited", f"{kind} rate limit exceeded")
                    if isinstance(message, InputMessage):
                        await _handle_input(runtime, session_id, message, send)
                    elif isinstance(message, CommandMessage):
                        try:
                            future = runtime.submit_command(session_id, message.id, message.command)
                        except RuntimeCommandError as exc:
                            raise ProtocolError(
                                exc.code,
                                str(exc),
                                request_id=message.id,
                            ) from exc
                        await _send_command_result(send, future, message.id)
                    elif isinstance(message, PlaybackMessage):
                        if "playback" not in runtime.capabilities:
                            raise ProtocolError(
                                "capability_unavailable",
                                "playback capability is unavailable",
                                request_id=message.id,
                            )
                        assert runtime.replay is not None
                        try:
                            playback = runtime.replay.submit(
                                message.id,
                                message.expected_recording_epoch,
                                message.action,
                                recording_time_ns=message.recording_time_ns,
                            )
                        except ReplayCommandError as exc:
                            raise ProtocolError(exc.code, str(exc), request_id=message.id) from exc
                        playback_applied = await _send_playback_result(send, playback, message.id)
                        if playback_applied is not None:
                            assert runtime.terrain is not None
                            runtime.terrain.sync_source(
                                playback_applied.recording_epoch, playback_applied.source_mode
                            )
                    elif isinstance(message, TerrainMessage):
                        if "terrain" not in runtime.capabilities:
                            raise ProtocolError(
                                "capability_unavailable",
                                "terrain capability is unavailable",
                                request_id=message.id,
                            )
                        assert runtime.replay is not None and runtime.terrain is not None
                        try:
                            async with authority_lock:
                                current_view = runtime.replay.latest.read()
                                runtime.terrain.sync_source(
                                    current_view.recording_epoch, current_view.source_mode
                                )
                                if message.action == "apply_preview":
                                    assert message.preview_token is not None
                                    terrain_applied = runtime.terrain.apply_preview(
                                        session_id,
                                        message.id,
                                        message.preview_token,
                                        expected_recording_epoch=message.expected_recording_epoch,
                                        expected_terrain_epoch=message.expected_terrain_epoch,
                                        selected_sample_sequence=current_view.selected_sample_sequence,
                                    )
                                else:
                                    terrain_applied = runtime.terrain.reset(
                                        message.id,
                                        expected_recording_epoch=message.expected_recording_epoch,
                                        expected_terrain_epoch=message.expected_terrain_epoch,
                                        selected_sample_sequence=current_view.selected_sample_sequence,
                                    )
                                await send(terrain_applied.as_message())
                                # A stopped runtime may not publish another replay revision. Emit
                                # the exact state/terrain pair used as the mutation boundary so the
                                # client can accept the new terrain view immediately.
                                await send(
                                    _state_message(
                                        current_view, current_view.view_revision, manager
                                    )
                                )
                                await send(
                                    runtime.terrain.view_for(
                                        current_view.recording_epoch,
                                        current_view.selected_sample_sequence,
                                        current_view.source_mode,
                                    ).as_message()
                                )
                        except TerrainCommandError as exc:
                            raise ProtocolError(exc.code, str(exc), request_id=message.id) from exc
                    elif isinstance(message, PingMessage):
                        await send(
                            {
                                "type": "pong",
                                "id": message.id,
                                "client_sent_ms": message.client_sent_ms,
                                "server_monotonic_ms": time.perf_counter() * 1000.0,
                            }
                        )
                except (ProtocolError, RuntimeCommandError, TerrainCommandError) as exc:
                    violations += 1
                    protocol_error = (
                        exc if isinstance(exc, ProtocolError) else ProtocolError(exc.code, str(exc))
                    )
                    await send(error_message(protocol_error))
                    if not protocol_error.recoverable or violations >= MAX_PROTOCOL_VIOLATIONS:
                        await ws.close(
                            code=1008, message=protocol_error.code.encode("ascii", "replace")
                        )
                        break
            elif ws_message.type is WSMsgType.BINARY:
                await send(
                    error_message(
                        ProtocolError(
                            "binary_not_supported",
                            "binary messages are not supported",
                            recoverable=False,
                        )
                    )
                )
                await ws.close(code=1003)
                break
            elif ws_message.type in {WSMsgType.ERROR, WSMsgType.CLOSE, WSMsgType.CLOSED}:
                break
    except (TimeoutError, ProtocolError) as exc:
        error = (
            ProtocolError("hello_timeout", "hello was not received in time", recoverable=False)
            if isinstance(exc, asyncio.TimeoutError)
            else exc
        )
        with contextlib.suppress(ConnectionResetError, RuntimeError):
            await send(error_message(error))
        await ws.close(code=1008)
    finally:
        for task in (sender_task, status_task):
            if task is not None:
                task.cancel()
        await asyncio.gather(
            *(task for task in (sender_task, status_task) if task is not None),
            return_exceptions=True,
        )
        if close_tasks:
            await asyncio.gather(*close_tasks, return_exceptions=True)
        if runtime is not None:
            runtime.disconnect_client(session_id)
            if runtime.exchange is not None:
                runtime.exchange.cancel_session(session_id)
        manager.release(session_id)
    return ws


async def _handle_input(
    runtime: RuntimeController,
    session_id: str,
    message: InputMessage,
    send: Callable[[dict[str, object]], Awaitable[None]],
) -> None:
    try:
        runtime.submit_input(
            session_id,
            client_sequence=message.client_sequence,
            connected=message.connected,
            focused=message.focused,
            axes=message.axes,
        )
    except InputRouterError as exc:
        await send(
            {
                "type": "input_ack",
                "client_sequence": message.client_sequence,
                "accepted": False,
                "error_code": exc.code,
            }
        )
    else:
        await send(
            {
                "type": "input_ack",
                "client_sequence": message.client_sequence,
                "accepted": True,
            }
        )


async def _state_sender(
    runtime: RuntimeController,
    ws: web.WebSocketResponse,
    send: Callable[[dict[str, object]], Awaitable[None]],
    authority_lock: asyncio.Lock,
) -> None:
    view_revision = 0
    emitted = 0
    interval = 1.0 / VIEW_POLL_HZ
    while not ws.closed:
        await asyncio.sleep(interval)
        async with authority_lock:
            view = runtime.latest_view.read()
            if view.view_revision <= view_revision:
                continue
            view_revision = view.view_revision
            if "terrain" not in runtime.capabilities:
                await send(_state_message(view, emitted, runtime))
                emitted += 1
                continue
            assert runtime.terrain is not None
            terrain_view = runtime.terrain.view_for(
                view.recording_epoch,
                view.selected_sample_sequence,
                view.source_mode,
            )
            await send(_state_message(view, emitted, runtime))
            await send(terrain_view.as_message())
            patch = runtime.terrain.patch_for(
                terrain_view.terrain_epoch, terrain_view.terrain_revision
            )
            if (
                patch is not None
                and patch.selected_sample_sequence <= view.selected_sample_sequence
            ):
                await send(patch.as_message(view.recording_epoch, terrain_view.terrain_epoch))
        emitted += 1


async def _status_sender(
    runtime: RuntimeController,
    ws: web.WebSocketResponse,
    send: Callable[[dict[str, object]], Awaitable[None]],
) -> None:
    while not ws.closed:
        await asyncio.sleep(1.0)
        await send(_status_message(runtime))
        if "recording" in runtime.capabilities:
            await send(_recording_status_message(runtime))


async def _static(request: web.Request) -> web.StreamResponse:
    root = request.app[FRONTEND_DIR_KEY]
    if not root.is_dir():
        raise web.HTTPServiceUnavailable(text="frontend build is unavailable; run pixi run build")
    relative = request.match_info.get("path", "")
    candidate = (root / relative).resolve() if relative else root / "index.html"
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise web.HTTPNotFound() from exc
    if candidate.is_file():
        return web.FileResponse(candidate)
    return web.FileResponse(root / "index.html")
