# Backend Directory Structure

## Ownership

```text
backend/
├── src/babylon_sim/       # authoritative Python package (legacy-compatible namespace)
├── tests/backend/         # pytest coverage and fixtures
└── scripts/               # verification, smoke, and benchmark tools
protocol/                  # JSON schemas and version manifest shared with Godot
assets/                   # URDF/calibration, visual GLBs, provenance, notices
```

`backend/src/babylon_sim/paths.py` is the single owner of repository resource paths. New modules should import path constants rather than reconstructing `Path(__file__)` chains.

## Module boundaries

- `model.py`, `calibration.py`, `control.py`, `simulation.py`, and `state.py` define kinematics and state types.
- `runtime.py` owns the fixed-rate loop, lifecycle command queue, latest-state publication, replay worker, and terrain controller composition.
- `terrain.py` owns deterministic source generation; `terrain_excavation.py` owns layered edits, volume accounting, repose relaxation, patches, and replayable events; `terrain_controller.py` owns session-bound previews and history.
- `protocol.py` owns JSON decoding, schema validation, version manifests, and message encoding. `web.py` is the transport boundary and should not duplicate protocol parsing.
- `visual_assets.py` owns GLB manifest, digest, bounds, and allowlist validation. It does not infer collision or mass properties.

## Naming and placement

Use one focused snake_case module per authority concern. Add tests under `backend/tests/backend/test_<module>.py`. Put one-off operational tooling under `backend/scripts/`, not in the package.

Reference examples: `backend/src/babylon_sim/runtime.py`, `terrain_excavation.py`, `protocol.py`, and `backend/tests/backend/test_terrain_excavation.py`.

