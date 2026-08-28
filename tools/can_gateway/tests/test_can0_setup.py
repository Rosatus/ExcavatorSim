"""Tests for fixed physical-can0 inspection and preparation."""

from __future__ import annotations

import json
import os
import stat
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from can0_setup import (  # noqa: E402
    CAN0_HELPER_PATH,
    CAN0_LOCK_PATH,
    IP_PATH_CANDIDATES,
    MINIMAL_COMMAND_ENV,
    Can0LockOps,
    Can0SetupError,
    _exclusive_setup_lock,
    _validate_lock_directory,
    _validate_lock_file,
    _validate_runtime_root,
    configure_can0,
    inspect_can0,
    prepare_can0,
    restart_can0,
)
from can0_setup_helper import main as helper_main  # noqa: E402

TEST_LOCK_PATH = Path("C:/run/excavatorsim/can0.lock")


def link_json(
    *,
    up: bool = True,
    bitrate: int = 250_000,
    restart_ms: int = 100,
    txqlen: int = 1_000,
    state: str = "ERROR-ACTIVE",
    kind: str = "can",
) -> str:
    return json.dumps(
        [
            {
                "ifname": "can0",
                "flags": ["UP", "NOARP"] if up else ["NOARP"],
                "txqlen": txqlen,
                "linkinfo": {
                    "info_kind": kind,
                    "info_data": {
                        "state": state,
                        "restart_ms": restart_ms,
                        "bittiming": {"bitrate": bitrate},
                    },
                },
            }
        ]
    )


class SequenceRunner:
    def __init__(self, inspections: list[str], failures: dict[tuple[str, ...], str] | None = None):
        self.inspections = list(inspections)
        self.failures = failures or {}
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, command, **kwargs):
        key = tuple(command)
        self.calls.append(key)
        if key[1:6] == ("-j", "-d", "link", "show", "dev"):
            if not self.inspections:
                raise AssertionError("unexpected extra inspection")
            return SimpleNamespace(returncode=0, stdout=self.inspections.pop(0), stderr="")
        if key in self.failures:
            return SimpleNamespace(returncode=1, stdout="", stderr=self.failures[key])
        return SimpleNamespace(returncode=0, stdout="", stderr="")


def fake_stat(mode: int, *, uid: int = 0, nlink: int = 1) -> SimpleNamespace:
    return SimpleNamespace(st_mode=mode, st_uid=uid, st_nlink=nlink)


def make_lock_ops(
    *,
    runtime_metadata: SimpleNamespace | None = None,
    directory_metadata: SimpleNamespace | None = None,
    lock_metadata: SimpleNamespace | None = None,
    fail_phase: str | None = None,
) -> Can0LockOps:
    metadata = {
        10: runtime_metadata or fake_stat(stat.S_IFDIR | 0o755),
        11: directory_metadata or fake_stat(stat.S_IFDIR | 0o700),
        12: lock_metadata or fake_stat(stat.S_IFREG | 0o600),
    }
    open_fds = iter((10, 11, 12))

    def open_fd(*args, **kwargs):
        fd = next(open_fds)
        if fail_phase == f"open_{fd}":
            raise PermissionError("attacker-controlled open detail")
        return fd

    def mkdir(*args, **kwargs):
        if fail_phase == "mkdir":
            raise PermissionError("attacker-controlled mkdir detail")

    def fstat(fd):
        if fail_phase == f"fstat_{fd}":
            raise OSError("attacker-controlled stat detail")
        return metadata[fd]

    def flock(fd, operation):
        if fail_phase == "flock":
            raise PermissionError("attacker-controlled flock detail")

    return Can0LockOps(
        open_fd=open_fd,
        mkdir=mkdir,
        fstat=fstat,
        flock=flock,
        close_fd=lambda fd: None,
        lock_ex=1,
    )


