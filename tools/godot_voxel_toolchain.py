"""Resolve, verify, and stage the pinned Godot + Voxel Tools toolchain."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from collections.abc import Mapping, Sequence
from pathlib import Path
from typing import Any

TOOLS_DIR = Path(__file__).resolve().parent
DEFAULT_LOCK_PATH = TOOLS_DIR / "godot_voxel_toolchain.json"
ROOT_ENVIRONMENT_VARIABLE = "GODOT_VOXEL_ROOT"
COMPONENTS = (
    "windows_editor",
    "windows_release_template",
    "linux_editor",
    "linux_release_template",
)
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_DISALLOWED_VARIANT_RE = re.compile(r"(?:^|[._-])(double|tracy)(?:[._-]|$)", re.IGNORECASE)
_PRESET_SECTION_RE = re.compile(r"^\[preset\.(\d+)\]$")
_PRESET_OPTIONS_RE = re.compile(r"^\[preset\.(\d+)\.options\]$")
_RELEASE_FIELDS = (
    "url",
    "download_base_url",
    "tag",
    "release_commit",
    "voxel_tools_version",
    "godot_version",
    "engine_commit",
)
_ASSET_FIELDS = {
    "filename",
    "archive_filename",
    "archive_sha256",
    "binary_sha256",
    "binary_size_bytes",
    "platform",
    "kind",
    "variant",
}


class ToolchainError(RuntimeError):
    """Raised when the pinned toolchain cannot be resolved safely."""


def _fail(code: str, detail: str) -> ToolchainError:
    return ToolchainError(f"GODOT_VOXEL_TOOLCHAIN_FAILED[{code}]: {detail}")


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _object_pairs_no_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise _fail("LOCK_INVALID", f"duplicate key in lock: {key}")
        result[key] = value
    return result


def load_lock(path: Path = DEFAULT_LOCK_PATH) -> dict[str, Any]:
    try:
        payload = json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=_object_pairs_no_duplicates,
            parse_constant=lambda value: (_ for _ in ()).throw(
                _fail("LOCK_INVALID", f"non-finite JSON constant: {value}")
            ),
        )
    except ToolchainError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise _fail("LOCK_INVALID", f"unable to read {path}: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("schema_version") != 1:
        raise _fail("LOCK_INVALID", "schema_version must be 1")
    release = payload.get("release")
    assets = payload.get("assets")
    if not isinstance(release, dict) or not isinstance(assets, dict):
        raise _fail("LOCK_INVALID", "release and assets must be objects")
    if set(assets) != set(COMPONENTS):
        raise _fail("LOCK_INVALID", f"assets must contain exactly {COMPONENTS}")
    for field in _RELEASE_FIELDS:
        value = release.get(field)
        if not isinstance(value, str) or not value:
            raise _fail("LOCK_INVALID", f"release.{field} must be a non-empty string")
    for component in COMPONENTS:
        asset = assets[component]
        if not isinstance(asset, dict):
            raise _fail("LOCK_INVALID", f"asset {component} must be an object")
        if set(asset) != _ASSET_FIELDS:
            raise _fail(
                "LOCK_INVALID", f"asset {component} fields must be exactly {_ASSET_FIELDS}"
            )
        for field in ("binary_sha256", "archive_sha256"):
            value = asset.get(field)
            if not isinstance(value, str) or not _SHA256_RE.fullmatch(value):
                raise _fail("LOCK_INVALID", f"asset {component}.{field} is invalid")
        filename = asset.get("filename")
        if not isinstance(filename, str) or Path(filename).name != filename:
            raise _fail("LOCK_INVALID", f"asset {component}.filename is invalid")
        archive_filename = asset.get("archive_filename")
        if (
            not isinstance(archive_filename, str)
            or Path(archive_filename).name != archive_filename
        ):
            raise _fail("LOCK_INVALID", f"asset {component}.archive_filename is invalid")
        size = asset.get("binary_size_bytes")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            raise _fail("LOCK_INVALID", f"asset {component}.binary_size_bytes is invalid")
        expected_platform = "windows" if component.startswith("windows_") else "linux"
        expected_kind = "editor" if component.endswith("_editor") else "release_template"
        if asset.get("platform") != expected_platform or asset.get("kind") != expected_kind:
            raise _fail("LOCK_INVALID", f"asset {component} platform/kind is invalid")
        if asset.get("variant") != "standard" or _DISALLOWED_VARIANT_RE.search(filename):
            raise _fail("LOCK_INVALID", f"asset {component} is not the standard variant")
    return payload


def resolve_root(
    lock: Mapping[str, Any],
    explicit_root: Path | None = None,
    *,
    environment: Mapping[str, str] = os.environ,
) -> Path:
    if explicit_root is not None:
        selected = explicit_root
    elif environment.get(ROOT_ENVIRONMENT_VARIABLE):
        selected = Path(environment[ROOT_ENVIRONMENT_VARIABLE])
    else:
        default_root = lock.get("default_root")
        if not isinstance(default_root, str) or not default_root:
            raise _fail("LOCK_INVALID", "default_root must be a non-empty string")
        selected = Path(default_root)
    return selected.expanduser().resolve()


def resolve_component_path(
    lock: Mapping[str, Any],
    component: str,
    *,
    root: Path,
    explicit_path: Path | None = None,
) -> Path:
    if component not in COMPONENTS:
        raise _fail("COMPONENT_UNKNOWN", f"unknown component: {component}")
    if explicit_path is not None:
        return explicit_path.expanduser().resolve()
    asset = lock["assets"][component]
    return (root / str(asset["filename"])).resolve()


def _linux_version_command(path: Path) -> list[str]:
    if os.name != "nt":
        return [str(path), "--version"]
    script = (
        'binary_path="$(wslpath -a "$1")" && '
        '{ test -x "$binary_path" || chmod u+x "$binary_path"; } && '
        'exec "$binary_path" --version'
    )
    return ["wsl.exe", "--exec", "sh", "-c", script, "sh", str(path)]


def _read_version(path: Path, platform: str) -> str:
    command = (
        _linux_version_command(path)
        if platform == "linux"
        else [str(path), "--version"]
    )
    try:
        result = subprocess.run(
            command,
            capture_output=True,
            text=True,
            encoding="utf-8",
            errors="replace",
            check=False,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise _fail("VERSION_UNAVAILABLE", f"unable to run {path}: {exc}") from exc
    output = "\n".join(part for part in (result.stdout, result.stderr) if part).strip()
    if result.returncode != 0:
        raise _fail(
            "VERSION_UNAVAILABLE",
            f"{path.name} --version exited {result.returncode}: {output or 'no output'}",
        )
    for line in output.splitlines():
        value = line.strip()
        if value:
            return value
    raise _fail("VERSION_UNAVAILABLE", f"{path.name} --version returned no output")


def verify_component(
    lock: Mapping[str, Any],
    component: str,
    *,
    root: Path,
    explicit_path: Path | None = None,
    check_version: bool = True,
) -> dict[str, Any]:
    asset = lock["assets"].get(component)
    if not isinstance(asset, dict):
        raise _fail("COMPONENT_UNKNOWN", f"unknown component: {component}")
    path = resolve_component_path(
        lock, component, root=root, explicit_path=explicit_path
    )
    if _DISALLOWED_VARIANT_RE.search(path.name):
        raise _fail("VARIANT_REJECTED", f"double/tracy binary is not allowed: {path.name}")
    if not path.is_file():
        archive_name = str(asset["archive_filename"])
        download_url = f"{lock['release']['download_base_url']}/{archive_name}"
        raise _fail(
            "COMPONENT_MISSING",
            f"missing {component}: {path}; download {download_url}",
        )
    actual_size = path.stat().st_size
    expected_size = int(asset["binary_size_bytes"])
    if actual_size != expected_size:
        raise _fail(
            "SIZE_MISMATCH",
            f"{component} expected {expected_size} bytes, got {actual_size}: {path}",
        )
    actual_hash = sha256_file(path)
    expected_hash = str(asset["binary_sha256"])
    if actual_hash != expected_hash:
        raise _fail(
            "HASH_MISMATCH",
            f"{component} expected {expected_hash}, got {actual_hash}: {path}",
        )
    version = str(lock["release"]["godot_version"])
    if check_version:
        version = _read_version(path, str(asset["platform"]))
        expected_version = str(lock["release"]["godot_version"])
        if version != expected_version:
            raise _fail(
                "VERSION_MISMATCH",
                f"{component} expected {expected_version}, got {version!r}",
            )
    return {
        "component": component,
        "path": str(path),
        "filename": path.name,
        "archive_filename": asset["archive_filename"],
        "archive_sha256": asset["archive_sha256"],
        "binary_sha256": actual_hash,
        "binary_size_bytes": actual_size,
        "platform": asset["platform"],
        "kind": asset["kind"],
        "variant": asset["variant"],
        "version": version,
    }


def verify_toolchain(
    lock: Mapping[str, Any],
    *,
    root: Path,
    components: Sequence[str] = COMPONENTS,
    explicit_paths: Mapping[str, Path] | None = None,
    check_version: bool = True,
) -> dict[str, Any]:
    explicit_paths = explicit_paths or {}
    verified = {
        component: verify_component(
            lock,
            component,
            root=root,
            explicit_path=explicit_paths.get(component),
            check_version=check_version,
        )
        for component in components
    }
    release = dict(lock["release"])
    return {
        "schema_version": 1,
        "root": str(root),
        "release": release,
        "components": verified,
    }


def build_toolchain_provenance(
    verified: Mapping[str, Any], components: Sequence[str]
) -> dict[str, Any]:
    release = verified["release"]
    component_payload = verified["components"]
    return {
        "release_url": release["url"],
        "tag": release["tag"],
        "release_commit": release["release_commit"],
        "voxel_tools_version": release["voxel_tools_version"],
        "godot_version": release["godot_version"],
        "engine_commit": release["engine_commit"],
        "components": [
            {
                "component": component,
                "filename": component_payload[component]["filename"],
                "binary_sha256": component_payload[component]["binary_sha256"],
                "binary_size_bytes": component_payload[component]["binary_size_bytes"],
                "archive_filename": component_payload[component]["archive_filename"],
                "archive_sha256": component_payload[component]["archive_sha256"],
            }
            for component in components
        ],
    }


def _preset_names(lines: Sequence[str]) -> dict[str, str]:
    names: dict[str, str] = {}
    current: str | None = None
    for line in lines:
        section = _PRESET_SECTION_RE.fullmatch(line.strip())
        if section:
            current = section.group(1)
            continue
        if line.startswith("["):
            current = None
            continue
        if current is not None and line.startswith("name="):
            try:
                name = json.loads(line.partition("=")[2])
            except json.JSONDecodeError as exc:
                raise _fail("PRESET_INVALID", f"invalid preset name: {line}") from exc
            if isinstance(name, str):
                names[current] = name
    return names


def inject_release_templates(
    preset_path: Path, windows_template: Path, linux_template: Path
) -> None:
    try:
        original = preset_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise _fail("PRESET_INVALID", f"unable to read {preset_path}: {exc}") from exc
    newline = "\r\n" if "\r\n" in original else "\n"
    lines = original.splitlines()
    names = _preset_names(lines)
    replacements = {
        "ExcavatorSim": windows_template.resolve().as_posix(),
        "Linux": linux_template.resolve().as_posix(),
    }
    seen_release: set[str] = set()
    seen_debug: set[str] = set()
    current_name: str | None = None
    for index, line in enumerate(lines):
        section = _PRESET_OPTIONS_RE.fullmatch(line.strip())
        if section:
            current_name = names.get(section.group(1))
            continue
        if line.startswith("["):
            current_name = None
            continue
        if current_name not in replacements:
            continue
        if line.startswith("custom_template/debug="):
            lines[index] = 'custom_template/debug=""'
            seen_debug.add(current_name)
        elif line.startswith("custom_template/release="):
            lines[index] = "custom_template/release=" + json.dumps(
                replacements[current_name], ensure_ascii=False
            )
            seen_release.add(current_name)
    expected = set(replacements)
    if seen_release != expected or seen_debug != expected:
        raise _fail(
            "PRESET_INVALID",
            "Windows/Linux presets must each define release and debug custom templates",
        )
    preset_path.write_text(newline.join(lines) + newline, encoding="utf-8", newline="")


def stage_export_project(
    source_project: Path,
    destination_project: Path,
    windows_template: Path,
    linux_template: Path,
) -> Path:
    source = source_project.resolve()
    destination = destination_project.resolve()
    if not (source / "project.godot").is_file():
        raise _fail("PROJECT_INVALID", f"project.godot is missing under {source}")
    if destination.exists():
        raise _fail("PROJECT_INVALID", f"staging destination already exists: {destination}")
    for path in source.rglob("*"):
        if path.is_symlink():
            raise _fail("PROJECT_INVALID", f"source project contains a symlink: {path}")
    try:
        shutil.copytree(
            source,
            destination,
            ignore=shutil.ignore_patterns(".godot", "output", "dist", "__pycache__"),
        )
        inject_release_templates(
            destination / "export_presets.cfg", windows_template, linux_template
        )
    except ToolchainError:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    except (OSError, shutil.Error) as exc:
        shutil.rmtree(destination, ignore_errors=True)
        raise _fail("STAGE_FAILED", f"unable to stage project: {exc}") from exc
    return destination


def _write_json(payload: Mapping[str, Any], output: Path | None) -> None:
    content = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    if output is None:
        sys.stdout.write(content)
        return
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8")


def _add_resolution_arguments(parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--lock", type=Path, default=DEFAULT_LOCK_PATH)
    parser.add_argument("--root", type=Path)
    parser.add_argument("--godot-exe", type=Path)
    parser.add_argument("--output", type=Path)


def parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    verify_parser = subparsers.add_parser("verify")
    _add_resolution_arguments(verify_parser)
    verify_parser.add_argument("--component", action="append", choices=COMPONENTS)
    stage_parser = subparsers.add_parser("stage-project")
    _add_resolution_arguments(stage_parser)
    stage_parser.add_argument("--source", required=True, type=Path)
    stage_parser.add_argument("--destination", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = parse_args(argv)
    try:
        lock = load_lock(args.lock)
        root = resolve_root(lock, args.root)
        explicit_paths = (
            {"windows_editor": args.godot_exe} if args.godot_exe is not None else {}
        )
        components = tuple(getattr(args, "component", None) or COMPONENTS)
        verified = verify_toolchain(
            lock,
            root=root,
            components=components,
            explicit_paths=explicit_paths,
            check_version=True,
        )
        if args.command == "stage-project":
            component_payload = verified["components"]
            stage_export_project(
                args.source,
                args.destination,
                Path(component_payload["windows_release_template"]["path"]),
                Path(component_payload["linux_release_template"]["path"]),
            )
            verified["staged_project"] = str(args.destination.resolve())
        verified["build_toolchain"] = build_toolchain_provenance(verified, components)
        _write_json(verified, args.output)
    except ToolchainError as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
