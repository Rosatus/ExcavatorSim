# Rename runtime protocol identifiers from BabylonSim to Godot/Pinocchio

## Goal

Replace active wire and serialized protocol identifiers that still expose the
historical BabylonSim product name with a neutral name describing the actual
authority boundary: Godot presentation client plus Pinocchio Python motion
authority.

## Background

- The current live contract uses `babylon-sim-*`, `babylon-sim/rrd-v1`,
  `X-BabylonSim-Session`, and `application/vnd.babylon-sim.*` identifiers.
- The backend Python package remains `babylon_sim` for source/provenance and
  import compatibility. This task is a protocol naming migration, not a
  package namespace rewrite.
- Motion semantics, JSON fields, schema shapes, coordinate conversion,
  deterministic authority, and model versions must not change.

## Requirements

1. Use `godot-pinocchio` as the active protocol family name:
   - `godot-pinocchio-v3`
   - `godot-pinocchio-state-v2`
   - `godot-pinocchio/rrd-v1`
   - `X-Godot-Pinocchio-Session`
   - `application/vnd.godot-pinocchio.terrain-f32le`
2. Rename the primary protocol schema file to
   `protocol/godot-pinocchio-v3.schema.json`; update all path owners and
   schema `$id`/references consistently.
3. Update backend, Godot, fixtures, smoke tests, schemas, and current API/
   transport documentation to use the new active identifiers.
4. Update the Trellis backend/frontend contract specs so future work treats
   the Godot/Pinocchio identifiers as canonical and does not reintroduce
   Babylon names in active contracts.
5. Keep historical migration/provenance/license references and the Python
   package name unless they are active wire identifiers.
6. Do not provide a silent dual-protocol fallback. A client or recording with
   an old active identifier should fail the existing version/profile validation
   rather than being accepted under the new name.

## Acceptance Criteria

- [x] `rg` finds no active `babylon-sim-*`, `babylon-sim/rrd-v1`,
  `X-BabylonSim-Session`, or `application/vnd.babylon-sim.*` references in
  protocol implementation, schemas, tests, fixtures, or current transport/API
  docs.
- [x] Backend hello/version validation, HTTP terrain/recording endpoints, and
  RRD metadata use the Godot/Pinocchio identifiers.
- [x] Godot hello payload and protocol constants exactly match the backend
  manifest and schemas.
- [x] Existing backend and Godot protocol tests pass with the new names,
  including rejection of mismatched versions.
- [x] `pixi run verify`, backend smoke, and the Godot standalone protocol tests
  pass.
- [x] No kinematic, terrain, replay, coordinate, or visual behavior changes
  are introduced.

## Out of Scope

- Renaming the `babylon_sim` Python package or its internal module paths.
- Rewriting historical migration inventory, source-rights, or license evidence
  that documents the origin of reused code/assets.
- Changing protocol fields, version numbers' semantic meaning, transport
  behavior, or compatibility policy beyond the identifier rename.

## Open Questions

None. The requested choice is resolved as the combined `godot-pinocchio`
family name because it names both sides of the live boundary.
