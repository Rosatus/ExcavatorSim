"""Exercise frozen Gateway Web assets, DBCs, and editable startup calibrations."""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Sequence
from pathlib import Path
from typing import cast


def free_port(*, udp: bool = False) -> int:
    kind = socket.SOCK_DGRAM if udp else socket.SOCK_STREAM
    with socket.socket(socket.AF_INET, kind) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def read_url(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=3.0) as response:
        if response.status != 200:
            raise RuntimeError(f"unexpected HTTP {response.status} for {url}")
        return cast(bytes, response.read())


def wait_for_json(url: str, process: subprocess.Popen[bytes]) -> dict[str, object]:
    deadline = time.monotonic() + 12.0
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise RuntimeError(f"frozen Gateway exited early with code {process.returncode}")
        try:
            payload = json.loads(read_url(url))
            if not isinstance(payload, dict):
                raise RuntimeError(f"expected a JSON object from {url}")
            return cast(dict[str, object], payload)
        except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
            last_error = exc
            time.sleep(0.1)
    raise RuntimeError(f"Gateway Web API did not become ready: {last_error}")


def terminate(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        return
    if os.name == "nt":
        subprocess.run(
            ["taskkill", "/PID", str(process.pid), "/T", "/F"],
            capture_output=True,
            check=False,
        )
    else:
        process.terminate()
    try:
        process.wait(timeout=5.0)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait(timeout=5.0)


def verify_calibration_restart(executable: Path, temp: Path, environment: dict[str, str]) -> None:
    package = temp / "package"
    package.mkdir()
    copied_executable = package / executable.name
    shutil.copy2(executable, copied_executable)
    shutil.copytree(executable.parent / "config", package / "config")
    for model in ("sy135", "sy80u", "sy155w"):
        calibration = package / "config" / f"calibration_{model}.toml"
        payloads = []
        for attempt in range(2):
            if attempt:
                original = calibration.read_text(encoding="utf-8-sig")
                changed, count = re.subn(
                    r"(?m)^(\s*pitch_boom\s*=\s*)([-+\d.eE]+)",
                    lambda match: f"{match[1]}{float(match[2]) + 1.0}",
                    original,
                )
                if count != 1:
                    raise RuntimeError(f"expected one pitch_boom in {calibration}")
                calibration.write_text(changed, encoding="utf-8-sig")
            output = temp / f"{model}-{attempt}"
            process = subprocess.Popen(
                [
                    str(copied_executable),
                    "--model",
                    model,
                    "--sink",
                    "csv",
                    "--max-rows",
                    "1",
                    "--port",
                    str(free_port(udp=True)),
                    "--out",
                    str(output),
                ],
                cwd=temp,
                env=environment,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )
            try:
                logs, _ = process.communicate(timeout=40)
                if process.returncode != 0:
                    raise RuntimeError(f"calibration smoke failed: {logs.decode(errors='replace')}")
            finally:
                terminate(process)
            with (output / "can_telemetry_smoke.csv").open(encoding="utf-8-sig") as handle:
                rows = list(csv.reader(handle))[1:]
            payloads.append(
                next(
                    row[9]
                    for row in rows
                    if int(row[5], 16) == (0x18F10000 if model == "sy155w" else 0x18FF3B00)
                )
            )
        if payloads[0] == payloads[1]:
            raise RuntimeError(f"{model}: edited calibration did not change the emitted boom frame")


def run_smoke(executable: Path) -> None:
    executable = executable.resolve()
    if not executable.is_file():
        raise FileNotFoundError(f"frozen Gateway is missing: {executable}")
    dbc_files = sorted((executable.parent / "dbc").glob("*.dbc"))
    if len(dbc_files) < 2:
        raise RuntimeError("adjacent Gateway DBC directory is incomplete")
    for model in ("sy135", "sy80u", "sy155w"):
        calibration = executable.parent / "config" / f"calibration_{model}.toml"
        if not calibration.is_file():
            raise RuntimeError(f"adjacent Gateway calibration is missing: {calibration}")

    with tempfile.TemporaryDirectory(prefix="gateway-frozen-smoke-") as temp_dir:
        temp = Path(temp_dir)
        environment = dict(os.environ)
        environment.update(
            {
                "LOCALAPPDATA": str(temp / "local"),
                "XDG_CONFIG_HOME": str(temp / "config"),
                "XDG_STATE_HOME": str(temp / "state"),
            }
        )
        web_port = free_port()
        process = subprocess.Popen(
            [
                str(executable),
                "--mode",
                "standalone",
                "--sink",
                "tcp",
                "--host",
                "127.0.0.1",
                "--port",
                str(free_port(udp=True)),
                "--ack-port",
                str(free_port(udp=True)),
                "--tcp-host",
                "127.0.0.1",
                "--tcp-port",
                str(free_port()),
                "--web-port",
                str(web_port),
                "--out",
                str(temp / "output"),
            ],
            cwd=temp,
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        base_url = f"http://127.0.0.1:{web_port}"
        try:
            status = wait_for_json(f"{base_url}/api/v1/status", process)
            if not isinstance(status.get("status"), dict):
                raise RuntimeError("Gateway status API returned an invalid envelope")

            html = read_url(f"{base_url}/").decode("utf-8")
            if "Gateway CAN Console" not in html:
                raise RuntimeError("Gateway Web root did not serve the production UI")
            asset_match = re.search(r'(?:src|href)="((?:\./|/)?assets/[^"]+\.(?:js|css))"', html)
            asset_url = (
                ""
                if asset_match is None
                else urllib.parse.urljoin(base_url + "/", asset_match.group(1))
            )
            if not asset_url or not read_url(asset_url):
                raise RuntimeError("Gateway Web production asset is unavailable")

            dbc = wait_for_json(f"{base_url}/api/v1/dbc", process).get("dbc")
            if not isinstance(dbc, dict):
                raise RuntimeError("Gateway DBC API returned an invalid envelope")
            catalog = dbc.get("catalog")
            if not isinstance(catalog, dict) or int(catalog.get("message_count", 0)) <= 0:
                raise RuntimeError("frozen Gateway did not load its adjacent DBC catalog")
        finally:
            terminate(process)
        verify_calibration_restart(executable, temp, environment)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("executable", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    run_smoke(args.executable)
    print(f"frozen Gateway Web and calibration restart smoke passed: {args.executable}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
