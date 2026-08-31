"""Generate a deterministic provenance manifest for release artifacts.

The manifest is a build-time sidecar. It is never imported by the simulator or
Gateway runtime and deliberately excludes itself from the artifact hash list.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from collections.abc import Iterable, Mapping, Sequence
from datetime import UTC, datetime
from pathlib import Path
from uuid import uuid4

REPO_ROOT = Path(__file__).resolve().parents[1]
VERSION_MANIFEST = REPO_ROOT / "protocol" / "version-manifest.json"
_ARTIFACT_NAME_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*$")
_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")


class ManifestError(RuntimeError):
    """Raised when release provenance cannot be established safely."""


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def collect_artifact(
    name: str,
    root: Path,
    *,
    excluded_paths: Iterable[Path] = (),
) -> dict[str, object]:
    if not _ARTIFACT_NAME_RE.fullmatch(name):
        raise ManifestError(f"invalid artifact name: {name!r}")
    if root.is_symlink():
        raise ManifestError(f"artifact root must not be a symlink: {root}")
    resolved_root = root.resolve()
    if not resolved_root.is_dir():
        raise ManifestError(f"artifact root is not a directory: {root}")

    excluded = {path.resolve() for path in excluded_paths}
    files: list[dict[str, object]] = []
    for directory, directory_names, file_names in os.walk(
        resolved_root, followlinks=False
    ):
        directory_path = Path(directory)
        directory_names.sort()
        file_names.sort()
        for directory_name in directory_names:
            child = directory_path / directory_name
            if child.is_symlink():
                raise ManifestError(f"artifact tree contains a symlink: {child}")
        for file_name in file_names:
            path = directory_path / file_name
            if path.resolve() in excluded:
                continue
            if path.is_symlink():
                raise ManifestError(f"artifact tree contains a symlink: {path}")
            if not path.is_file():
                raise ManifestError(f"artifact tree contains a non-file: {path}")
            files.append(
                {
                    "path": path.relative_to(resolved_root).as_posix(),
                    "size_bytes": path.stat().st_size,
                    "sha256": sha256_file(path),
                }
            )
    files.sort(key=lambda item: str(item["path"]))
    if not files:
        raise ManifestError(f"artifact root is empty: {root}")
    return {
        "name": name,
        "root": ".",
        "files": files,
    }


def _run_git(repo_root: Path, arguments: Sequence[str]) -> str:
    result = subprocess.run(
        ["git", *arguments],
        cwd=repo_root,
        capture_output=True,
        text=True,
        encoding="utf-8",
        errors="replace",
        check=False,
    )
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "unknown git error"
        raise ManifestError(f"git {' '.join(arguments)} failed: {detail}")
    return result.stdout.strip()


def read_source(repo_root: Path = REPO_ROOT) -> dict[str, object]:
    commit = _run_git(repo_root, ["rev-parse", "--verify", "HEAD"]).lower()
    if not _COMMIT_RE.fullmatch(commit):
        raise ManifestError(f"git returned an invalid commit id: {commit!r}")
    status = _run_git(
        repo_root, ["status", "--porcelain=v1", "--untracked-files=normal"]
    )
    try:
        version_payload = json.loads(VERSION_MANIFEST.read_text(encoding="utf-8"))
        software_version = str(version_payload["software_version"])
    except (OSError, KeyError, TypeError, ValueError) as exc:
        raise ManifestError(f"unable to read software version: {exc}") from exc
    return {
        "git_commit": commit,
        "git_tree_dirty": bool(status),
        "software_version": software_version,
    }


def create_manifest(
    output_path: Path,
    artifact_specs: Sequence[tuple[str, Path]],
    *,
    repo_root: Path = REPO_ROOT,
    source: Mapping[str, object] | None = None,
    generated_at_utc: str | None = None,
) -> dict[str, object]:
    if not artifact_specs:
        raise ManifestError("at least one artifact root is required")
    names = [name for name, _ in artifact_specs]
    if len(names) != len(set(names)):
        raise ManifestError("artifact names must be unique")

    resolved_output = output_path.resolve()
    artifacts = [
        collect_artifact(
            name,
            root,
            excluded_paths=(resolved_output,),
        )
        for name, root in sorted(artifact_specs, key=lambda item: item[0])
    ]
    timestamp = generated_at_utc or datetime.now(UTC).isoformat(
        timespec="seconds"
    ).replace("+00:00", "Z")
    document: dict[str, object] = {
        "schema_version": 1,
        "generated_at_utc": timestamp,
        "source": dict(source) if source is not None else read_source(repo_root),
        "artifacts": artifacts,
    }

    output_path.parent.mkdir(parents=True, exist_ok=True)
    temporary = output_path.with_name(f".{output_path.name}.{uuid4().hex}.tmp")
    try:
        temporary.write_text(
            json.dumps(document, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        temporary.replace(output_path)
    finally:
        temporary.unlink(missing_ok=True)
    return document


def _parse_artifact(value: str) -> tuple[str, Path]:
    name, separator, path_text = value.partition("=")
    if not separator or not path_text:
        raise argparse.ArgumentTypeError("expected NAME=PATH")
    if not _ARTIFACT_NAME_RE.fullmatch(name):
        raise argparse.ArgumentTypeError(f"invalid artifact name: {name!r}")
    return name, Path(path_text)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument(
        "--artifact-root",
        action="append",
        required=True,
        type=_parse_artifact,
        metavar="NAME=PATH",
    )
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        document = create_manifest(args.output, args.artifact_root)
    except ManifestError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    file_count = sum(
        len(artifact["files"]) for artifact in document["artifacts"]  # type: ignore[index]
    )
    print(f"wrote: {args.output} ({file_count} files)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
