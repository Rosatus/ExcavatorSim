# BabylonSim Migration Inventory

> **Historical reference (2026-08-13):** This is the original BabylonSim
> migration checklist, not a list of backend files still missing from the
> current repository. For the current architecture, read
> [`docs/architecture/engineering.md`](architecture/engineering.md) and the
> release/profile contracts first.

## Migrate into `backend/`

- `src/babylon_sim/calibration.py`
- `src/babylon_sim/constants.py`
- `src/babylon_sim/control.py`
- `src/babylon_sim/exchange.py`
- `src/babylon_sim/input_router.py`
- `src/babylon_sim/model.py`
- `src/babylon_sim/paths.py`
- `src/babylon_sim/production.py`
- `src/babylon_sim/protocol.py`
- `src/babylon_sim/recording.py`
- `src/babylon_sim/replay.py`
- `src/babylon_sim/replay_contract.py`
- `src/babylon_sim/rrd.py`
- `src/babylon_sim/runtime.py`
- `src/babylon_sim/series.py`
- `src/babylon_sim/simulation.py`
- `src/babylon_sim/state.py`
- `src/babylon_sim/terrain.py`
- `src/babylon_sim/terrain_controller.py`
- `src/babylon_sim/terrain_excavation.py`
- `src/babylon_sim/visual_assets.py`
- `src/babylon_sim/web.py`

Also migrate the backend tests, fixtures, protocol schemas, and backend-only verification scripts after paths and package metadata are established.

## Migrate as data and documentation

- `assets/visual/original/*.glb` and conversion/provenance files;
- `assets/calibration/` and `assets/provenance.json`;
- applicable license and notice files;
- `docs/terrain-api.md`, recording/RRD docs, visual model docs, and GLB export guidance;
- `protocol/*.schema.json` and `protocol/version-manifest.json`.

## Reference only / replace later

- `frontend/src/scene/**` — Babylon scene and terrain rendering;
- `frontend/src/protocol/**` — useful behavior reference, but Godot transport code will be rewritten;
- React components, Vite configuration, Playwright browser tests, and Babylon package metadata;
- Babylon Havok adapter work, until the Godot physics boundary is implemented.

## Explicitly deferred

- URDF/GLB collision proxy mapping;
- mass, inertia, hydraulic force, and production contact calibration;
- dynamic articulated rigid-body excavator authority;
- C++ rewrite or GDExtension optimization;
- per-grain granular soil simulation.
