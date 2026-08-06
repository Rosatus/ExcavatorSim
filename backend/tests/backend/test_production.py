from __future__ import annotations

import socket
import subprocess
import sys
import time
import urllib.request
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path

import pytest

from babylon_sim import production
from babylon_sim.production import ListenerProcess, PortCleanupError, cleanup_stale_server

PYTHON = sys.executable


def _listener(
    *,
    pid: int = 100,
    executable_path: str = PYTHON,
    command_line: str = f'"{PYTHON}" -m babylon_sim.cli --no-browser',
) -> ListenerProcess:
    return ListenerProcess(
        local_address="127.0.0.1",
        local_port=8765,
        pid=pid,
        creation_date="2026-07-30T00:00:00.0000000Z",
        executable_path=executable_path,
        command_line=command_line,
    )


def _sequence_query(
    snapshots: Iterator[tuple[ListenerProcess, ...]],
) -> production.ListenerQuery:
    def query(_port: int) -> tuple[ListenerProcess, ...]:
        return next(snapshots)

    return query


@dataclass
class _FakeProcessHandle:
    pid: int
    terminated: list[int]
    closed: list[int]

    def terminate(self) -> None:
        self.terminated.append(self.pid)

    def close(self) -> None:
        self.closed.append(self.pid)


def _handle_factory(
    terminated: list[int], closed: list[int] | None = None
) -> production.ProcessHandleFactory:
    closed_handles = closed if closed is not None else []

    def open_process(pid: int) -> _FakeProcessHandle:
        return _FakeProcessHandle(pid, terminated, closed_handles)

    return open_process


def _listener_on(address: str) -> ListenerProcess:
    listener = _listener()
    return ListenerProcess(
        local_address=address,
        local_port=listener.local_port,
        pid=listener.pid,
        creation_date=listener.creation_date,
        executable_path=listener.executable_path,
        command_line=listener.command_line,
    )


def _free_loopback_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(("127.0.0.1", 0))
        return int(probe.getsockname()[1])


def _wait_for_production(process: subprocess.Popen[bytes], port: int) -> None:
    deadline = time.monotonic() + 30.0
    while time.monotonic() < deadline:
        if process.poll() is not None:
            raise AssertionError(f"production PID {process.pid} exited with {process.returncode}")
        listeners = production._query_windows_listeners(port)
        if any(listener.pid == process.pid for listener in listeners):
            try:
                with urllib.request.urlopen(
                    f"http://127.0.0.1:{port}/health", timeout=0.5
                ) as response:
                    if response.status == 200:
                        return
            except OSError:
                pass
        time.sleep(0.1)
    raise AssertionError(f"production PID {process.pid} did not become healthy")


def test_cleanup_does_nothing_without_a_listener() -> None:
    terminated: list[int] = []

    result = cleanup_stale_server(
        "127.0.0.1",
        8765,
        python_executable=PYTHON,
        query=lambda _port: (),
        open_process=_handle_factory(terminated),
    )

    assert result is None
    assert terminated == []


def test_cleanup_stops_verified_same_checkout_listener(capsys: pytest.CaptureFixture[str]) -> None:
    stale = _listener()
    snapshots = iter(((stale,), (stale,), ()))
    terminated: list[int] = []
    closed: list[int] = []

    result = cleanup_stale_server(
        "127.0.0.1",
        8765,
        python_executable=PYTHON,
        query=_sequence_query(snapshots),
        open_process=_handle_factory(terminated, closed),
    )

    assert result == stale.pid
    assert terminated == [stale.pid]
    assert closed == [stale.pid]
    assert "Stopping stale BabylonSim PID 100" in capsys.readouterr().out


def test_cleanup_stops_previous_production_launcher() -> None:
    stale = _listener(
        command_line=f'"{PYTHON}" -m babylon_sim.production --no-browser',
    )
    terminated: list[int] = []

    result = cleanup_stale_server(
        "127.0.0.1",
        8765,
        python_executable=PYTHON,
        query=_sequence_query(iter(((stale,), (stale,), ()))),
        open_process=_handle_factory(terminated),
    )

    assert result == stale.pid
    assert terminated == [stale.pid]


def test_cleanup_refuses_unrelated_listener() -> None:
    unrelated = _listener(
        pid=200,
        executable_path=r"C:\Python311\python.exe",
        command_line="python -m http.server 8765",
    )
    terminated: list[int] = []

    with pytest.raises(PortCleanupError, match=r"PID 200.*http\.server"):
        cleanup_stale_server(
            "127.0.0.1",
            8765,
            python_executable=PYTHON,
            query=lambda _port: (unrelated,),
            open_process=_handle_factory(terminated),
        )

    assert terminated == []


