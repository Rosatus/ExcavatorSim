"""Start the production CLI and probe HTTP plus WebSocket readiness."""

from __future__ import annotations

import asyncio
import hashlib
import json
import socket
import subprocess
import sys
import time
from pathlib import Path

from aiohttp import ClientSession, ClientTimeout

ROOT = Path(__file__).resolve().parents[2]


def _available_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind(("127.0.0.1", 0))
        return int(listener.getsockname()[1])


async def _probe(port: int, process: subprocess.Popen[str]) -> None:
    base_url = f"http://127.0.0.1:{port}"
    deadline = time.monotonic() + 20.0
    timeout = ClientTimeout(total=3.0)
    async with ClientSession(timeout=timeout) as session:
        while True:
            if process.poll() is not None:
                raise RuntimeError(f"production server exited early with code {process.returncode}")
            try:
                async with session.get(f"{base_url}/health") as response:
                    payload = await response.json()
                    if response.status == 200 and payload.get("status") == "ok":
                        break
            except OSError:
                pass
            if time.monotonic() >= deadline:
                raise TimeoutError("production server did not become healthy within 20 seconds")
            await asyncio.sleep(0.1)

        async with session.get(f"{base_url}/") as response:
            text = await response.text()
            if response.status != 200 or "Godot client is not implemented" not in text:
                raise RuntimeError("backend placeholder frontend probe failed")
        async with session.get(f"{base_url}/api/model") as response:
            text = await response.text()
            if response.status != 200 or "<robot" not in text:
                raise RuntimeError("production URDF probe failed")
        async with session.get(f"{base_url}/api/visual-model") as response:
            visual_model = await response.json()
            if (
                response.status != 200
                or visual_model.get("visual_model_version") != "original-skin-v1"
                or len(visual_model.get("entries", [])) != 5
            ):
                raise RuntimeError("production visual model manifest probe failed")
            asset_url = visual_model["entries"][0].get("url")
            if not isinstance(asset_url, str):
                raise RuntimeError("production visual model has no asset URL")
        async with session.get(f"{base_url}{asset_url}") as response:
            if (
                response.status != 200
                or response.headers.get("Content-Type") != "model/gltf-binary"
                or (await response.read())[:4] != b"glTF"
            ):
                raise RuntimeError("production GLB asset probe failed")
        async with session.ws_connect(f"{base_url}/ws", origin=base_url) as websocket:
            await websocket.send_json(
                {
                    "type": "hello",
                    "protocol_version": "godot-pinocchio-v3",
                    "capabilities": [
                        "input_snapshot",
                        "commands",
                        "latency",
                        "playback",
                        "recording",
                        "terrain",
                    ],
                }
            )
            first = await websocket.receive_str(timeout=3.0)
            message = json.loads(first)
            protocol_version = message.get("versions", {}).get("protocol_version")
            if message.get("type") != "hello_ack" or protocol_version != "godot-pinocchio-v3":
                raise RuntimeError(f"unexpected WebSocket handshake response: {message}")
            session_id = message.get("session_id")
            if not isinstance(session_id, str):
                raise RuntimeError("WebSocket handshake did not provide a session id")
            view_state: dict[str, object] | None = None
            terrain_view: dict[str, object] | None = None
            deadline = time.monotonic() + 3.0
            while view_state is None or terrain_view is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise TimeoutError("production server did not emit aligned terrain state")
                candidate = json.loads(await websocket.receive_str(timeout=remaining))
                if candidate.get("type") == "view_state":
                    view_state = candidate
                elif candidate.get("type") == "terrain_view":
                    terrain_view = candidate
            if (
                terrain_view.get("recording_epoch") != view_state.get("recording_epoch")
                or terrain_view.get("selected_sample_sequence")
                != view_state.get("selected_sample_sequence")
            ):
                raise RuntimeError("production terrain view is not aligned to motion state")
            terrain_recording_epoch = terrain_view.get("recording_epoch")
            terrain_epoch = terrain_view.get("terrain_epoch")
            terrain_revision = terrain_view.get("terrain_revision")
            rows = terrain_view.get("rows")
            columns = terrain_view.get("columns")
            snapshot_sha256 = terrain_view.get("snapshot_sha256")
            if (
                not isinstance(terrain_recording_epoch, str)
                or not isinstance(terrain_epoch, str)
                or not isinstance(terrain_revision, int)
                or not isinstance(rows, int)
                or not isinstance(columns, int)
                or not isinstance(snapshot_sha256, str)
            ):
                raise RuntimeError("production terrain view metadata is invalid")
            query: dict[str, str | int] = {
                "recording_epoch": terrain_recording_epoch,
                "terrain_epoch": terrain_epoch,
                "terrain_revision": terrain_revision,
                "request_id": "production-smoke",
            }
            async with session.get(
                f"{base_url}/api/terrain/snapshot",
                params=query,
                headers={"X-Godot-Pinocchio-Session": session_id},
            ) as response:
                snapshot = await response.read()
                if (
                    response.status != 200
                    or response.headers.get("Content-Type")
                    != "application/vnd.godot-pinocchio.terrain-f32le"
                    or len(snapshot) != rows * columns * 4
                    or hashlib.sha256(snapshot).hexdigest() != snapshot_sha256
                ):
                    raise RuntimeError("production terrain snapshot probe failed")


def main() -> int:
    port = _available_port()
    process = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "babylon_sim.cli",
            "--no-browser",
            "--port",
            str(port),
        ],
        cwd=ROOT,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
    )
    try:
        asyncio.run(_probe(port, process))
        print(
            "Backend smoke passed: health, placeholder frontend, URDF, visual GLB, "
            "WebSocket handshake, and authoritative terrain snapshot."
        )
        return 0
    finally:
        process.terminate()
        try:
            process.wait(timeout=5.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5.0)
        if process.returncode not in {0, 1} and process.stdout is not None:
            output = process.stdout.read().strip()
            if output:
                print(output, file=sys.stderr)


if __name__ == "__main__":
    raise SystemExit(main())
