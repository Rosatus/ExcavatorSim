"""Fast contract tests for the Gateway-only distribution entry point."""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "tools" / "build_gateway_dist.ps1"
GATEWAY_TOOLS = REPO_ROOT / "tools" / "can_gateway"
if str(GATEWAY_TOOLS) not in sys.path:
    sys.path.insert(0, str(GATEWAY_TOOLS))

from build_exe import DEFAULT_DIST, parse_args  # noqa: E402
from smoke_frozen_gateway import parse_args as parse_smoke_args  # noqa: E402


def _plan(platform: str, *arguments: str) -> dict[str, object]:
    result = subprocess.run(
        [
            "pwsh",
            "-NoProfile",
            "-NonInteractive",
            "-File",
            str(SCRIPT),
            "-PlanOnly",
            "-Platform",
            platform,
            *arguments,
        ],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.returncode != 0:
        raise AssertionError(f"plan failed: {result.stdout}\n{result.stderr}")
    return json.loads(result.stdout)


class BuildGatewayDistPlanTest(unittest.TestCase):
    def test_all_builds_web_once_and_selects_both_packages(self) -> None:
        plan = _plan("all")
        self.assertEqual(plan["platforms"], ["windows", "linux"])
        self.assertEqual(plan["web_builds"], 1)
        self.assertEqual(plan["windows_output"], "dist/can_gateway")
        self.assertEqual(plan["linux_output"], "dist/can_gateway_linux")
        self.assertTrue(plan["manifests"])
        self.assertTrue(plan["packaged_smoke"])

    def test_platform_filter_and_smoke_switch_are_explicit(self) -> None:
        windows = _plan("windows", "-SkipSmoke")
        linux = _plan("linux")
        self.assertEqual(windows["platforms"], ["windows"])
        self.assertIsNone(windows["linux_output"])
        self.assertFalse(windows["packaged_smoke"])
        self.assertEqual(linux["platforms"], ["linux"])
        self.assertIsNone(linux["windows_output"])

    def test_invalid_platform_is_rejected_before_build(self) -> None:
        result = subprocess.run(
            [
                "pwsh",
                "-NoProfile",
                "-NonInteractive",
                "-File",
                str(SCRIPT),
                "-PlanOnly",
                "-Platform",
                "android",
            ],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ValidateSet", result.stderr)

    def test_multi_package_install_rolls_back_as_one_transaction(self) -> None:
        with tempfile.TemporaryDirectory(prefix="gateway-transaction-") as temp_dir:
            root = Path(temp_dir)
            first_target = root / "first"
            second_target = root / "second"
            first_stage = root / "stage-first"
            missing_second_stage = root / "stage-second-missing"
            for path, marker in (
                (first_target, "old-first"),
                (second_target, "old-second"),
                (first_stage, "new-first"),
            ):
                path.mkdir()
                (path / "marker.txt").write_text(marker, encoding="utf-8")

            environment = dict(os.environ)
            environment.update(
                {
                    "GATEWAY_SCRIPT": str(SCRIPT),
                    "TRANSACTION_ROOT": str(root),
                    "FIRST_STAGE": str(first_stage),
                    "MISSING_SECOND_STAGE": str(missing_second_stage),
                    "FIRST_TARGET": str(first_target),
                    "SECOND_TARGET": str(second_target),
                }
            )
            command = r"""
$ErrorActionPreference = 'Stop'
. $env:GATEWAY_SCRIPT -PlanOnly | Out-Null
$distRoot = $env:TRANSACTION_ROOT
$packages = @(
    @{ Staged = $env:FIRST_STAGE; Target = $env:FIRST_TARGET },
    @{ Staged = $env:MISSING_SECOND_STAGE; Target = $env:SECOND_TARGET }
)
try {
    Install-StagedPackages -Packages $packages
    exit 9
}
catch {
    exit 0
}
"""
            result = subprocess.run(
                ["pwsh", "-NoProfile", "-NonInteractive", "-Command", command],
                cwd=REPO_ROOT,
                env=environment,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
                check=False,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(
                (first_target / "marker.txt").read_text(encoding="utf-8"),
                "old-first",
            )
            self.assertEqual(
                (second_target / "marker.txt").read_text(encoding="utf-8"),
                "old-second",
            )


class PlatformBuilderArgumentTest(unittest.TestCase):
    def test_windows_builder_defaults_remain_compatible(self) -> None:
        arguments = parse_args([])
        self.assertFalse(arguments.skip_web_build)
        self.assertEqual(arguments.dist_dir, DEFAULT_DIST)

    def test_windows_builder_accepts_prebuilt_web_and_staging_output(self) -> None:
        arguments = parse_args(
            ["--skip-web-build", "--dist-dir", "staging/gateway-windows"]
        )
        self.assertTrue(arguments.skip_web_build)
        self.assertEqual(arguments.dist_dir, Path("staging/gateway-windows"))

    def test_frozen_smoke_requires_an_explicit_executable(self) -> None:
        arguments = parse_smoke_args(["dist/can_gateway/gateway.exe"])
        self.assertEqual(arguments.executable, Path("dist/can_gateway/gateway.exe"))


if __name__ == "__main__":
    unittest.main()
