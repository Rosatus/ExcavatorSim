# Backend Error Handling

## Typed domain errors

Use typed `ValueError` subclasses for input and protocol failures and include a stable machine-readable code. Examples are `ProtocolError`, `TerrainCommandError`, `TerrainHistoryError`, `RuntimeCommandError`, `PortCleanupError`, and `VisualAssetError`.

The transport catches these errors at the boundary and serializes an `error` message with the code, message, request ID when available, and recoverability. Do not leak Python tracebacks or filesystem paths to clients.

## Validation location

Validate untrusted JSON once in `protocol.py` before constructing dataclasses. Validate terrain specs before staging previews. Validate GLB bytes, schema, bounds, allowlisted filenames, and SHA-256 digests in `visual_assets.py` before serving or exposing assets.

## Failure semantics

- Invalid input is rejected without mutating authority state.
- Stale epoch/revision or replay selections return a recoverable error and leave the selected state unchanged.
- Worker shutdown cancels pending work and fails pending command futures with a stable shutdown code.
- Physics failure in a future Godot client is a diagnostic/degraded mode; it must not stop or mutate the Python authority.

Reference tests: `backend/tests/backend/test_protocol.py`, `test_terrain_controller.py`, `test_runtime.py`, `test_production.py`, and `test_visual_assets.py`.

