"""Inspect and prepare the fixed physical CAN interface used by Linux ICT."""

from __future__ import annotations

import contextlib
import json
import subprocess
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

CAN_INTERFACE = "can0"
CAN_BITRATE = 250_000
CAN_RESTART_MS = 100
CAN_TX_QUEUE_LEN = 1_000
CAN0_HELPER_PATH = Path("/usr/local/libexec/excavatorsim/can0-setup-helper")
CAN0_LOCK_PATH = Path("/run/lock/excavatorsim-can0.lock")
IP_PATH_CANDIDATES = tuple(
    Path(path) for path in ("/usr/sbin/ip", "/usr/bin/ip", "/sbin/ip", "/bin/ip")
)
MINIMAL_COMMAND_ENV = {
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin",
    "LANG": "C",
    "LC_ALL": "C",
}

CommandRunner = Callable[..., subprocess.CompletedProcess[str]]


class Can0SetupError(RuntimeError):
    """Stable can0 preparation failure surfaced at the ICT transport boundary."""

    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code


@dataclass(frozen=True)
class CanInterfaceSnapshot:
    exists: bool
    kind: str | None = None
    up: bool = False
    bitrate: int | None = None
    restart_ms: int | None = None
    tx_queue_len: int | None = None
    controller_state: str | None = None

    def readiness_issues(self) -> tuple[str, ...]:
        if not self.exists:
            return ("interface missing",)
        issues: list[str] = []
        if self.kind != "can":
            issues.append(f"kind={self.kind or 'unknown'}")
        if not self.up:
            issues.append("interface is not UP")
        if self.bitrate != CAN_BITRATE:
            issues.append(f"bitrate={self.bitrate!r}")
        if self.restart_ms != CAN_RESTART_MS:
            issues.append(f"restart_ms={self.restart_ms!r}")
        if self.tx_queue_len != CAN_TX_QUEUE_LEN:
            issues.append(f"tx_queue_len={self.tx_queue_len!r}")
        state = (self.controller_state or "").upper().replace("_", "-")
        if not state or state in {"STOPPED", "BUS-OFF", "SLEEPING"}:
            issues.append(f"controller_state={self.controller_state!r}")
        return tuple(issues)

    @property
    def ready(self) -> bool:
        return not self.readiness_issues()


def _completed(
    runner: CommandRunner,
    command: list[str],
) -> subprocess.CompletedProcess[str]:
    try:
        return runner(
            command,
            check=False,
            capture_output=True,
            text=True,
            env=MINIMAL_COMMAND_ENV,
        )
    except FileNotFoundError as exc:
        raise Can0SetupError(
            "CAN0_IP_MISSING",
            "iproute2 'ip' command is unavailable; install iproute2 before using ICT",
        ) from exc


def _as_int(value: object) -> int | None:
    if isinstance(value, bool):
        return None
    if isinstance(value, int):
        return value
    if isinstance(value, str):
        with contextlib.suppress(ValueError):
            return int(value, 10)
    return None


def _ip_path() -> str:
    """Return an iproute2 binary only from the fixed system allowlist."""

    for candidate in IP_PATH_CANDIDATES:
        if candidate.is_file():
            return str(candidate)
    # Keep the primary path in diagnostics and injected-runner tests. The real
    # subprocess call will turn its absence into the stable IP-missing error.
    return str(IP_PATH_CANDIDATES[0])


def _fixed_sudo_path(name: str) -> str | None:
    if name != "sudo":
        return None
    return next(
        (
            str(candidate)
            for candidate in (Path("/usr/bin/sudo"), Path("/bin/sudo"))
            if candidate.is_file()
        ),
        None,
    )


