"""Build a self-contained gateway.exe with PyInstaller into dist/can_gateway/.

Usage: python tools/can_gateway/build_exe.py
Requires: uv tool run pyinstaller (or pip install pyinstaller in a venv).
"""

from __future__ import annotations

import argparse
import hashlib
import subprocess
import sys
from collections.abc import Sequence
from pathlib import Path
from shutil import copy2, which

ROOT = Path(__file__).resolve().parents[2]
GW_DIR = ROOT / "tools" / "can_gateway"
DEFAULT_DIST = ROOT / "dist" / "can_gateway"
WEB_DIR = GW_DIR / "web"
WEB_OUTPUT = GW_DIR / "resources" / "web"


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def validate_web_bundle() -> bool:
    assets = WEB_OUTPUT / "assets"
    if not (WEB_OUTPUT / "index.html").is_file() or not any(assets.glob("index-*.js")):
        print("error: Gateway Web production bundle is missing", file=sys.stderr)
        return False
    return True


def build_web() -> bool:
    npm = which("npm.cmd") or which("npm")
    if npm is None:
        print("error: Node.js/npm is required on the build machine", file=sys.stderr)
        return False
    for command in ([npm, "ci"], [npm, "run", "build"]):
        if subprocess.run(command, cwd=WEB_DIR).returncode != 0:
            return False
    return validate_web_bundle()


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--skip-web-build",
        action="store_true",
        help="reuse the validated tools/can_gateway/resources/web bundle",
    )
    parser.add_argument(
        "--dist-dir",
        type=Path,
        default=DEFAULT_DIST,
        help="output directory (default: dist/can_gateway)",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    if not (validate_web_bundle() if args.skip_web_build else build_web()):
        return 1
    dist = args.dist_dir.resolve()
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
        str(dist),
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
    adjacent_dbc = dist / "dbc"
    adjacent_dbc.mkdir(parents=True, exist_ok=True)
    for source in sorted((GW_DIR / "resources" / "dbc").glob("*.dbc")):
        destination = adjacent_dbc / source.name
        # A running packaged gateway or scanner may hold an adjacent DBC open
        # on Windows. An already byte-identical file needs no replacement.
        if destination.is_file() and _sha256(source) == _sha256(destination):
            continue
        copy2(source, destination)
    print(f"\nbuilt: {dist / 'gateway.exe'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