class Can0InspectionTest(unittest.TestCase):
    def test_ready_snapshot_is_exact(self) -> None:
        runner = SequenceRunner([link_json()])
        snapshot = inspect_can0(runner=runner)
        self.assertTrue(snapshot.ready)
        self.assertEqual(snapshot.readiness_issues(), ())
        self.assertIn(Path(runner.calls[0][0]), IP_PATH_CANDIDATES)

    def test_missing_interface_is_not_created(self) -> None:
        def runner(command, **kwargs):
            return SimpleNamespace(returncode=1, stdout="", stderr='Device "can0" does not exist.')

        snapshot = inspect_can0(runner=runner)
        self.assertFalse(snapshot.exists)

    def test_unverifiable_snapshot_is_not_ready(self) -> None:
        snapshot = inspect_can0(runner=SequenceRunner([json.dumps([{"flags": ["UP"]}])]))
        self.assertFalse(snapshot.ready)
        self.assertIn("kind=unknown", snapshot.readiness_issues())

    def test_stopped_and_bus_off_controllers_are_not_ready(self) -> None:
        for state in ("STOPPED", "BUS-OFF"):
            with self.subTest(state=state):
                snapshot = inspect_can0(runner=SequenceRunner([link_json(state=state)]))
                self.assertFalse(snapshot.ready)
                self.assertIn(f"controller_state='{state}'", snapshot.readiness_issues())


class Can0ConfigureTest(unittest.TestCase):
    def test_ready_interface_is_noop(self) -> None:
        runner = SequenceRunner([link_json()])
        snapshot = configure_can0(runner=runner, lock_path=None)
        self.assertTrue(snapshot.ready)
        self.assertEqual(len(runner.calls), 1)

    def test_mismatch_runs_reference_order_and_verifies(self) -> None:
        runner = SequenceRunner([link_json(up=False, bitrate=500_000), link_json()])
        snapshot = configure_can0(runner=runner, lock_path=None)
        self.assertTrue(snapshot.ready)
        ip_path = runner.calls[0][0]
        mutations = [call for call in runner.calls if call[0:2] == (ip_path, "link")]
        self.assertEqual(
            mutations,
            [
                (ip_path, "link", "set", "can0", "down"),
                (
                    ip_path,
                    "link",
                    "set",
                    "can0",
                    "type",
                    "can",
                    "bitrate",
                    "250000",
                    "restart-ms",
                    "100",
                ),
                (ip_path, "link", "set", "can0", "txqueuelen", "1000"),
                (ip_path, "link", "set", "can0", "up"),
            ],
        )
        self.assertFalse(any("add" in call for call in runner.calls))

    def test_force_cycles_an_already_ready_interface(self) -> None:
        runner = SequenceRunner([link_json(), link_json()])
        snapshot = configure_can0(runner=runner, lock_path=None, force=True)
        self.assertTrue(snapshot.ready)
        ip_path = runner.calls[0][0]
        mutations = [call for call in runner.calls if call[0:2] == (ip_path, "link")]
        self.assertEqual(mutations[0], (ip_path, "link", "set", "can0", "down"))
        self.assertEqual(mutations[-1], (ip_path, "link", "set", "can0", "up"))

    def test_failure_preserves_original_down_state(self) -> None:
        ip_path = str(IP_PATH_CANDIDATES[0])
        configure = (
            ip_path,
            "link",
            "set",
            "can0",
            "type",
            "can",
            "bitrate",
            "250000",
            "restart-ms",
            "100",
        )
        runner = SequenceRunner([link_json(up=False)], {configure: "device busy"})
        with self.assertRaisesRegex(Can0SetupError, "device busy"):
            configure_can0(runner=runner, lock_path=None)
        self.assertEqual(runner.calls[-1], configure)

    def test_failure_restores_original_up_state(self) -> None:
        ip_path = str(IP_PATH_CANDIDATES[0])
        configure = (
            ip_path,
            "link",
            "set",
            "can0",
            "type",
            "can",
            "bitrate",
            "250000",
            "restart-ms",
            "100",
        )
        runner = SequenceRunner([link_json(up=True, bitrate=500_000)], {configure: "device busy"})
        with self.assertRaisesRegex(Can0SetupError, "device busy"):
            configure_can0(runner=runner, lock_path=None)
        self.assertEqual(runner.calls[-1], (ip_path, "link", "set", "can0", "up"))

    def test_subprocess_environment_is_fixed(self) -> None:
        observed: dict[str, object] = {}

        def runner(command, **kwargs):
            observed.update(kwargs)
            return SimpleNamespace(returncode=0, stdout=link_json(), stderr="")

        self.assertTrue(inspect_can0(runner=runner).ready)
        self.assertEqual(observed["env"], MINIMAL_COMMAND_ENV)

    def test_post_verification_failure_is_stable(self) -> None:
        runner = SequenceRunner(
            [link_json(up=False, bitrate=500_000), link_json(up=True, bitrate=500_000)]
        )
        with self.assertRaises(Can0SetupError) as ctx:
            configure_can0(runner=runner, lock_path=None)
        self.assertEqual(ctx.exception.code, "CAN0_NOT_READY")

    def test_configure_uses_the_requested_exclusive_lock(self) -> None:
        runner = SequenceRunner([link_json()])
        lock_path = Path("/run/test-can0/can0.lock")
        with patch("can0_setup._exclusive_setup_lock") as setup_lock:
            configure_can0(runner=runner, lock_path=lock_path)
        setup_lock.assert_called_once_with(lock_path, lock_ops=None)

    def test_wrong_kind_is_rejected_without_mutation(self) -> None:
        runner = SequenceRunner([link_json(kind="vcan")])
        with self.assertRaisesRegex(Can0SetupError, "not a driver-created CAN"):
            configure_can0(runner=runner, lock_path=None)
        self.assertEqual(len(runner.calls), 1)