def _parse_snapshot(payload: str) -> CanInterfaceSnapshot:
    try:
        decoded = json.loads(payload)
    except json.JSONDecodeError as exc:
        raise Can0SetupError("CAN0_INSPECT_FAILED", f"invalid iproute2 JSON: {exc.msg}") from exc
    if not isinstance(decoded, list) or len(decoded) != 1 or not isinstance(decoded[0], dict):
        raise Can0SetupError("CAN0_INSPECT_FAILED", "iproute2 returned an unexpected link shape")
    link = decoded[0]
    linkinfo = link.get("linkinfo")
    if not isinstance(linkinfo, dict):
        linkinfo = {}
    info_data = linkinfo.get("info_data")
    if not isinstance(info_data, dict):
        info_data = {}
    bittiming = info_data.get("bittiming")
    if not isinstance(bittiming, dict):
        bittiming = {}
    flags = link.get("flags")
    if not isinstance(flags, list):
        flags = []
    state_value = info_data.get("state")
    controller_state = state_value if isinstance(state_value, str) else None
    restart_value = info_data.get("restart_ms", info_data.get("restart-ms"))
    bitrate_value = bittiming.get("bitrate", info_data.get("bitrate"))
    return CanInterfaceSnapshot(
        exists=True,
        kind=linkinfo.get("info_kind") if isinstance(linkinfo.get("info_kind"), str) else None,
        up="UP" in flags,
        bitrate=_as_int(bitrate_value),
        restart_ms=_as_int(restart_value),
        tx_queue_len=_as_int(link.get("txqlen")),
        controller_state=controller_state,
    )


