# Backend Quality Guidelines

## Required checks

Run `pixi run verify`, which executes Ruff, strict mypy, the backend pytest suite, provenance validation, and standalone-path validation. Keep documentation and protocol schemas in English.

## Determinism and immutability

Terrain edits must be deterministic for identical baseline, input, and sample sequence. Preserve Float32 array semantics, stable/loose layer digests, event equality, patch bytes, and volume conservation. Tests should compare bytes or full dataclass values where replay identity matters; do not assert only a rounded visual value.

## Forbidden patterns

- Do not use the browser, Godot renderer, or wall-clock scheduling as authority time.
- Do not add a second terrain state store in the client.
- Do not create one rigid body per sand grain.
- Do not import from `E:/projects/BabylonSim`, use sibling paths, symlinks, editable installs, or copied frontend build output.
- Keep active protocol/version identifiers aligned with the canonical
  `godot-pinocchio-*` family. Any future wire-name change must be an explicit,
  cross-layer, versioned protocol task; do not change it silently in one
  consumer.
- Do not broaden stale-port cleanup to terminate unverified processes.

## Tests

Add a focused regression beside the owning module. For cross-layer changes cover both the typed protocol boundary and the state transition. For worker/lifecycle changes prove reset, close, stale generation, and replay behavior. Use existing fixtures under `backend/tests/fixtures/` rather than creating alternate baselines.

## Generated asset provenance

Keep external byte-for-byte imports in `assets/provenance.json` under `entries`. Record assets
generated inside this repository under `generated_assets`, with a repository-relative generator,
all material input paths, and verified SHA-256 values. Use `hash_mode: raw` for binary inputs such
as GLB files; text inputs use CRLF-to-LF canonicalization. A regenerated frame fixture must identify
the active URDF, model implementation, dependency lock, model version, and Pinocchio version.

Run `pixi run verify-provenance` after changing an imported or generated asset, its generator, or
any recorded input. If a recorded generator input changes, rerun the generator even when the main
artifact bytes are expected to remain stable; evidence and provenance hashes still need to advance.
