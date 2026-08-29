"""Loopback-only aiohttp boundary for the CAN Gateway runtime core."""

from __future__ import annotations

import asyncio
import json
import threading
import uuid
import zipfile
from pathlib import Path
from typing import Any

from aiohttp import WSMsgType, web
from gateway_runtime import GatewayRuntimeCore, GatewayRuntimeError

WEB_HOST = "127.0.0.1"
DEFAULT_WEB_PORT = 29_777
MAX_JSON_BYTES = 64 * 1024
COMMAND_TIMEOUT_S = 30.0
CORE_KEY = web.AppKey("gateway_core", GatewayRuntimeCore)


def _reject_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON number is not allowed: {value}")


async def _read_json_object(request: web.Request) -> dict[str, Any]:
    if request.content_type != "application/json":
        raise GatewayRuntimeError(
            "content_type_invalid", "application/json is required", status=415
        )
    if request.content_length is not None and request.content_length > MAX_JSON_BYTES:
        raise GatewayRuntimeError("request_too_large", "request exceeds 64 KiB", status=413)
    raw = await request.read()
    if len(raw) > MAX_JSON_BYTES:
        raise GatewayRuntimeError("request_too_large", "request exceeds 64 KiB", status=413)
    try:
        decoded = json.loads(raw.decode("utf-8"), parse_constant=_reject_constant)
    except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        raise GatewayRuntimeError("json_invalid", "request body is not strict JSON") from exc
    if not isinstance(decoded, dict):
        raise GatewayRuntimeError("json_object_required", "request body must be a JSON object")
    return decoded


def _error_response(error: GatewayRuntimeError, request_id: str = "") -> web.Response:
    return web.json_response(
        {
            "error": {
                "code": error.code,
                "message": str(error),
                "request_id": request_id,
                "recoverable": error.status < 500,
            }
        },
        status=error.status,
    )


