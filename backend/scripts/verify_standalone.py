"""Reject source-checkout and local-package dependencies in ExcavatorSim."""

from __future__ import annotations

import argparse
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
EXCLUDED_PARTS = {
    ".git",
    ".pixi",
    ".trellis",
    ".agents",
    ".codex",
    ".codegraph",
    "__pycache__",
}
SKIP_FILES = {"AGENTS.md"}
TEXT_SUFFIXES = {
    ".cjs",
    ".css",
    ".html",
    ".js",
    ".json",
    ".md",
    ".mjs",
    ".ps1",
    ".py",
    ".toml",
    ".ts",
    ".tsx",
    ".txt",
    ".urdf",
    ".yaml",
    ".yml",
}
FORBIDDEN_PATHS = (
    re.compile(r"(?i)[a-z]:[\\/]projects[\\/](?:KinematicSim|Babylon\.js)(?:[\\/]|$)"),
    re.compile(r"(?i)(?:^[\"'\s])\.\.[\\/](?:KinematicSim|Babylon\.js)(?:[\\/]|$)"),
)


def verify_paths() -> list[str]:
    errors: list[str] = []
    for path in ROOT.rglob("*"):
        relative = path.relative_to(ROOT)
        if relative.name in SKIP_FILES or any(part in EXCLUDED_PARTS for part in relative.parts):
            continue
        if path.is_symlink():
            errors.append(f"symbolic links are not allowed: {relative.as_posix()}")
            continue
        if not path.is_file() or path.suffix.lower() not in TEXT_SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for pattern in FORBIDDEN_PATHS:
            if pattern.search(text):
                errors.append(f"forbidden sibling-checkout path in {relative.as_posix()}")
                break
    return errors


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--paths-only",
        action="store_true",
        help="compatibility flag; path scan is the bootstrap check",
    )
    parser.parse_args()
    errors = verify_paths()
    if errors:
        for error in errors:
            print(f"ERROR: {error}")
        return 1
    print("Standalone path verification passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
