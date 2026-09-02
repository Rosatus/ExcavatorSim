from __future__ import annotations

import json
import os
import queue
import socket
import subprocess
import sys
import tempfile
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, cast

from pc001_test_client.protocol import Pc001Batch
from pc001_test_client.receiver import Pc001Receiver, ReceiverEvent, ReceiverState

REPO_ROOT = Path(__file__).resolve().parents[3]
GATEWAY_DIR = REPO_ROOT / "tools" / "can_gateway"


def _free_port(*, udp: bool = False) -> int:
    kind = socket.SOCK_DGRAM if udp else socket.SOCK_STREAM
    probe = socket.socket(socket.AF_INET, kind)
    probe.bind(("127.0.0.1", 0))
    port = int(probe.getsockname()[1])
    probe.close()
    return port


def _request_json(
    url: str,
    method: str = "GET",
    body: dict[str, object] | None = None,
) -> dict[str, Any]:
    data = None if body is None else json.dumps(body).encode("utf-8")
    request = urllib.request.Request(
        url,
        data=data,
        method=method,
        headers={"Content-Type": "application/json"} if data is not None else {},
    )
    with urllib.request.urlopen(request, timeout=3.0) as response:
        payload = json.loads(response.read())
    if not isinstance(payload, dict):
        raise AssertionError("Gateway response must be a JSON object")
    return cast(dict[str, Any], payload)


class GatewayProcessIntegrationTest(unittest.TestCase):
    def test_receiver_connects_to_real_gateway_and_observes_all_channel_families(self) -> None:
        udp_port = _free_port(udp=True)
        ack_port = _free_port(udp=True)
        tcp_port = _free_port()
        web_port = _free_port()
        with tempfile.TemporaryDirectory() as temporary:
            environment = dict(os.environ)
            environment["LOCALAPPDATA"] = str(Path(temporary, "local"))
            environment["XDG_CONFIG_HOME"] = str(Path(temporary, "config"))
            environment["XDG_STATE_HOME"] = str(Path(temporary, "state"))
            creation_flags = subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0
            process = subprocess.Popen(
                [
                    sys.executable,
                    str(GATEWAY_DIR / "gateway.py"),
                    "--mode",
                    "standalone",
                    "--sink",
                    "tcp",
                    "--host",
                    "127.0.0.1",
                    "--port",
                    str(udp_port),
                    "--ack-port",
                    str(ack_port),
                    "--tcp-host",
                    "127.0.0.1",
                    "--tcp-port",
                    str(tcp_port),
                    "--web-port",
                    str(web_port),
                    "--out",
                    str(Path(temporary, "output")),
                ],
                cwd=REPO_ROOT,
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                creationflags=creation_flags,
            )
            states: queue.Queue[ReceiverEvent] = queue.Queue()
            batches: queue.Queue[tuple[int, Pc001Batch, float]] = queue.Queue()
            receiver = Pc001Receiver(
                states.put,
                lambda generation, batch, received_s: batches.put(
                    (generation, batch, received_s)
                ),
            )
            try:
                base = f"http://127.0.0.1:{web_port}"
                deadline = time.monotonic() + 10.0
                while True:
                    try:
                        snapshot = _request_json(f"{base}/api/v1/can-console")
                        break
                    except (OSError, urllib.error.URLError):
                        if time.monotonic() >= deadline:
                            self.fail("Gateway Web API did not become ready")
                        time.sleep(0.05)

                generation = receiver.start("127.0.0.1", tcp_port)
                connected = False
                deadline = time.monotonic() + 3.0
                while not connected and time.monotonic() < deadline:
                    event = states.get(timeout=1.0)
                    connected = (
                        event.generation == generation
                        and event.state == ReceiverState.CONNECTED
                    )
                self.assertTrue(connected)

                revision = int(snapshot["status"]["revision"])
                bulk = _request_json(
                    f"{base}/api/v1/can-console/authority",
                    "PUT",
                    {"authority": "custom", "expected_revision": revision},
                )
                revision = int(bulk["result"]["status"]["revision"])
                _request_json(
                    f"{base}/api/v1/can-console/start",
                    "POST",
                    {"expected_revision": revision},
                )

                expected = {
                    (True, 0x18FF3A00, 3),
                    (True, 0x0CFDA800, 2),
                    (True, 0x18FFF100, 3),
                    (False, 0x256, 0),
                }
                observed: set[tuple[bool, int, int]] = set()
                deadline = time.monotonic() + 5.0
                while not expected.issubset(observed) and time.monotonic() < deadline:
                    _batch_generation, batch, _received_s = batches.get(timeout=1.0)
                    observed.update(
                        (frame.is_extended, frame.can_id, frame.channel)
                        for frame in batch.frames
                    )
                self.assertTrue(expected.issubset(observed), expected - observed)
            finally:
                receiver.stop()
                process.terminate()
                try:
                    process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=3.0)


if __name__ == "__main__":
    unittest.main()
