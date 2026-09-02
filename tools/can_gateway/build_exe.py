"""Build a self-contained gateway.exe with PyInstaller into dist/can_gateway/.

Usage: python tools/can_gateway/build_exe.py
Requires: uv tool run pyinstaller (or pip install pyinstaller in a venv).
"""

from __future__ import annotations

import hashlib
import subprocess
import sys
from pathlib import Path
from shutil import copy2, which

ROOT = Path(__file__).resolve().parents[2]
GW_DIR = ROOT / "tools" / "can_gateway"
DIST = ROOT / "dist" / "can_gateway"
WEB_DIR = GW_DIR / "web"
WEB_OUTPUT = GW_DIR / "resources" / "web"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_web() -> bool:
    npm = which("npm.cmd") or which("npm")
    if npm is None:
        print("error: Node.js/npm is required on the build machine", file=sys.stderr)
        return False
    for command in ([npm, "ci"], [npm, "run", "build"]):
        if subprocess.run(command, cwd=WEB_DIR).returncode != 0:
            return False
    assets = WEB_OUTPUT / "assets"
    if not (WEB_OUTPUT / "index.html").is_file() or not any(assets.glob("index-*.js")):
        print("error: Gateway Web production bundle is missing", file=sys.stderr)
        return False
    return True


def main() -> int:
    if not build_web():
        return 1
    # Use the uv-managed PyInstaller (project avoids pip-installing into the
    # interpreter); fall back to an in-interpreter module if present.
    pyinstaller = [
        "uv",
        "tool",
        "run",
        "--from",
        "pyinstaller",
        "--with",
        "aiohttp",
        "--with",
        "cantools>=40,<41",
        "--with",
        "platformdirs",
        "pyinstaller",
    ]
    probe = subprocess.run([*pyinstaller, "--version"], capture_output=True, text=True)
    if probe.returncode != 0:
        pyinstaller = [sys.executable, "-m", "PyInstaller"]
    cmd = [
        *pyinstaller,
        "--onefile",
        "--console",
        "--name",
        "gateway",
        "--distpath",
        str(DIST),
        "--workpath",
        str(ROOT / "build" / "pyinstaller"),
        "--specpath",
        str(ROOT / "build" / "pyinstaller"),
        "--paths",
        str(GW_DIR),
        "--add-data",
        f"{GW_DIR / 'resources'};resources",
        "--collect-all",
        "cantools",
        str(GW_DIR / "gateway.py"),
    ]
    print(" ".join(cmd))
    result = subprocess.run(cmd, cwd=GW_DIR)
    if result.returncode != 0:
        return result.returncode
    adjacent_dbc = DIST / "dbc"
    adjacent_dbc.mkdir(parents=True, exist_ok=True)
    for source in sorted((GW_DIR / "resources" / "dbc").glob("*.dbc")):
        destination = adjacent_dbc / source.name
        # A running packaged gateway or scanner may hold an adjacent DBC open
        # on Windows. An already byte-identical file needs no replacement.
        if destination.is_file() and _sha256(source) == _sha256(destination):
            continue
        copy2(source, destination)
    print(f"\nbuilt: {DIST / 'gateway.exe'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
