# Authority and Concurrency

## Fixed-rate runtime

`RuntimeController` runs simulation work on a dedicated fixed-rate thread and publishes a latest-value snapshot through `LatestStateSlot`. Network and render cadence must not become the simulation clock. Commands enter the bounded queue through `submit_command`; duplicate command IDs use the session cache for idempotency.

## Terrain ownership

`TerrainController` is the only owner of active terrain history. Live edits are newest-wins inputs; expensive terrain work runs on its edit thread and bounded executor. `TerrainTimeline` and `TerrainEditEvent` preserve deterministic replay. Stable substrate and loose depth are authoritative layers; the derived surface is what protocol snapshots expose.

## Lifecycle

Every worker and executor must have an explicit `close()` path. `RuntimeController.stop()` stops the simulation thread, replay worker, exchange, terrain controller, and pending command futures. Do not add daemon threads that silently outlive the authority.

## Cross-layer rule

Godot may consume snapshots, patches, and pose state and may maintain local colliders or visual particles. It must not write physics transforms, terrain heights, bucket volume, or replay cursors back to Python in the first release.

Reference files:

- `backend/src/babylon_sim/runtime.py`
- `backend/src/babylon_sim/terrain_controller.py`
- `backend/src/babylon_sim/terrain_excavation.py`
- `.trellis/tasks/08-06-excavator-sim-bootstrap/docs/godot-integration.md`

## Reviewed model session identity

When more than one reviewed excavator is selectable, `RuntimeSessionManager`
is the lifecycle boundary. A model switch must construct a fresh
`RuntimeController` from one immutable descriptor and must not mutate the
active controller in place. The descriptor's `model_id`, `model_version`,
URDF, visual manifest, replay model, recording exchange, and RRD metadata are
one identity.

The WebSocket hello may request a model ID. The manager must reject an unknown
or unavailable ID, and must return `model_switch_busy` while an established
peer still owns the current session. Replay model construction must pass the
selected descriptor's explicit `model_version`; loading the same URDF without
that argument silently restores the SY205 compatibility identity.

Good: resolve every endpoint and replay worker through the selected descriptor
and create new queues/epochs on a successful switch. Bad: relabel a fixed
SY205 visual manifest as another model, or hot-reload a URDF underneath an
existing peer.
