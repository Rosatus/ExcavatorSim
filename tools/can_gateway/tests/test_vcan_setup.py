"""Tests for vcan_setup port. Run: python -m unittest discover -s tools/can_gateway/tests"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path
from types import SimpleNamespace

TOOLS_DIR = Path(__file__).resolve().parents[1]
if str(TOOLS_DIR) not in sys.path:
    sys.path.insert(0, str(TOOLS_DIR))

from vcan_setup import VcanSetupError, ensure_vcan_interface, require_vcan_interface  # noqa: E402


def make_runner(responses: dict[tuple, object] | None = None):
    """Runner stub: maps command tuples to returncode; default 0 for 'ip link show' miss=1."""

    def run(command, **kwargs):
        key = tuple(command)
        if responses and key in responses:
            value = responses[key]
            if isinstance(value, int):
                return SimpleNamespace(returncode=value, stdout="", stderr="")
            return value
        if command[:3] == ["ip", "link", "show"]:
            return SimpleNamespace(returncode=1, stdout="", stderr="")
        return SimpleNamespace(returncode=0, stdout="", stderr="")

    run.calls = []
    original = run

    def recording(command, **kwargs):
        recording.calls.append(tuple(command))
        return original(command, **kwargs)

    recording.calls = run.calls
    return recording


def link_output(flags: str) -> SimpleNamespace:
    return SimpleNamespace(returncode=0, stdout=f"5: vcan0: <{flags}> mtu 72 qdisc noop state UNKNOWN", stderr="")


def root_env():
    return {"geteuid": lambda: 0, "which": lambda name: "/usr/bin/" + name}


class RequireVcanInterfaceTest(unittest.TestCase):
    def test_existing_interface_passes(self):
        runner = make_runner({("ip", "link", "show", "dev", "vcan0"): link_output("NOARP")})
        require_vcan_interface("vcan0", runner=runner)

    def test_missing_interface_raises(self):
        runner = make_runner()
        with self.assertRaises(VcanSetupError) as ctx:
            require_vcan_interface("vcan0", runner=runner)
        self.assertIn("--setup-vcan", str(ctx.exception))


class EnsureVcanInterfaceTest(unittest.TestCase):
    def test_existing_up_is_noop(self):
        runner = make_runner({("ip", "link", "show", "dev", "vcan0"): link_output("UP,NOARP")})
        ensure_vcan_interface("vcan0", runner=runner, **root_env())
        commands = [c for c in runner.calls if c[0] == "sudo"]
        self.assertEqual(commands, [])

    def test_missing_creates_with_modprobe_and_up(self):
        # first 'ip link show' misses, subsequent calls (post-create check) succeed
        state = {"n": 0}

        def run(command, **kwargs):
            run.calls.append(tuple(command))
            if tuple(command) == ("ip", "link", "show", "dev", "vcan0"):
                state["n"] += 1
                if state["n"] == 1:
                    return SimpleNamespace(returncode=1, stdout="", stderr="")
                return link_output("UP,NOARP")
            return SimpleNamespace(returncode=0, stdout="", stderr="")

        run.calls = []
        ensure_vcan_interface("vcan0", runner=run, **root_env())
        joined = [" ".join(c) for c in run.calls]
        self.assertIn("modprobe vcan", joined)
        self.assertIn("ip link add dev vcan0 type vcan", joined)
        self.assertIn("ip link set dev vcan0 up", joined)

    def test_non_vcan_name_rejected(self):
        runner = make_runner()
        with self.assertRaises(VcanSetupError):
            ensure_vcan_interface("can0", runner=runner, **root_env())

    def test_no_sudo_raises(self):
        runner = make_runner()
        with self.assertRaises(VcanSetupError):
            ensure_vcan_interface(
                "vcan0",
                runner=runner,
                geteuid=lambda: 1000,
                which=lambda name: None,
            )

    def test_existing_down_vcan_brought_up(self):
        runner = make_runner({("ip", "link", "show", "dev", "vcan1"): link_output("NOARP")})
        ensure_vcan_interface("vcan1", runner=runner, geteuid=lambda: 0, which=lambda n: n)
        joined = [" ".join(c) for c in runner.calls]
        self.assertIn("ip link set dev vcan1 up", joined)


if __name__ == "__main__":
    unittest.main()
