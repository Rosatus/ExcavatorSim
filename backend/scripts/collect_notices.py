"""Collect locked Python environment evidence for the ExcavatorSim backend."""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
LICENSE_ROOT = ROOT / "assets/licenses"
PIXI_LOCKFILE = ROOT / "pixi.lock"


def _canonical_text(content: bytes) -> bytes:
    return content.replace(b"\r\n", b"\n")


def _sha256(path: Path) -> str:
    return hashlib.sha256(_canonical_text(path.read_bytes())).hexdigest()


def _pixi_inventory() -> list[dict[str, object]]:
    pixi = shutil.which("pixi")
    if pixi is None:
        raise RuntimeError("pixi is required to inventory the locked Python environment")
    import subprocess

    result = subprocess.run(
        [pixi, "list", "--json"],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    packages = json.loads(result.stdout)
    if not isinstance(packages, list):
        raise RuntimeError("pixi list --json did not return a package array")
    fields = (
        "name",
        "version",
        "build",
        "kind",
        "source",
        "license",
        "license_family",
        "is_explicit",
        "sha256",
        "url",
    )
    return sorted(
        [
            {field: package.get(field) for field in fields}
            for package in packages
            if isinstance(package, dict)
        ],
        key=lambda package: (
            str(package.get("name", "")),
            str(package.get("version", "")),
            str(package.get("build", "")),
        ),
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    if not PIXI_LOCKFILE.is_file():
        raise RuntimeError("pixi.lock is required to collect backend notice evidence")
    evidence: dict[str, Any] = {
        "schema_version": 1,
        "generated_from": "pixi.lock",
        "pixi_lock_sha256": _sha256(PIXI_LOCKFILE),
        "packages": _pixi_inventory(),
        "retained_licenses": [
            "assets/licenses/KinematicSim-AGPL-3.0.txt",
            "assets/visual/original/SOURCE-RIGHTS.md",
        ],
    }
    destination = LICENSE_ROOT / "third-party-dependencies.json"
    content = (json.dumps(evidence, indent=2) + "\n").encode("utf-8")
    if args.check:
        if not destination.is_file() or _canonical_text(destination.read_bytes()) != content:
            relative = destination.relative_to(ROOT)
            raise RuntimeError(f"notice evidence is stale or missing: {relative}")
        action = "Verified"
    else:
        LICENSE_ROOT.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(_canonical_text(content))
        action = "Collected"
    package_count = len(evidence["packages"])
    print(f"{action} {package_count} locked Pixi packages and retained license evidence.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
