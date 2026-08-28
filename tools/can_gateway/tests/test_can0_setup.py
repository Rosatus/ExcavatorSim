"""Tests for fixed physical-can0 inspection and preparation."""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from can0_setup import (  # noqa: E402
    CAN0_HELPER_PATH,
    IP_PATH_CANDIDATES,
    MINIMAL_COMMAND_ENV,
    Can0SetupError,
    configure_can0,
    inspect_can0,
    prepare_can0,
    restart_can0,
)
from can0_setup_helper import main as helper_main  # noqa: E402


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
        lock_path = Path("/run/lock/test-can0.lock")
        with patch("can0_setup._exclusive_setup_lock") as setup_lock:
            configure_can0(runner=runner, lock_path=lock_path)
        setup_lock.assert_called_once_with(lock_path)

    def test_wrong_kind_is_rejected_without_mutation(self) -> None:
        runner = SequenceRunner([link_json(kind="vcan")])
        with self.assertRaisesRegex(Can0SetupError, "not a driver-created CAN"):
            configure_can0(runner=runner, lock_path=None)
        self.assertEqual(len(runner.calls), 1)


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


if __name__ == "__main__":
    unittest.main()