class GatewayWebServer:
    def __init__(
        self,
        core: GatewayRuntimeCore,
        *,
        port: int = DEFAULT_WEB_PORT,
        static_root: Path | None = None,
    ) -> None:
        if not 1 <= port <= 65_535:
            raise ValueError("web port must be in 1..65535")
        self.core = core
        self.port = port
        self.static_root = static_root
        self.url = f"http://{WEB_HOST}:{port}"
        self._ready = threading.Event()
        self._startup_error: BaseException | None = None
        self._loop: asyncio.AbstractEventLoop | None = None
        self._runner: web.AppRunner | None = None
        self._thread = threading.Thread(target=self._thread_main, name="gateway-web")

    def start(self, timeout_s: float = 5.0) -> None:
        self._thread.start()
        if not self._ready.wait(timeout_s):
            self.close()
            raise RuntimeError("gateway Web server did not become ready")
        if self._startup_error is not None:
            self.close()
            raise RuntimeError(
                f"cannot listen Web console on {WEB_HOST}:{self.port}: {self._startup_error}"
            ) from self._startup_error
        self.core.publish(web_url=self.url)
        self.core.emit_event("web_ready", "web", url=self.url)

    def close(self) -> None:
        loop = self._loop
        if loop is not None and loop.is_running():
            loop.call_soon_threadsafe(loop.stop)
        if self._thread.is_alive():
            self._thread.join(timeout=3.0)

    def _thread_main(self) -> None:
        loop = asyncio.new_event_loop()
        self._loop = loop
        asyncio.set_event_loop(loop)
        try:
            app = self.create_app()
            self._runner = web.AppRunner(app, access_log=None)
            loop.run_until_complete(self._runner.setup())
            site = web.TCPSite(self._runner, WEB_HOST, self.port)
            loop.run_until_complete(site.start())
        except BaseException as exc:
            self._startup_error = exc
            try:
                if self._runner is not None:
                    loop.run_until_complete(self._runner.cleanup())
            finally:
                loop.close()
                self._ready.set()
            return
        self._ready.set()
        try:
            loop.run_forever()
        finally:
            if self._runner is not None:
                loop.run_until_complete(self._runner.cleanup())
            pending = asyncio.all_tasks(loop)
            for task in pending:
                task.cancel()
            if pending:
                loop.run_until_complete(asyncio.gather(*pending, return_exceptions=True))
            loop.close()

    def create_app(self) -> web.Application:
        app = web.Application(client_max_size=MAX_JSON_BYTES)
        app[CORE_KEY] = self.core
        app.middlewares.append(self._error_middleware)
        app.router.add_get("/api/v1/status", self._status)
        app.router.add_get("/api/v1/events", self._events)
        app.router.add_get("/api/v1/logs/current", self._current_log)
        app.router.add_get("/api/v1/logs/archive", self._archive_logs)
        app.router.add_get("/api/v1/dbc", self._dbc_catalog)
        app.router.add_put("/api/v1/dbc/messages/{message_key}", self._dbc_message)
        app.router.add_post("/api/v1/dbc/messages/{message_key}/preview", self._dbc_message_preview)
        app.router.add_post("/api/v1/dbc/start", self._dbc_start)
        app.router.add_post("/api/v1/dbc/stop", self._dbc_stop)
        app.router.add_post("/api/v1/dbc/reload", self._dbc_reload)
        app.router.add_put("/api/v1/transport/tcp", self._tcp_transport)
        app.router.add_post("/api/v1/transport/can0/restart", self._restart_can0)
        app.router.add_get("/", self._static)
        app.router.add_get("/{path:.*}", self._static)
        return app

    @web.middleware
    async def _error_middleware(self, request: web.Request, handler):
        try:
            return await handler(request)
        except GatewayRuntimeError as exc:
            return _error_response(exc, request.headers.get("X-Request-ID", ""))
        except web.HTTPException:
            raise
        except Exception:
            return _error_response(
                GatewayRuntimeError("internal_error", "internal Gateway Web error", status=500),
                request.headers.get("X-Request-ID", ""),
            )

    async def _status(self, _request: web.Request) -> web.Response:
        return web.json_response({"status": self.core.snapshot().to_dict()})

    async def _events(self, request: web.Request) -> web.StreamResponse:
        origin = request.headers.get("Origin")
        if origin is not None and origin.rstrip("/") != self.url:
            raise GatewayRuntimeError(
                "origin_forbidden", "WebSocket origin is not local console", status=403
            )
        try:
            after = int(request.query.get("after", "0"), 10)
        except ValueError as exc:
            raise GatewayRuntimeError("sequence_invalid", "after must be an integer") from exc
        if after < 0:
            raise GatewayRuntimeError("sequence_invalid", "after must be non-negative")
        ws = web.WebSocketResponse(max_msg_size=MAX_JSON_BYTES, heartbeat=10.0, autoping=True)
        await ws.prepare(request)
        try:
            while not ws.closed:
                events, gap = await asyncio.to_thread(self.core.events.wait_after, after, 1.0)
                if gap:
                    await ws.send_json(
                        {
                            "type": "gap",
                            "requested_after": after,
                            "earliest_sequence": self.core.events.earliest_sequence,
                        }
                    )
                for event in events:
                    await ws.send_json({"type": "event", "event": event.to_dict()})
                    after = event.sequence
                try:
                    message = await asyncio.wait_for(ws.receive(), timeout=0.01)
                except TimeoutError:
                    continue
                if message.type in (WSMsgType.CLOSE, WSMsgType.CLOSED, WSMsgType.ERROR):
                    break
        finally:
            await ws.close()
        return ws

    async def _current_log(self, _request: web.Request) -> web.StreamResponse:
        path = self.core.events.current_path
        if not path.is_file():
            raise GatewayRuntimeError("log_unavailable", "current log is not available", status=404)
        return web.FileResponse(
            path, headers={"Content-Disposition": 'attachment; filename="gateway.jsonl"'}
        )

    async def _archive_logs(self, _request: web.Request) -> web.StreamResponse:
        paths = self.core.events.retained_paths()
        if not paths:
            raise GatewayRuntimeError(
                "log_unavailable", "retained logs are not available", status=404
            )
        archive_path = await asyncio.to_thread(self._build_archive, paths)
        return web.FileResponse(
            archive_path,
            headers={"Content-Disposition": 'attachment; filename="gateway-logs.zip"'},
        )

    async def _dbc_catalog(self, _request: web.Request) -> web.Response:
        status, dbc = self.core.web_snapshot()
        return web.json_response({"status": status.to_dict(), "dbc": dbc})

    async def _dbc_message(self, request: web.Request) -> web.Response:
        self._require_standalone()
        body = await _read_json_object(request)
        self._require_fields(
            body,
            {"values", "payload_hex", "enabled", "frequency_hz", "expected_revision", "request_id"},
        )
        if "values" in body and "payload_hex" in body:
            raise GatewayRuntimeError(
                "dbc_edit_source_conflict", "provide values or payload_hex, not both"
            )
        if "values" in body and not isinstance(body["values"], dict):
            raise GatewayRuntimeError("dbc_values_invalid", "values must be an object")
        if "payload_hex" in body and not isinstance(body["payload_hex"], str):
            raise GatewayRuntimeError("dbc_payload_invalid", "payload_hex must be a string")
        payload: dict[str, Any] = {"message_key": request.match_info["message_key"]}
        for field in ("values", "payload_hex", "enabled", "frequency_hz"):
            if field in body:
                payload[field] = body[field]
        return await self._submit(request, "dbc_message_update", payload, body)

    async def _dbc_message_preview(self, request: web.Request) -> web.Response:
        self._require_standalone()
        body = await _read_json_object(request)
        self._require_fields(body, {"values", "payload_hex", "expected_revision", "request_id"})
        has_values = "values" in body
        has_payload = "payload_hex" in body
        if has_values == has_payload:
            raise GatewayRuntimeError(
                "dbc_edit_source_invalid", "provide exactly one of values or payload_hex"
            )
        if has_values and not isinstance(body["values"], dict):
            raise GatewayRuntimeError("dbc_values_invalid", "values must be an object")
        if has_payload and not isinstance(body["payload_hex"], str):
            raise GatewayRuntimeError("dbc_payload_invalid", "payload_hex must be a string")
        payload: dict[str, Any] = {"message_key": request.match_info["message_key"]}
        payload["values" if has_values else "payload_hex"] = body[
            "values" if has_values else "payload_hex"
        ]
        return await self._submit(
            request, "dbc_message_preview", payload, body, require_revision=False
        )

    async def _dbc_start(self, request: web.Request) -> web.Response:
        self._require_standalone()
        body = await _read_json_object(request)
        return await self._submit(request, "dbc_start", {}, body)

    async def _dbc_stop(self, request: web.Request) -> web.Response:
        self._require_standalone()
        body = await _read_json_object(request)
        return await self._submit(request, "dbc_stop", {}, body)

    async def _dbc_reload(self, request: web.Request) -> web.Response:
        self._require_standalone()
        body = await _read_json_object(request)
        return await self._submit(request, "dbc_reload", {}, body)

    def _build_archive(self, paths: list[Path]) -> Path:
        archive_path = self.core.events.directory / "gateway-logs-export.zip"
        temporary = archive_path.with_suffix(".zip.tmp")
        with zipfile.ZipFile(temporary, "w", compression=zipfile.ZIP_DEFLATED) as archive:
            for path in paths:
                archive.write(path, arcname=path.name)
        temporary.replace(archive_path)
        return archive_path

    async def _tcp_transport(self, request: web.Request) -> web.Response:
        self._require_mutation("windows")
        body = await _read_json_object(request)
        host = body.get("host")
        port = body.get("port")
        if not isinstance(host, str):
            raise GatewayRuntimeError("tcp_host_invalid", "host must be a string")
        if not isinstance(port, int) or isinstance(port, bool) or not 1 <= port <= 65_535:
            raise GatewayRuntimeError("tcp_port_invalid", "port must be an integer in 1..65535")
        return await self._submit(request, "tcp_rebind", {"host": host, "port": port}, body)

    async def _restart_can0(self, request: web.Request) -> web.Response:
        self._require_mutation("linux")
        body = await _read_json_object(request)
        if body.get("confirm") is not True:
            raise GatewayRuntimeError("confirmation_required", "can0 restart requires confirm=true")
        return await self._submit(request, "can0_restart", {"confirm": True}, body)

    def _require_mutation(self, platform: str) -> None:
        self._require_standalone()
        if self.core.platform != platform:
            raise GatewayRuntimeError(
                "capability_unavailable",
                f"transport control is unavailable on {self.core.platform}",
                status=409,
            )

    def _require_standalone(self) -> None:
        if self.core.mode != "standalone":
            raise GatewayRuntimeError(
                "managed_mode_read_only", "Godot-managed Gateway Web API is read-only", status=403
            )

    @staticmethod
    def _require_fields(body: dict[str, Any], allowed: set[str]) -> None:
        unknown = sorted(set(body) - allowed)
        if unknown:
            raise GatewayRuntimeError(
                "request_field_unknown", f"unknown request field {unknown[0]!r}"
            )

    async def _submit(
        self,
        request: web.Request,
        kind: str,
        payload: dict[str, Any],
        body: dict[str, Any],
        *,
        require_revision: bool = True,
    ) -> web.Response:
        if require_revision:
            revision = body.get("expected_revision")
            if not isinstance(revision, int) or isinstance(revision, bool) or revision < 0:
                raise GatewayRuntimeError(
                    "revision_invalid", "expected_revision must be a non-negative integer"
                )
        else:
            revision = self.core.snapshot().revision
        request_id = body.get("request_id", request.headers.get("X-Request-ID"))
        if request_id is None:
            request_id = uuid.uuid4().hex
        if not isinstance(request_id, str) or not request_id.strip() or len(request_id) > 128:
            raise GatewayRuntimeError("request_id_invalid", "request_id must be 1..128 characters")
        future = self.core.submit(
            kind=kind,
            payload=payload,
            expected_revision=revision,
            request_id=request_id,
        )
        try:
            result = await asyncio.wait_for(asyncio.wrap_future(future), timeout=COMMAND_TIMEOUT_S)
        except TimeoutError as exc:
            raise GatewayRuntimeError(
                "command_timeout", "Gateway owner loop did not finish the command", status=504
            ) from exc
        return web.json_response({"request_id": request_id, "result": result})

    async def _static(self, request: web.Request) -> web.StreamResponse:
        root = self.static_root
        if root is not None and root.is_dir():
            relative = request.match_info.get("path", "") or "index.html"
            candidate = (root / relative).resolve()
            resolved_root = root.resolve()
            try:
                candidate.relative_to(resolved_root)
            except ValueError as exc:
                raise web.HTTPNotFound() from exc
            if candidate.is_file():
                return web.FileResponse(candidate)
            index = resolved_root / "index.html"
            if index.is_file():
                return web.FileResponse(index)
        status = self.core.snapshot()
        return web.Response(
            text=(
                "<!doctype html><meta charset='utf-8'><title>CAN Gateway</title>"
                f"<h1>CAN Gateway</h1><p>mode={status.mode}</p>"
                "<p>The production console bundle has not been built yet.</p>"
            ),
            content_type="text/html",
        )
