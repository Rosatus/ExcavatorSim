"""Build a self-contained gateway.exe with PyInstaller into dist/can_gateway/.

Usage: python tools/can_gateway/build_exe.py
Requires: uv tool run pyinstaller (or pip install pyinstaller in a venv).
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GW_DIR = ROOT / "tools" / "can_gateway"
DIST = ROOT / "dist" / "can_gateway"


def main() -> int:
    # Use the uv-managed PyInstaller (project avoids pip-installing into the
    # interpreter); fall back to an in-interpreter module if present.
    pyinstaller = ["uv", "tool", "run", "pyinstaller"]
    probe = subprocess.run(pyinstaller + ["--version"], capture_output=True, text=True)
    if probe.returncode != 0:
        pyinstaller = [sys.executable, "-m", "PyInstaller"]
    cmd = pyinstaller + [
        "--onefile",
        "--console",
        "--name", "gateway",
        "--distpath", str(DIST),
        "--workpath", str(ROOT / "build" / "pyinstaller"),
        "--specpath", str(ROOT / "build" / "pyinstaller"),
        "--paths", str(GW_DIR),
        str(GW_DIR / "gateway.py"),
    ]
    print(" ".join(cmd))
    result = subprocess.run(cmd, cwd=GW_DIR)
    if result.returncode != 0:
        return result.returncode
    print(f"\nbuilt: {DIST / 'gateway.exe'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