class Can0SecureLockTest(unittest.TestCase):
    def test_fixed_lock_is_inside_root_only_runtime_directory(self) -> None:
        self.assertEqual(CAN0_LOCK_PATH, Path("/run/excavatorsim/can0.lock"))

    def test_safe_metadata_is_accepted(self) -> None:
        _validate_runtime_root(fake_stat(stat.S_IFDIR | 0o755))
        _validate_lock_directory(fake_stat(stat.S_IFDIR | 0o700))
        _validate_lock_file(fake_stat(stat.S_IFREG | 0o600))

    def test_unsafe_runtime_metadata_is_rejected(self) -> None:
        cases = (
            fake_stat(stat.S_IFREG | 0o755),
            fake_stat(stat.S_IFDIR | 0o755, uid=1000),
            fake_stat(stat.S_IFDIR | 0o777),
        )
        for metadata in cases:
            with self.subTest(metadata=metadata), self.assertRaises(Can0SetupError) as ctx:
                _validate_runtime_root(metadata)
            self.assertEqual(ctx.exception.code, "CAN0_SETUP_FAILED")

    def test_wrong_directory_owner_or_mode_is_rejected(self) -> None:
        cases = (
            fake_stat(stat.S_IFDIR | 0o700, uid=1000),
            fake_stat(stat.S_IFDIR | 0o750),
            fake_stat(stat.S_IFREG | 0o700),
        )
        for metadata in cases:
            with self.subTest(metadata=metadata), self.assertRaises(Can0SetupError) as ctx:
                _validate_lock_directory(metadata)
            self.assertEqual(ctx.exception.code, "CAN0_SETUP_FAILED")

    def test_preoccupied_or_unsafe_lock_object_is_rejected(self) -> None:
        cases = (
            fake_stat(stat.S_IFREG | 0o600, uid=1000),
            fake_stat(stat.S_IFREG | 0o660),
            fake_stat(stat.S_IFIFO | 0o600),
            fake_stat(stat.S_IFREG | 0o600, nlink=2),
        )
        for metadata in cases:
            runner = SequenceRunner([])
            with self.subTest(metadata=metadata), self.assertRaises(Can0SetupError) as ctx:
                configure_can0(
                    runner=runner,
                    lock_path=TEST_LOCK_PATH,
                    lock_ops=make_lock_ops(lock_metadata=metadata),
                )
            self.assertEqual(ctx.exception.code, "CAN0_SETUP_FAILED")
            self.assertEqual(runner.calls, [])

    def test_lock_syscall_failures_are_stable_and_sanitized(self) -> None:
        for phase in (
            "open_10",
            "fstat_10",
            "mkdir",
            "open_11",
            "fstat_11",
            "open_12",
            "fstat_12",
            "flock",
        ):
            runner = SequenceRunner([])
            with self.subTest(phase=phase), self.assertRaises(Can0SetupError) as ctx:
                configure_can0(
                    runner=runner,
                    lock_path=TEST_LOCK_PATH,
                    lock_ops=make_lock_ops(fail_phase=phase),
                )
            self.assertEqual(ctx.exception.code, "CAN0_SETUP_FAILED")
            self.assertNotIn("attacker-controlled", str(ctx.exception))
            self.assertEqual(runner.calls, [])

    def test_injected_lock_serializes_complete_transactions(self) -> None:
        mutex = threading.Lock()
        fd_lock = threading.Lock()
        next_fd = 20
        roles: dict[int, str] = {}

        def open_fd(path, flags, mode=0o777, *, dir_fd=None):
            nonlocal next_fd
            with fd_lock:
                fd = next_fd
                next_fd += 1
                if str(path) == "can0.lock":
                    roles[fd] = "lock"
                elif str(path) == "excavatorsim":
                    roles[fd] = "child"
                else:
                    roles[fd] = "runtime"
                return fd

        def fstat(fd):
            role = roles[fd]
            if role == "lock":
                return fake_stat(stat.S_IFREG | 0o600)
            return fake_stat(stat.S_IFDIR | (0o700 if role == "child" else 0o755))

        def flock(fd, operation):
            mutex.acquire()

        def close_fd(fd):
            if roles[fd] == "lock":
                mutex.release()

        ops = Can0LockOps(open_fd, lambda *a, **k: None, fstat, flock, close_fd, 1)
        first_entered = threading.Event()
        allow_first_exit = threading.Event()
        second_entered = threading.Event()
        entry_count = 0
        entry_guard = threading.Lock()

        def runner(command, **kwargs):
            nonlocal entry_count
            with entry_guard:
                entry_count += 1
                current = entry_count
            if current == 1:
                first_entered.set()
                self.assertTrue(allow_first_exit.wait(2.0))
            else:
                second_entered.set()
            return SimpleNamespace(returncode=0, stdout=link_json(), stderr="")

        failures: list[BaseException] = []

        def run_configure():
            try:
                configure_can0(runner=runner, lock_path=TEST_LOCK_PATH, lock_ops=ops)
            except BaseException as exc:  # pragma: no cover - surfaced by assertion below
                failures.append(exc)

        first = threading.Thread(target=run_configure)
        second = threading.Thread(target=run_configure)
        first.start()
        self.assertTrue(first_entered.wait(2.0))
        second.start()
        self.assertFalse(second_entered.wait(0.1))
        allow_first_exit.set()
        first.join(2.0)
        second.join(2.0)
        self.assertTrue(second_entered.is_set())
        self.assertFalse(first.is_alive())
        self.assertFalse(second.is_alive())
        self.assertEqual(failures, [])

    @unittest.skipUnless(
        os.name == "posix" and hasattr(os, "geteuid") and os.geteuid() == 0,
        "root Linux only",
    )
    def test_real_flock_blocks_a_second_holder(self) -> None:
        with tempfile.TemporaryDirectory(dir="/run") as tmp:
            runtime_dir = Path(tmp)
            runtime_dir.chmod(0o700)
            lock_path = runtime_dir / "excavatorsim" / "can0.lock"
            first_entered = threading.Event()
            release_first = threading.Event()
            second_entered = threading.Event()

            def hold_first():
                with _exclusive_setup_lock(lock_path):
                    first_entered.set()
                    release_first.wait(2.0)

            def hold_second():
                with _exclusive_setup_lock(lock_path):
                    second_entered.set()

            first = threading.Thread(target=hold_first)
            second = threading.Thread(target=hold_second)
            first.start()
            self.assertTrue(first_entered.wait(2.0))
            second.start()
            self.assertFalse(second_entered.wait(0.1))
            release_first.set()
            first.join(2.0)
            second.join(2.0)
            self.assertTrue(second_entered.is_set())