def test_cleanup_refuses_process_identity_change_before_termination() -> None:
    stale = _listener()
    replacement = _listener(pid=201, command_line="python -m other.service")
    terminated: list[int] = []
    closed: list[int] = []

    with pytest.raises(PortCleanupError, match="identity changed before cleanup"):
        cleanup_stale_server(
            "127.0.0.1",
            8765,
            python_executable=PYTHON,
            query=_sequence_query(iter(((stale,), (replacement,)))),
            open_process=_handle_factory(terminated, closed),
        )

    assert terminated == []
    assert closed == [stale.pid]


def test_cleanup_times_out_while_verified_listener_remains() -> None:
    stale = _listener()
    clock = iter((0.0, 1.0))

    with pytest.raises(PortCleanupError, match="did not release"):
        cleanup_stale_server(
            "127.0.0.1",
            8765,
            python_executable=PYTHON,
            query=lambda _port: (stale,),
            open_process=_handle_factory([]),
            monotonic=lambda: next(clock),
            sleep=lambda _seconds: None,
            timeout=0.5,
        )


def test_cleanup_refuses_unrelated_wildcard_listener() -> None:
    wildcard = ListenerProcess(
        local_address="0.0.0.0",
        local_port=8765,
        pid=202,
        creation_date="2026-07-30T00:00:00.0000000Z",
        executable_path=r"C:\Windows\System32\svchost.exe",
        command_line="svchost.exe",
    )
    terminated: list[int] = []

    with pytest.raises(PortCleanupError, match=r"PID 202.*svchost"):
        cleanup_stale_server(
            "127.0.0.1",
            8765,
            python_executable=PYTHON,
            query=lambda _port: (wildcard,),
            open_process=_handle_factory(terminated),
        )

    assert terminated == []


def test_target_matching_covers_localhost_ipv6_and_unspecified_addresses() -> None:
    assert production._targets_host(_listener_on("127.0.0.1"), "localhost")
    assert production._targets_host(_listener_on("::1"), "localhost")
    assert production._targets_host(_listener_on("::1"), "::1")
    assert production._targets_host(_listener_on("0.0.0.0"), "127.0.0.1")
    assert production._targets_host(_listener_on("::"), "::1")


def test_cleanup_refuses_same_python_with_unrelated_module() -> None:
    unrelated = _listener(pid=203, command_line=f'"{PYTHON}" -m http.server 8765')
    terminated: list[int] = []

    with pytest.raises(PortCleanupError, match=r"PID 203.*http\.server"):
        cleanup_stale_server(
            "127.0.0.1",
            8765,
            python_executable=PYTHON,
            query=lambda _port: (unrelated,),
            open_process=_handle_factory(terminated),
        )

    assert terminated == []


def test_listener_query_has_a_hard_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    def timeout(*_args: object, **_kwargs: object) -> None:
        raise production.subprocess.TimeoutExpired("powershell", 5.0)

    monkeypatch.setattr(production.subprocess, "run", timeout)

    with pytest.raises(PortCleanupError, match="inspection timed out"):
        production._query_windows_listeners(8765)


def test_real_production_restart_replaces_listener_and_recovers_health(tmp_path: Path) -> None:
    port = _free_loopback_port()
    (tmp_path / "index.html").write_text("<!doctype html><title>test</title>", encoding="utf-8")
    command = [
        sys.executable,
        "-m",
        "babylon_sim.production",
        "--no-browser",
        "--port",
        str(port),
        "--frontend-dir",
        str(tmp_path),
    ]
    first = subprocess.Popen(
        command,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        creationflags=subprocess.CREATE_NO_WINDOW,
    )
    second: subprocess.Popen[bytes] | None = None
    try:
        _wait_for_production(first, port)
        second = subprocess.Popen(
            command,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
        _wait_for_production(second, port)

        first.wait(timeout=10.0)
        listeners = production._query_windows_listeners(port)
        assert first.pid != second.pid
        assert all(listener.pid != first.pid for listener in listeners)
        assert any(listener.pid == second.pid for listener in listeners)
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/health", timeout=3.0) as response:
            assert response.status == 200
    finally:
        for process in (second, first):
            if process is None or process.poll() is not None:
                continue
            process.terminate()
            process.wait(timeout=10.0)


def test_main_uses_custom_port_without_rewriting_cli_arguments(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    arguments = [
        "babylon_sim.production",
        "--host",
        "127.0.0.1",
        "--port",
        "8877",
        "--no-browser",
        "--frontend-dir",
        "godot/dist",
    ]
    observed: list[tuple[str, int]] = []
    monkeypatch.setattr(sys, "argv", arguments.copy())
    monkeypatch.setattr(
        production,
        "cleanup_stale_server",
        lambda host, port: observed.append((host, port)),
    )
    monkeypatch.setattr(production.cli, "main", lambda: 17)

    assert production.main() == 17
    assert observed == [("127.0.0.1", 8877)]
    assert sys.argv == arguments
