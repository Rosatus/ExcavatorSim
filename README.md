# ExcavatorSim

ExcavatorSim is the planned desktop excavator simulator built around a Godot Forward+ client and a Python authority migrated from BabylonSim.

## Current bootstrap state

This repository currently contains the Trellis/CodeGraph project foundation and migration plan. The Godot scene and client are intentionally deferred to a later implementation task.

The first architecture keeps Python authoritative for:

- Pinocchio excavator kinematics and input safety;
- deterministic terrain generation and layered stable/loose soil;
- bucket volume, excavation/deposition, replay, reset, seek, and lifecycle state;
- HTTP/WebSocket state and terrain contracts.

Godot will later own desktop rendering, GLB scene assembly, UI, visual terrain, particles, and optional local collision/contact presentation. Godot physics must not write authoritative transforms, terrain heights, bucket volume, or replay state back to Python in the first release.

## Repository map

- `.trellis/` — project knowledge and active implementation tasks.
- `.codegraph/` — CodeGraph index metadata.
- `backend/` — migrated Python authority (created during migration execution).
- `protocol/` — shared JSON schemas and version manifest.
- `assets/` — visual GLBs, calibration, provenance, and notices.
- `docs/` — migration and future Godot integration notes.
- `godot/` — reserved for the future Godot client.

## Development direction

1. Complete the reusable backend and asset migration.
2. Build a Godot visual vertical slice that consumes the existing protocol.
3. Add Godot terrain rendering and static collider synchronization.
4. Add bucket-load visuals and bounded soil presentation.
5. Evaluate Jolt/Godot Physics integration without changing Python authority.
6. Consider C++ only after profiling identifies a Python bottleneck.

See `.trellis/tasks/08-06-excavator-sim-bootstrap/` for the authoritative bootstrap requirements and execution plan.