class GatewayPreparationTest(unittest.TestCase):
    def test_ready_interface_skips_sudo_and_helper(self) -> None:
        runner = SequenceRunner([link_json()])
        snapshot = prepare_can0(runner=runner, helper_path=Path("missing"), which=lambda _: None)
        self.assertTrue(snapshot.ready)
        self.assertEqual(len(runner.calls), 1)

    def test_unready_interface_requires_installed_helper(self) -> None:
        runner = SequenceRunner([link_json(up=False)])
        with self.assertRaisesRegex(Can0SetupError, "install_can0_helper"):
            prepare_can0(runner=runner, helper_path=CAN0_HELPER_PATH)

    def test_helper_is_fixed_noninteractive_command_then_reverified(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "helper"
            helper.write_bytes(b"ELF")
            runner = SequenceRunner([link_json(up=False), link_json()])
            snapshot = prepare_can0(
                runner=runner,
                helper_path=helper,
                which=lambda name: "/usr/bin/sudo" if name == "sudo" else None,
            )
        self.assertTrue(snapshot.ready)
        self.assertIn(("/usr/bin/sudo", "-n", str(helper)), runner.calls)

    def test_privilege_failure_is_stable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "helper"
            helper.write_bytes(b"ELF")
            sudo_call = ("sudo", "-n", str(helper))
            runner = SequenceRunner([link_json(up=False)], {sudo_call: "a password is required"})
            with self.assertRaises(Can0SetupError) as ctx:
                prepare_can0(runner=runner, helper_path=helper, which=lambda _: "sudo")
        self.assertEqual(ctx.exception.code, "CAN0_PRIVILEGE")

    def test_helper_setup_failure_is_stable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "helper"
            helper.write_bytes(b"ELF")
            sudo_call = ("sudo", "-n", str(helper))
            runner = SequenceRunner(
                [link_json(up=False)],
                {sudo_call: "CAN0_SETUP_FAILED: device busy"},
            )
            with self.assertRaises(Can0SetupError) as ctx:
                prepare_can0(runner=runner, helper_path=helper, which=lambda _: "sudo")
        self.assertEqual(ctx.exception.code, "CAN0_SETUP_FAILED")

    def test_explicit_restart_invokes_helper_even_when_ready(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            helper = Path(tmp) / "helper"
            helper.write_bytes(b"ELF")
            runner = SequenceRunner([link_json(), link_json()])
            snapshot = restart_can0(
                runner=runner,
                helper_path=helper,
                which=lambda name: "/usr/bin/sudo" if name == "sudo" else None,
            )
        self.assertTrue(snapshot.ready)
        self.assertIn(("/usr/bin/sudo", "-n", str(helper)), runner.calls)

    def test_helper_rejects_arguments(self) -> None:
        self.assertEqual(helper_main(["can1"]), 64)

    def test_helper_lock_failure_is_one_stable_line_without_traceback(self) -> None:
        stderr = StringIO()
        error = Can0SetupError("CAN0_SETUP_FAILED", "can0 lock object unavailable")
        with patch("can0_setup_helper.configure_can0", side_effect=error), redirect_stderr(stderr):
            self.assertEqual(helper_main([]), 1)
        output = stderr.getvalue()
        self.assertEqual(output, "CAN0_SETUP_FAILED: can0 lock object unavailable\n")
        self.assertNotIn("Traceback", output)


if __name__ == "__main__":
    unittest.main()
