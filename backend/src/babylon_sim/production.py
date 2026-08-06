"""Production-only launcher with safe stale-listener cleanup."""

from __future__ import annotations

import _winapi
import ipaddress
import json
import os
import re
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from typing import Protocol

from . import cli

_MODULE_COMMAND = re.compile(
    r"(?:^|\s)-m\s+[\"']?babylon_sim\.(?:cli|production)[\"']?(?:\s|$)",
    re.IGNORECASE,
)
_POWERSHELL_SNAPSHOT = r"""
$ErrorActionPreference = 'Stop'
$port = [int]$env:BABYLON_SIM_CLEANUP_PORT
$connections = @(
    Get-NetTCPConnection -State Listen -ErrorAction Stop |
        Where-Object { $_.LocalPort -eq $port }
)
$listeners = @(
    foreach ($connection in $connections) {
        $process = Get-CimInstance Win32_Process `
            -Filter "ProcessId = $($connection.OwningProcess)" `
            -ErrorAction SilentlyContinue
        [pscustomobject]@{
            local_address = [string]$connection.LocalAddress
            local_port = [int]$connection.LocalPort
            pid = [int]$connection.OwningProcess
            creation_date = if ($null -eq $process) {
                $null
            } else {
                $process.CreationDate.ToUniversalTime().ToString('O')
            }
            executable_path = if ($null -eq $process) {
                $null
            } else {
                [string]$process.ExecutablePath
            }
            command_line = if ($null -eq $process) {
                $null
            } else {
                [string]$process.CommandLine
            }
        }
    }
)
[pscustomobject]@{ listeners = $listeners } | ConvertTo-Json -Compress -Depth 4
"""


class PortCleanupError(RuntimeError):
    """Raised when production cannot safely clear its requested port."""


@dataclass(frozen=True, slots=True)
class ListenerProcess:
    """One Windows TCP listener joined to its process identity."""

    local_address: str
    local_port: int
    pid: int
    creation_date: str | None
    executable_path: str | None
    command_line: str | None


ListenerQuery = Callable[[int], tuple[ListenerProcess, ...]]
Clock = Callable[[], float]
Sleeper = Callable[[float], None]


class ProcessHandle(Protocol):
    """A handle bound to one Windows process object, not just a reusable PID."""

    def terminate(self) -> None: ...

    def close(self) -> None: ...


ProcessHandleFactory = Callable[[int], ProcessHandle]


class _WindowsProcessHandle:
    def __init__(self, pid: int) -> None:
        process_terminate = 0x0001
        access = process_terminate | _winapi.SYNCHRONIZE
        self._handle = _winapi.OpenProcess(access, False, pid)

    def terminate(self) -> None:
        wait_result = _winapi.WaitForSingleObject(self._handle, 0)
        if wait_result == _winapi.WAIT_OBJECT_0:
            return
        if wait_result != _winapi.WAIT_TIMEOUT:
            raise OSError(f"unexpected process wait result: {wait_result}")
        _winapi.TerminateProcess(self._handle, 15)

    def close(self) -> None:
        _winapi.CloseHandle(self._handle)


def _optional_string(value: object) -> str | None:
    return value if isinstance(value, str) and value else None


