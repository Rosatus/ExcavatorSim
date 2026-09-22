"""Check raw model provenance before export; runtime loads imported scenes."""

import hashlib
import json
from pathlib import Path

CLIENT = Path(__file__).resolve().parents[1] / "godot/client"


def verify(client: Path = CLIENT) -> list[str]:
    errors: list[str] = []

    def check(path: str, expected: str, owner: Path) -> None:
        if not path.startswith("res://"):
            errors.append(f"{owner}: invalid source path {path}")
            return
        source = (client / path.removeprefix("res://")).resolve()
        if not source.is_relative_to(client.resolve()) or not source.is_file():
            errors.append(f"{owner}: missing source asset {path}")
        elif hashlib.sha256(source.read_bytes()).hexdigest() != expected:
            errors.append(f"{owner}: source SHA-256 mismatch: {path}")

    # Read the same contracts as the runtime, including attachment soil sources.
    owners = [
        client / "resources/physics/wheeled_machine_profiles.json",
        client / "resources/models/attachment_catalog.json",
    ]
    owners.extend(sorted((client / "resources/attachments").glob("*.json")))
    owners.extend(sorted((client / "resources/models").glob("*_soil_contract.json")))
    for owner in owners:

        def walk(value: object, owner: Path = owner) -> None:
            if isinstance(value, dict):
                for prefix in ("asset", "rotator_glb", "tool_glb", "source_glb"):
                    path = value.get(prefix + "_path")
                    digest = value.get(prefix + "_sha256")
                    if isinstance(path, str) and path.endswith(".glb"):
                        if not isinstance(digest, str):
                            errors.append(f"{owner}: missing {prefix}_sha256")
                        else:
                            check(path, digest, owner)
                for child in value.values():
                    walk(child)
            elif isinstance(value, list):
                for child in value:
                    walk(child)

        walk(json.loads(owner.read_text(encoding="utf-8")))
    return errors


if __name__ == "__main__":
    failures = verify()
    for failure in failures:
        print(failure)
    if not failures:
        print("Model source asset hashes verified.")
    raise SystemExit(bool(failures))