def inspect_can0(*, runner: CommandRunner = subprocess.run) -> CanInterfaceSnapshot:
    result = _completed(
        runner,
        [_ip_path(), "-j", "-d", "link", "show", "dev", CAN_INTERFACE],
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        missing_markers = ("does not exist", "cannot find device", "not found")
        if any(marker in detail.lower() for marker in missing_markers):
            return CanInterfaceSnapshot(exists=False)
        raise Can0SetupError(
            "CAN0_INSPECT_FAILED",
            f"cannot inspect {CAN_INTERFACE}: {detail or f'ip exited {result.returncode}'}",
        )
    return _parse_snapshot(result.stdout)


def _run_checked(runner: CommandRunner, command: list[str]) -> None:
    result = _completed(runner, command)
    if result.returncode == 0:
        return
    detail = (result.stderr or result.stdout or "").strip()
    raise Can0SetupError(
        "CAN0_SETUP_FAILED",
        f"{' '.join(command)} failed: {detail or f'exit {result.returncode}'}",
    )


@contextlib.contextmanager
def _exclusive_setup_lock(lock_path: Path | None) -> Iterator[None]:
    if lock_path is None:
        yield
        return
    try:
        import fcntl
    except ImportError as exc:  # pragma: no cover - helper is Linux-only
        raise Can0SetupError("CAN0_SETUP_FAILED", "can0 setup locking requires Linux") from exc
    with lock_path.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def configure_can0(
    *,
    runner: CommandRunner = subprocess.run,
    lock_path: Path | None = CAN0_LOCK_PATH,
    force: bool = False,
) -> CanInterfaceSnapshot:
    """Apply the fixed can0 contract. Intended to run only in the root helper."""

    with _exclusive_setup_lock(lock_path):
        snapshot = inspect_can0(runner=runner)
        if not snapshot.exists:
            raise Can0SetupError(
                "CAN0_MISSING",
                "can0 does not exist; connect the USB-CAN adapter and load its driver",
            )
        if snapshot.ready and not force:
            return snapshot
        if snapshot.kind != "can":
            raise Can0SetupError(
                "CAN0_WRONG_KIND",
                f"can0 is {snapshot.kind or 'unknown'}, not a driver-created CAN interface",
            )

        down_applied = False
        try:
            ip_path = _ip_path()
            _run_checked(runner, [ip_path, "link", "set", CAN_INTERFACE, "down"])
            down_applied = True
            _run_checked(
                runner,
                [
                    ip_path,
                    "link",
                    "set",
                    CAN_INTERFACE,
                    "type",
                    "can",
                    "bitrate",
                    str(CAN_BITRATE),
                    "restart-ms",
                    str(CAN_RESTART_MS),
                ],
            )
            _run_checked(
                runner,
                [
                    ip_path,
                    "link",
                    "set",
                    CAN_INTERFACE,
                    "txqueuelen",
                    str(CAN_TX_QUEUE_LEN),
                ],
            )
            _run_checked(runner, [ip_path, "link", "set", CAN_INTERFACE, "up"])
            down_applied = False
        except Can0SetupError:
            if down_applied and snapshot.up:
                with contextlib.suppress(Can0SetupError):
                    _run_checked(runner, [ip_path, "link", "set", CAN_INTERFACE, "up"])
            raise

        verified = inspect_can0(runner=runner)
        if not verified.ready:
            raise Can0SetupError(
                "CAN0_NOT_READY",
                "can0 post-verification failed: " + ", ".join(verified.readiness_issues()),
            )
        return verified


def prepare_can0(
    *,
    runner: CommandRunner = subprocess.run,
    helper_path: Path = CAN0_HELPER_PATH,
    which: Callable[[str], str | None] = _fixed_sudo_path,
) -> CanInterfaceSnapshot:
    """Unprivileged Gateway entry point: inspect, invoke fixed helper if needed, verify."""

    snapshot = inspect_can0(runner=runner)
    if not snapshot.exists:
        raise Can0SetupError(
            "CAN0_MISSING",
            "can0 does not exist; connect the USB-CAN adapter and load its driver",
        )
    if snapshot.ready:
        return snapshot
    if not helper_path.is_file():
        raise Can0SetupError(
            "CAN0_HELPER_MISSING",
            "can0 setup helper is not installed; run install_can0_helper.sh as administrator",
        )
    sudo_path = which("sudo")
    if sudo_path is None:
        raise Can0SetupError("CAN0_PRIVILEGE", "sudo is unavailable; install the can0 helper first")
    result = _completed(runner, [sudo_path, "-n", str(helper_path)])
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        lowered = detail.lower()
        if "can0_missing" in lowered:
            code = "CAN0_MISSING"
        elif "password" in lowered or "sudoers" in lowered or "not allowed" in lowered:
            code = "CAN0_PRIVILEGE"
        else:
            code = "CAN0_SETUP_FAILED"
        raise Can0SetupError(code, detail or f"can0 helper exited {result.returncode}")
    verified = inspect_can0(runner=runner)
    if not verified.ready:
        raise Can0SetupError(
            "CAN0_NOT_READY",
            "can0 is still not ready: " + ", ".join(verified.readiness_issues()),
        )
    return verified


def restart_can0(
    *,
    runner: CommandRunner = subprocess.run,
    helper_path: Path = CAN0_HELPER_PATH,
    which: Callable[[str], str | None] = _fixed_sudo_path,
) -> CanInterfaceSnapshot:
    """Force the installed fixed helper transaction, then verify can0."""

    snapshot = inspect_can0(runner=runner)
    if not snapshot.exists:
        raise Can0SetupError(
            "CAN0_MISSING",
            "can0 does not exist; connect the USB-CAN adapter and load its driver",
        )
    if snapshot.kind != "can":
        raise Can0SetupError(
            "CAN0_WRONG_KIND",
            f"can0 is {snapshot.kind or 'unknown'}, not a driver-created CAN interface",
        )
    if not helper_path.is_file():
        raise Can0SetupError(
            "CAN0_HELPER_MISSING",
            "can0 setup helper is not installed; run install_can0_helper.sh as administrator",
        )
    sudo_path = which("sudo")
    if sudo_path is None:
        raise Can0SetupError("CAN0_PRIVILEGE", "sudo is unavailable; install the can0 helper first")
    result = _completed(runner, [sudo_path, "-n", str(helper_path)])
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "").strip()
        lowered = detail.lower()
        if "can0_missing" in lowered:
            code = "CAN0_MISSING"
        elif "password" in lowered or "sudoers" in lowered or "not allowed" in lowered:
            code = "CAN0_PRIVILEGE"
        else:
            code = "CAN0_SETUP_FAILED"
        raise Can0SetupError(code, detail or f"can0 helper exited {result.returncode}")
    verified = inspect_can0(runner=runner)
    if not verified.ready:
        raise Can0SetupError(
            "CAN0_NOT_READY",
            "can0 is still not ready: " + ", ".join(verified.readiness_issues()),
        )
    return verified
