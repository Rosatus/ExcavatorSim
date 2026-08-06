"""Production launcher for the standalone BabylonSim application."""

from __future__ import annotations

import argparse
import ipaddress
import threading
import time
import urllib.error
import urllib.request
import webbrowser
from pathlib import Path

from aiohttp import web

from .calibration import MachineCalibration
from .model import ExcavatorModel
from .paths import CALIBRATION_PATH, FRONTEND_DIST_PATH, URDF_PATH
from .runtime import RuntimeController
from .web import create_app


def _loopback_host(value: str) -> str:
    if value == "localhost":
        return value
    try:
        address = ipaddress.ip_address(value)
    except ValueError as exc:
        raise argparse.ArgumentTypeError("host must be a loopback address") from exc
    if not address.is_loopback:
        raise argparse.ArgumentTypeError("BabylonSim MVP only binds to loopback")
    return value


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Run the standalone BabylonSim service")
    parser.add_argument("--host", type=_loopback_host, default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--frontend-dir", type=Path, default=FRONTEND_DIST_PATH)
    return parser


def _open_browser_when_ready(url: str) -> None:
    health_url = f"{url.rstrip('/')}/health"
    deadline = time.monotonic() + 20.0
    while time.monotonic() < deadline:
        try:
            with urllib.request.urlopen(health_url, timeout=0.5) as response:
                if response.status == 200:
                    webbrowser.open(url)
                    return
        except (OSError, urllib.error.URLError):
            pass
        time.sleep(0.1)


def _application_url(host: str, port: int) -> str:
    url_host = f"[{host}]" if ":" in host else host
    return f"http://{url_host}:{port}/"


def main() -> int:
    args = build_parser().parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be between 1 and 65535")
    frontend_dir = args.frontend_dir.resolve()
    if not (frontend_dir / "index.html").is_file():
        raise SystemExit("frontend build is missing; run 'pixi run build' first")
    model = ExcavatorModel.from_urdf(URDF_PATH)
    calibration = MachineCalibration.from_json(CALIBRATION_PATH)
    runtime = RuntimeController(model, calibration)
    application = create_app(runtime, frontend_dir=frontend_dir)
    url = _application_url(args.host, args.port)
    if not args.no_browser:
        opener = threading.Thread(
            target=_open_browser_when_ready,
            args=(url,),
            name="babylon-sim-browser-opener",
            daemon=True,
        )
        opener.start()
    web.run_app(application, host=args.host, port=args.port, print=lambda message: print(message))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
