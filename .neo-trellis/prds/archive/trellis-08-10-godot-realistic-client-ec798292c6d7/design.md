# Technical Design

## Architecture

The first client uses a split authority:

```text
Godot input actions ── sequenced commands ──> Python Motion Service
Godot WorldState  <── pose/frame snapshots ─ Python Motion Service
        │
        ├── deterministic-enough seeded terrain and edits
        ├── bucket interaction and volume accounting
        ├── derived mesh/static collider
        └── visual presentation (GLB, PBR, camera, UI, soil FX)
```

Python is authoritative for four-joint kinematics, limits, acceleration, input lease/safety, lifecycle and named frame transforms. Godot is authoritative for the first-release world state and presentation outside motion. Godot physics is local presentation and must not write transforms back to Python.

## Incremental delivery boundary

The parent task is an integration program, not a single implementation batch. Implementation proceeds through eight ordered child milestones: Godot foundation, supplied-GLB adaptation, connected motion, motion-only backend, deterministic terrain, excavation gameplay, realistic visuals, and release-candidate integration. Each milestone has an executable exit gate and may be checked/committed independently. The delivered combined SY205 GLB is imported and mapped immediately after foundation so connected motion uses the real visual hierarchy; the placeholder remains the rollback path.

## Backend boundary

1. Preserve the existing wire identifiers and motion message shape.
2. Introduce a motion-only runtime/profile that does not require terrain, recording, or replay workers for a Godot client session.
3. Keep the existing terrain/replay implementation available during migration; do not delete it until the motion-only profile and Godot world pass integration checks.
4. Expose capabilities so the client can distinguish motion-only sessions from legacy terrain/replay sessions without a silent protocol rename.
5. Keep the Python fixed-rate loop and input sequence/lease safety unchanged.

## Godot modules

- `MotionClient`: WebSocket hello/ack, pose decoding, input sequence/ack, lifecycle commands, reconnect and connection status.
- `MotionGeneration`: accepts pose only when session/stream generation and sequence are current; interpolation is allowed only within one generation.
- `ExcavatorVisualSkin`: loads the five manifest assets, validates frame names and local calibration, and applies `T_world_visual = T_world_link * T_link_visual`.
- `WorldState`: seeded terrain grid, fixed-step edit queue, bucket intersection/volume state, reset and generation transitions.
- `TerrainRenderer`: converts WorldState to a derived mesh and optional chunked static collider; stale async work is discarded by generation.
- `SoilPresentation`: bounded clumps/particles/dust driven by local bucket/world state; disposable and never authoritative.
- `OperatorUI`: connection/authority status, start/pause/reset, keyboard/mouse and generic gamepad actions, input acknowledgements and diagnostics.

## Determinism contract

- Terrain initialization requires an explicit seed and versioned algorithm identifier.
- Terrain edits are ordered by a monotonic local command sequence and applied on a fixed simulation step, not wall-clock render cadence.
- Use a stable grid and documented numeric precision; acceptance is repeatability on the supported Windows/Godot runtime, not cross-platform bitwise identity.
- Mesh, normals, collider and soil effects are derived outputs and may be rebuilt after reset/reconnect without changing the underlying command result.

## GLB and coordinate handling

- Treat GLB authoring as user-owned and the delivered combined SY205 GLB as the Godot client's visual source.
- Keep five stable placeholder frame nodes as a rollback path while the combined GLB import and calibration are validated.
- Map the supplied root, slew, boom, arm and bucket pivot nodes to the stable protocol frame aliases and calibrate local TRS/scale/bounds/materials against the frame-parity fixture before M2.
- Keep collision meshes optional and separate from visual assets until the user supplies and approves their contract.

## Compatibility and migration

- The first Godot client can connect to the existing backend while the motion-only profile is introduced.
- Terrain/replay messages from a legacy session are ignored by the motion-only client, not reinterpreted.
- If the motion-only profile cannot be added without changing current tests, use an adapter layer and preserve the old runtime as a compatibility implementation.

## Human review gates

- Performance baseline is approved as 1920×1080 at a target 60 FPS on a modern Windows desktop.
- The delivered GLB exposes the five required pivot targets. Preserve its auxiliary linkage meshes as visual-only children unless a later human visual review finds a visible mechanical mismatch.
- Local terrain colliders are approved as Godot-owned presentation/gameplay support and must never feed authority transforms back to Python.
- Before replacing legacy backend terrain: review deterministic test results and confirm that no future motion model needs terrain feedback.

## Rollback

- Keep new Godot code under `godot/client/` and new motion-only backend code behind an opt-in profile.
- If terrain determinism or pose parity fails, disable the new world/skin layer and keep the tested Python service operational.
- Do not alter protocol version identifiers or remove the legacy terrain/replay implementation in the first migration pass.
