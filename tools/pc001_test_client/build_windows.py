"""Build the independent Windows PC001 test-client package and zip archive.

Run from this directory with:
    uv run --python 3.12 --group dev python build_windows.py
"""

from __future__ import annotations

import json
import os
import platform
import shutil
import socket
import struct
import subprocess
import sys
import time
from importlib.metadata import version
from pathlib import Path

TOOL_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOL_DIR.parents[1]
DIST_ROOT = REPO_ROOT / "dist" / "pc001_test_client"
PACKAGE_DIR = DIST_ROOT / "PC001TestClient"
ARCHIVE_BASE = DIST_ROOT / "PC001TestClient-windows-x86_64"
WORK_DIR = REPO_ROOT / "build" / "pc001-test-client"

sys.path.insert(0, str(REPO_ROOT / "tools"))
from build_manifest import create_manifest  # noqa: E402


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    data = bytearray()
    while len(data) < size:
        chunk = sock.recv(size - len(data))
        if not chunk:
            raise RuntimeError("packaged client closed during smoke handshake")
        data.extend(chunk)
    return bytes(data)


def _write_build_info() -> None:
    payload = {
        "schema_version": 1,
        "python": platform.python_version(),
        "pyside6": version("PySide6"),
        "pyinstaller": version("PyInstaller"),
        "platform": platform.platform(),
    }
    (PACKAGE_DIR / "build-info.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def _smoke_packaged_client(executable: Path) -> None:
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", 0))
    server.listen(1)
    server.settimeout(0.1)
    port = int(server.getsockname()[1])
    trace_path = DIST_ROOT / ".pc001-smoke-trace.json"
    trace_path.unlink(missing_ok=True)
    process = subprocess.Popen(
        [
            str(executable),
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--smoke-connect",
        ],
        env={
            **os.environ,
            "EXCAVATORSIM_PC001_SMOKE_HOST": "127.0.0.1",
            "EXCAVATORSIM_PC001_SMOKE_PORT": str(port),
            "EXCAVATORSIM_PC001_SMOKE_TRACE": str(trace_path),
        },
    )
    client: socket.socket | None = None
    try:
        deadline = time.monotonic() + 8.0
        while client is None:
            if process.poll() is not None:
                raise RuntimeError(
                    f"packaged client exited before handshake with code {process.returncode}"
                )
            if time.monotonic() >= deadline:
                trace = (
                    trace_path.read_text(encoding="utf-8")
                    if trace_path.is_file()
                    else "missing"
                )
                raise RuntimeError(
                    f"packaged client did not connect before its deadline; trace={trace}"
                )
            try:
                client, _address = server.accept()
            except TimeoutError:
                continue
        client.settimeout(3.0)
        client.sendall(b"w")
        client.sendall(b"ho")
        if _recv_exact(client, 5) != b"PC001":
            raise RuntimeError("packaged client returned an invalid PC001 identity")
        payload = b"\x01\x02\x03\x04"
        frame = struct.pack(
            "<IBBBB8s",
            0x80000000 | 0x18FFF100,
            len(payload),
            0,
            0,
            0,
            payload.ljust(8, b"\0"),
        ) + struct.pack("<i", 3)
        client.sendall(struct.pack("<H", 1) + frame)
        if process.wait(timeout=5.0) != 0:
            raise RuntimeError(f"packaged client smoke failed with code {process.returncode}")
    finally:
        if client is not None:
            client.close()
        server.close()
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3.0)
        trace_path.unlink(missing_ok=True)


def _smoke_packaged_gui(executable: Path) -> None:
    startup_info: subprocess.STARTUPINFO | None = None
    creation_flags = 0
    if sys.platform == "win32":
        startup_info = subprocess.STARTUPINFO()
        startup_info.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        startup_info.wShowWindow = subprocess.SW_HIDE
        creation_flags = subprocess.CREATE_NO_WINDOW
    process = subprocess.Popen(
        [str(executable)],
        startupinfo=startup_info,
        creationflags=creation_flags,
    )
    try:
        time.sleep(1.0)
        if process.poll() is not None:
            raise RuntimeError(f"packaged GUI exited early with code {process.returncode}")
    finally:
        if process.poll() is None:
            process.terminate()
        try:
            process.wait(timeout=3.0)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=3.0)


def main() -> int:
    command = [
        sys.executable,
        "-m",
        "PyInstaller",
        "--noconfirm",
        "--clean",
        "--onedir",
        "--windowed",
        "--name",
        "PC001TestClient",
        "--distpath",
        str(DIST_ROOT),
        "--workpath",
        str(WORK_DIR),
        "--specpath",
        str(WORK_DIR),
        "--paths",
        str(TOOL_DIR),
        str(TOOL_DIR / "launch.py"),
    ]
    print(" ".join(command))
    result = subprocess.run(command, cwd=TOOL_DIR, check=False)
    if result.returncode != 0:
        return result.returncode

    executable = PACKAGE_DIR / "PC001TestClient.exe"
    if not executable.is_file():
        print(f"error: expected executable is missing: {executable}", file=sys.stderr)
        return 1

    _write_build_info()
    _smoke_packaged_client(executable)
    _smoke_packaged_gui(executable)
    manifest = PACKAGE_DIR / "build-manifest.json"
    create_manifest(
        manifest,
        [("pc001-test-client-windows", PACKAGE_DIR)],
        repo_root=REPO_ROOT,
    )
    archive_path = ARCHIVE_BASE.with_suffix(".zip")
    archive_path.unlink(missing_ok=True)
    built_archive = Path(
        shutil.make_archive(
            str(ARCHIVE_BASE),
            "zip",
            root_dir=DIST_ROOT,
            base_dir=PACKAGE_DIR.name,
        )
    )
    print(f"built: {executable}")
    print(f"archive: {built_archive}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
