"""SocketCAN vcan interface detection and creation (Linux only).

Ported from dev_arch2.0 tools/can_replay/vcan_setup.py: check for an existing
interface, auto-create vcanN interfaces with sudo when missing, tolerate
concurrent creators. Runner injection kept for deterministic tests.
"""

from __future__ import annotations

import os
import re
import shlex
import shutil
import subprocess
import sys
from collections.abc import Callable, Sequence
from typing import Any


CommandRunner = Callable[..., subprocess.CompletedProcess[str]]
_AUTO_VCAN_NAME = re.compile(r"vcan\d+\Z")


class VcanSetupError(RuntimeError):
    """vcan interface inspection or creation failed."""


def _command_error(command: Sequence[str], result: Any) -> VcanSetupError:
    detail = (getattr(result, "stderr", "") or getattr(result, "stdout", "") or "").strip()
    suffix = f": {detail}" if detail else ""
    return VcanSetupError(f"command failed: {shlex.join(command)}{suffix}")


def _run(
    runner: CommandRunner,
    command: Sequence[str],
    *,
    interactive: bool = False,
) -> subprocess.CompletedProcess[str]:
    try:
        if interactive:
            result = runner(command, check=False)
        else:
            result = runner(command, check=False, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise VcanSetupError(f"command not found: {command[0]}") from exc

    if result.returncode != 0:
        raise _command_error(command, result)
    return result


def _interface_status(runner: CommandRunner, interface: str) -> tuple[bool, bool]:
    command = ["ip", "link", "show", "dev", interface]
    try:
        result = runner(command, check=False, capture_output=True, text=True)
    except FileNotFoundError as exc:
        raise VcanSetupError("command not found: ip") from exc

    if result.returncode == 0:
        output = getattr(result, "stdout", "") or ""
        flags_match = re.search(r":\s*<([^>]*)>", output)
        flags = flags_match.group(1).split(",") if flags_match else []
        return True, "UP" in flags or re.search(r"\bstate UP\b", output) is not None
    if result.returncode == 1:
        return False, False
    raise _command_error(command, result)


def _sudo_prefix(
    runner: CommandRunner,
    *,
    geteuid: Callable[[], int],
    which: Callable[[str], str | None],
) -> list[str]:
    if geteuid() == 0:
        return []
    if which("sudo") is None:
        raise VcanSetupError("creating a vcan interface requires root privileges but no sudo is installed")

    probe = runner(["sudo", "-n", "true"], check=False, capture_output=True, text=True)
    if probe.returncode != 0:
        _run(runner, ["sudo", "-v"], interactive=True)
    return ["sudo"]


def require_vcan_interface(
    interface: str = "vcan0",
    *,
    runner: CommandRunner | None = None,
) -> None:
    """Raise unless the SocketCAN interface already exists (no auto-create)."""
    if not interface:
        raise VcanSetupError("SocketCAN interface name must not be empty")

    runner = runner or subprocess.run
    if not _interface_status(runner, interface)[0]:
        raise VcanSetupError(
            f"SocketCAN interface '{interface}' does not exist. Run first: gateway --setup-vcan --interface {interface}"
        )


def ensure_vcan_interface(
    interface: str = "vcan0",
    *,
    runner: CommandRunner | None = None,
    geteuid: Callable[[], int] | None = None,
    which: Callable[[str], str | None] | None = None,
) -> None:
    """Ensure the vcanN interface exists; create it via sudo when missing."""
    if not interface:
        raise VcanSetupError("SocketCAN interface name must not be empty")

    runner = runner or subprocess.run
    geteuid = geteuid or os.geteuid
    which = which or shutil.which

    exists, is_up = _interface_status(runner, interface)
    if exists:
        if is_up or not _AUTO_VCAN_NAME.fullmatch(interface):
            return
        prefix = _sudo_prefix(runner, geteuid=geteuid, which=which)
        _run(runner, [*prefix, "ip", "link", "set", "dev", interface, "up"])
        return

    if not _AUTO_VCAN_NAME.fullmatch(interface):
        raise VcanSetupError(
            f"SocketCAN interface '{interface}' does not exist; only vcan0/vcan1 style names are auto-created, "
            "configure real CAN hardware drivers separately"
        )

    prefix = _sudo_prefix(runner, geteuid=geteuid, which=which)
    _run(runner, [*prefix, "modprobe", "vcan"])
    try:
        _run(runner, [*prefix, "ip", "link", "add", "dev", interface, "type", "vcan"])
    except VcanSetupError:
        # Concurrent invocations may have created the interface in between.
        if not _interface_status(runner, interface)[0]:
            raise
    _run(runner, [*prefix, "ip", "link", "set", "dev", interface, "up"])

    if not _interface_status(runner, interface)[0]:
        raise VcanSetupError(f"vcan interface '{interface}' still invisible after creation")


if __name__ == "__main__":
    interface = sys.argv[1] if len(sys.argv) > 1 else "vcan0"
    try:
        ensure_vcan_interface(interface)
    except VcanSetupError as exc:
        print(f"vcan setup failed: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
    print(f"SocketCAN interface ready: {interface}")
