"""Enforce runtime texture budgets, including images extracted from GLB imports."""
from pathlib import Path
import argparse
import json
import re

PROJECT = Path(__file__).resolve().parents[1] / "godot/worldbuilding/construction"


def prepare(project: Path, check: bool = False) -> dict:
    changed = []
    count = 0
    for path in sorted((project / "maps/construction").rglob("*.import")):
        text = path.read_text(encoding="utf-8")
        if 'importer="texture"' not in text:
            continue
        count += 1
        # Decal textures share a renderer atlas, so individually valid 8K
        # images can still produce an atlas beyond the device dimension limit.
        decal = "/Textures/Decals/" in path.as_posix()
        match = re.search(r"^process/size_limit=(\d+)$", text, re.M)
        previous = int(match[1]) if match else 0
        limit = min(previous, 1024) if decal and previous else previous or 1024
        updated = text
        for key, value in (("process/size_limit", str(limit)),
                           ("compress/mode", "2"), ("mipmaps/generate", "true")):
            pattern = rf"^{re.escape(key)}=.*$"
            if re.search(pattern, updated, re.M):
                updated = re.sub(pattern, f"{key}={value}", updated, flags=re.M)
            else:
                updated = updated.replace("[params]", f"[params]\n{key}={value}", 1)
        if updated != text:
            changed.append(path.relative_to(project).as_posix())
            if not check:
                path.write_text(updated, encoding="utf-8", newline="\n")
    return {"textures": count, "changed": len(changed), "paths": changed}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = prepare(PROJECT, args.check)
    print(json.dumps({k: v for k, v in result.items() if k != "paths"}))
    if args.check and result["changed"]:
        raise SystemExit("Texture imports exceed the construction map budget; rebuild without -SkipImport")


if __name__ == "__main__":
    main()