def _required_integer(value: object, field: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise PortCleanupError(f"invalid listener snapshot field: {field}")
    return value


def _decode_snapshot(raw: str) -> tuple[ListenerProcess, ...]:
    try:
        payload: object = json.loads(raw.lstrip("\ufeff"))
    except json.JSONDecodeError as exc:
        raise PortCleanupError("Windows returned an invalid listener snapshot") from exc
    if not isinstance(payload, dict):
        raise PortCleanupError("Windows returned an invalid listener snapshot")
    listener_payload: object = payload.get("listeners", [])
    if isinstance(listener_payload, dict):
        listener_payload = [listener_payload]
    if not isinstance(listener_payload, list):
        raise PortCleanupError("Windows returned an invalid listener list")

    listeners: list[ListenerProcess] = []
    for item in listener_payload:
        if not isinstance(item, dict):
            raise PortCleanupError("Windows returned an invalid listener entry")
        local_address = item.get("local_address")
        if not isinstance(local_address, str):
            raise PortCleanupError("invalid listener snapshot field: local_address")
        listeners.append(
            ListenerProcess(
                local_address=local_address,
                local_port=_required_integer(item.get("local_port"), "local_port"),
                pid=_required_integer(item.get("pid"), "pid"),
                creation_date=_optional_string(item.get("creation_date")),
                executable_path=_optional_string(item.get("executable_path")),
                command_line=_optional_string(item.get("command_line")),
            )
        )
    return tuple(listeners)


def _query_windows_listeners(port: int) -> tuple[ListenerProcess, ...]:
    environment = os.environ.copy()
    environment["BABYLON_SIM_CLEANUP_PORT"] = str(port)
    try:
        result = subprocess.run(
            [
                "powershell",
                "-NoProfile",
                "-NonInteractive",
                "-ExecutionPolicy",
                "Bypass",
                "-Command",
                _POWERSHELL_SNAPSHOT,
            ],
            check=False,
            capture_output=True,
            text=True,
            encoding="utf-8",
            env=environment,
            timeout=5.0,
            creationflags=subprocess.CREATE_NO_WINDOW,
        )
    except subprocess.TimeoutExpired as exc:
        raise PortCleanupError(f"listener inspection timed out for port {port}") from exc
    except OSError as exc:
        raise PortCleanupError(f"unable to inspect port {port}: {exc}") from exc
    if result.returncode != 0:
        detail = result.stderr.strip() or "listener inspection failed"
        raise PortCleanupError(f"unable to inspect port {port}: {detail}")
    return _decode_snapshot(result.stdout)


def _open_process_handle(pid: int) -> ProcessHandle:
    return _WindowsProcessHandle(pid)


def _targets_host(listener: ListenerProcess, host: str) -> bool:
    try:
        local_address = ipaddress.ip_address(listener.local_address)
    except ValueError:
        return False
    if local_address.is_unspecified:
        return True
    if host == "localhost":
        return local_address.is_loopback
    return local_address == ipaddress.ip_address(host)


def _normalized_path(value: str) -> str:
    return os.path.normcase(os.path.realpath(os.path.abspath(value)))


def _owned_by_this_checkout(listener: ListenerProcess, python_executable: str) -> bool:
    return (
        listener.creation_date is not None
        and listener.executable_path is not None
        and listener.command_line is not None
        and _normalized_path(listener.executable_path) == _normalized_path(python_executable)
        and _MODULE_COMMAND.search(listener.command_line) is not None
    )


def _same_process(left: ListenerProcess, right: ListenerProcess) -> bool:
    if left.executable_path is None or right.executable_path is None:
        return False
    return (
        left.pid == right.pid
        and left.creation_date == right.creation_date
        and _normalized_path(left.executable_path) == _normalized_path(right.executable_path)
        and left.command_line == right.command_line
    )


def _format_conflict(listener: ListenerProcess) -> str:
    executable = listener.executable_path or "<unavailable>"
    command_line = listener.command_line or "<unavailable>"
    return (
        f"PID {listener.pid}, address {listener.local_address}:{listener.local_port}, "
        f"executable {executable!r}, command {command_line!r}"
    )


def _target_listeners(
    listeners: tuple[ListenerProcess, ...], host: str, port: int
) -> tuple[ListenerProcess, ...]:
    return tuple(
        listener
        for listener in listeners
        if listener.local_port == port and _targets_host(listener, host)
    )


def cleanup_stale_server(
    host: str,
    port: int,
    *,
    python_executable: str = sys.executable,
    query: ListenerQuery = _query_windows_listeners,
    open_process: ProcessHandleFactory = _open_process_handle,
    monotonic: Clock = time.monotonic,
    sleep: Sleeper = time.sleep,
    timeout: float = 5.0,
    poll_interval: float = 0.05,
) -> int | None:
    """Stop one verified same-checkout BabylonSim listener before production starts."""

    initial = _target_listeners(query(port), host, port)
    if not initial:
        return None

    pids = {listener.pid for listener in initial}
    if len(pids) != 1 or any(
        not _owned_by_this_checkout(listener, python_executable) for listener in initial
    ):
        conflicts = "\n  ".join(_format_conflict(listener) for listener in initial)
        raise PortCleanupError(
            f"refusing to stop an unverified listener on {host}:{port}:\n  {conflicts}"
        )

    expected = initial[0]
    if any(not _same_process(expected, listener) for listener in initial[1:]):
        raise PortCleanupError(f"refusing ambiguous listeners on {host}:{port}")

    try:
        process_handle = open_process(expected.pid)
    except OSError as exc:
        current = _target_listeners(query(port), host, port)
        if not current:
            print(
                f"Stale BabylonSim PID {expected.pid} released {host}:{port} before cleanup.",
                flush=True,
            )
            return expected.pid
        conflicts = "\n  ".join(_format_conflict(listener) for listener in current)
        raise PortCleanupError(
            f"unable to open stale BabylonSim PID {expected.pid}: {exc}\n  {conflicts}"
        ) from exc

    try:
        verified = _target_listeners(query(port), host, port)
        if not verified:
            print(
                f"Stale BabylonSim PID {expected.pid} released {host}:{port} before cleanup.",
                flush=True,
            )
            return expected.pid
        if any(not _same_process(expected, listener) for listener in verified):
            conflicts = "\n  ".join(_format_conflict(listener) for listener in verified)
            raise PortCleanupError(
                f"listener identity changed before cleanup on {host}:{port}:\n  {conflicts}"
            )

        print(f"Stopping stale BabylonSim PID {expected.pid} on {host}:{port}...", flush=True)
        try:
            process_handle.terminate()
        except OSError as exc:
            raise PortCleanupError(
                f"unable to stop stale BabylonSim PID {expected.pid}: {exc}"
            ) from exc

        deadline = monotonic() + timeout
        while True:
            remaining = _target_listeners(query(port), host, port)
            if not remaining:
                print(f"Released {host}:{port}; starting BabylonSim.", flush=True)
                return expected.pid
            if any(not _same_process(expected, listener) for listener in remaining):
                conflicts = "\n  ".join(_format_conflict(listener) for listener in remaining)
                raise PortCleanupError(
                    f"listener identity changed while releasing {host}:{port}:\n  {conflicts}"
                )
            if monotonic() >= deadline:
                raise PortCleanupError(
                    f"stale BabylonSim PID {expected.pid} did not release {host}:{port} "
                    f"within {timeout:.1f} seconds"
                )
            sleep(poll_interval)
    finally:
        process_handle.close()


def main() -> int:
    """Clean the selected port, then enter the unchanged production CLI."""

    args = cli.build_parser().parse_args()
    if not 1 <= args.port <= 65535:
        raise SystemExit("port must be between 1 and 65535")
    try:
        cleanup_stale_server(args.host, args.port)
    except PortCleanupError as exc:
        raise SystemExit(f"production startup blocked: {exc}") from None
    return cli.main()


if __name__ == "__main__":
    raise SystemExit(main())
